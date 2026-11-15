"""coco-token-meter admin dashboard (Streamlit in Snowflake).

Shows CoCo (Cortex Code) usage for all users from the COCO_TOKEN_METER.USAGE
views. It runs with the rights of the role that owns it, so give access to it
only to people who may see every user's usage.
"""

import pandas as pd
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="CoCo Token Meter", layout="wide")
session = get_active_session()

# The views live in the USAGE schema of the database this dashboard is in:
# COCO_TOKEN_METER for the SQL install, the application itself for the native app.
_database = (session.get_current_database() or "COCO_TOKEN_METER").strip('"')
SCHEMA = f'"{_database}".USAGE'


@st.cache_data(ttl=300, show_spinner="Reading CoCo usage...")
def load_requests(days: int) -> pd.DataFrame:
    df = session.sql(
        f"""
        SELECT THREAD_ID, REQUEST_NO, USER_NAME, INTERFACE, USAGE_TIME,
               USAGE_TIME::DATE AS USAGE_DATE, SECONDS_SINCE_PREVIOUS,
               TOTAL_TOKENS, INPUT_TOKENS, CACHE_READ_TOKENS, CACHE_WRITE_TOKENS,
               OUTPUT_TOKENS, CREDITS, INPUT_CREDITS, CACHE_READ_CREDITS,
               CACHE_WRITE_CREDITS, OUTPUT_CREDITS, REQUEST_KIND
        FROM {SCHEMA}.REQUESTS
        WHERE USAGE_TIME >= DATEADD('day', -{int(days)}, CURRENT_TIMESTAMP())
        """
    ).to_pandas()
    numeric = [c for c in df.columns if c.endswith("_TOKENS") or c.endswith("CREDITS")]
    for col in numeric:
        df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0).astype(float)
    return df


@st.cache_data(ttl=300, show_spinner=False)
def load_titles() -> pd.DataFrame:
    return session.sql(
        f"""
        SELECT THREAD_ID, CHAT_NAME FROM {SCHEMA}.CHAT_TITLES
        QUALIFY ROW_NUMBER() OVER (PARTITION BY THREAD_ID ORDER BY SYNCED_AT DESC) = 1
        """
    ).to_pandas()


@st.cache_data(ttl=300, show_spinner=False)
def load_settings() -> dict:
    df = session.sql(f"SELECT KEY, VALUE FROM {SCHEMA}.SETTINGS").to_pandas()
    return dict(zip(df["KEY"], df["VALUE"]))


@st.cache_data(ttl=300, show_spinner=False)
def load_savings() -> pd.DataFrame:
    df = session.sql(f"SELECT * FROM {SCHEMA}.SAVINGS_ESTIMATE").to_pandas()
    for col in df.columns:
        if col != "USER_NAME":
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0).astype(float)
    return df


def money(credits: float, price, currency: str) -> str:
    if price is None:
        return ""
    return f"{credits * price:,.2f} {currency}".strip()


st.title("CoCo Token Meter")
st.caption("What Snowflake CoCo (Cortex Code) chats cost, per chat and per user.")

with st.sidebar:
    st.header("Filters")
    days = st.selectbox("Period", [7, 30, 90, 365], index=1, format_func=lambda d: f"Last {d} days")
    if st.button("Refresh data"):
        st.cache_data.clear()

requests = load_requests(days)
settings = load_settings()
try:
    price = float(settings["CREDIT_PRICE"]) if settings.get("CREDIT_PRICE") else None
except ValueError:
    price = None
currency = settings.get("CURRENCY") or ""

if requests.empty:
    st.info("No CoCo usage found in this period.")
    st.stop()

with st.sidebar:
    users = sorted(requests["USER_NAME"].dropna().unique())
    picked_users = st.multiselect("Users", users, default=[])
    interfaces = sorted(requests["INTERFACE"].dropna().unique())
    picked_interfaces = st.multiselect("Interfaces", interfaces, default=[])

data = requests
if picked_users:
    data = data[data["USER_NAME"].isin(picked_users)]
if picked_interfaces:
    data = data[data["INTERFACE"].isin(picked_interfaces)]
if data.empty:
    st.info("Nothing matches these filters.")
    st.stop()

in_chats = data[data["THREAD_ID"].notna()]
total_credits = data["CREDITS"].sum()
chat_count = in_chats["THREAD_ID"].nunique()
cold = in_chats[in_chats["REQUEST_KIND"] == "cold start"]
cold_credits = cold["CACHE_WRITE_CREDITS"].sum()

# ---------------------------------------------------------------- headline
k1, k2, k3, k4, k5 = st.columns(5)
k1.metric("Credits", f"{total_credits:,.2f}", money(total_credits, price, currency) or None, delta_color="off")
k2.metric("Chats", f"{chat_count:,}")
k3.metric("Requests", f"{len(data):,}")
k4.metric("Credits per chat", f"{(in_chats['CREDITS'].sum() / chat_count):,.3f}" if chat_count else "0")
k5.metric("Spent on cold starts", f"{(100 * cold_credits / total_credits):.0f}%" if total_credits else "0%")

tab_overview, tab_chats, tab_users, tab_savings, tab_chat = st.tabs(
    ["Overview", "Chats", "Users", "Savings", "One chat"]
)

# ---------------------------------------------------------------- overview
with tab_overview:
    left, right = st.columns(2)
    with left:
        st.subheader("Credits per day")
        daily = (
            data.groupby("USAGE_DATE")[
                ["CACHE_WRITE_CREDITS", "CACHE_READ_CREDITS", "OUTPUT_CREDITS", "INPUT_CREDITS"]
            ]
            .sum()
            .rename(
                columns={
                    "CACHE_WRITE_CREDITS": "Cache write",
                    "CACHE_READ_CREDITS": "Cache read",
                    "OUTPUT_CREDITS": "Output",
                    "INPUT_CREDITS": "Fresh input",
                }
            )
        )
        st.bar_chart(daily)
    with right:
        st.subheader("Where the credits went")
        idle = in_chats[in_chats["REQUEST_KIND"] == "idle reload"]["CACHE_WRITE_CREDITS"].sum()
        large = in_chats[in_chats["REQUEST_KIND"] == "large addition"]["CACHE_WRITE_CREDITS"].sum()
        other_writes = data["CACHE_WRITE_CREDITS"].sum() - cold_credits - idle - large
        parts = pd.DataFrame(
            {
                "Credits": [
                    cold_credits,
                    idle,
                    large,
                    other_writes,
                    data["CACHE_READ_CREDITS"].sum(),
                    data["OUTPUT_CREDITS"].sum(),
                    data["INPUT_CREDITS"].sum(),
                ]
            },
            index=[
                "Cold starts (new chats)",
                "Idle reloads",
                "Large additions",
                "Other cache writes",
                "Cache reads",
                "Output (answers)",
                "Fresh input",
            ],
        )
        parts["Share %"] = (100 * parts["Credits"] / total_credits).round(1) if total_credits else 0.0
        parts["Credits"] = parts["Credits"].round(4)
        st.dataframe(parts, use_container_width=True)
        st.caption(
            "A cold start is the first request of a chat, when the starting context is "
            "written to the prompt cache. An idle reload is a chat resumed after the cache expired."
        )

    st.subheader("Credits by interface")
    by_interface = (
        data.groupby("INTERFACE")
        .agg(Chats=("THREAD_ID", "nunique"), Requests=("CREDITS", "size"), Credits=("CREDITS", "sum"))
        .sort_values("Credits", ascending=False)
    )
    by_interface["Credits"] = by_interface["Credits"].round(4)
    st.dataframe(by_interface, use_container_width=True)

# ---------------------------------------------------------------- chats
chats = (
    in_chats.groupby("THREAD_ID")
    .agg(
        User=("USER_NAME", "first"),
        Interface=("INTERFACE", "first"),
        Started=("USAGE_TIME", "min"),
        Requests=("CREDITS", "size"),
        Tokens=("TOTAL_TOKENS", "sum"),
        Credits=("CREDITS", "sum"),
    )
    .reset_index()
)
if not chats.empty:
    chats["THREAD_ID"] = chats["THREAD_ID"].astype("int64")
    titles = load_titles()
    if not titles.empty:
        titles["THREAD_ID"] = titles["THREAD_ID"].astype("int64")
        chats = chats.merge(titles, on="THREAD_ID", how="left")
    else:
        chats["CHAT_NAME"] = None
    chats = chats.rename(columns={"THREAD_ID": "Thread", "CHAT_NAME": "Chat name"})
    chats["Tokens"] = chats["Tokens"].astype("int64")
    chats["Credits"] = chats["Credits"].round(4)
    if price is not None:
        chats[f"Cost {currency}".strip()] = (chats["Credits"] * price).round(2)
    first_columns = ["Thread", "Chat name", "User", "Interface", "Started", "Requests", "Tokens", "Credits"]
    chats = chats[first_columns + [c for c in chats.columns if c not in first_columns]]

with tab_chats:
    st.subheader("Most expensive chats")
    st.dataframe(
        chats.sort_values("Credits", ascending=False).head(200), use_container_width=True, hide_index=True
    )
    st.caption(
        "A chat has a name once its owner has run CALL "
        "COCO_TOKEN_METER.USAGE.SYNC_MY_CHAT_TITLES(), which the CoCo skill does for them."
    )

# ---------------------------------------------------------------- users
with tab_users:
    st.subheader("Usage per user")
    per_user = (
        chats.groupby("User")
        .agg(Chats=("Thread", "count"), Requests=("Requests", "sum"), Credits=("Credits", "sum"),
             Most_expensive_chat=("Credits", "max"))
        .sort_values("Credits", ascending=False)
        .rename(columns={"Most_expensive_chat": "Most expensive chat"})
    )
    per_user["Credits per chat"] = (per_user["Credits"] / per_user["Chats"]).round(4)
    if price is not None:
        per_user[f"Cost {currency}".strip()] = (per_user["Credits"] * price).round(2)
    st.dataframe(per_user, use_container_width=True)
    st.bar_chart(per_user[["Credits"]].head(25))

# ---------------------------------------------------------------- savings
with tab_savings:
    st.subheader("What could have been saved (last 30 days)")
    st.caption(
        "Estimates and upper bounds, not promises. The three figures overlap and must not be added up."
    )
    savings = load_savings()
    if picked_users:
        savings = savings[savings["USER_NAME"].isin(picked_users)]
    if savings.empty:
        st.info("No chats in the last 30 days.")
    else:
        s1, s2, s3 = st.columns(3)
        s1.metric(
            "Follow-ups instead of new chats",
            f"{savings['QUICK_RESTART_SAVING'].sum():,.2f} credits",
            f"{int(savings['QUICK_RESTARTS'].sum())} chats started within 5 min of the previous one",
            delta_color="off",
        )
        s2.metric(
            "No long pauses inside a chat",
            f"{savings['IDLE_RELOAD_SAVING'].sum():,.2f} credits",
            f"{int(savings['IDLE_RELOADS'].sum())} idle reloads",
            delta_color="off",
        )
        s3.metric(
            "/slim in CoCo CLI",
            f"{savings['SLIM_SAVING_LOW'].sum():,.2f} to {savings['SLIM_SAVING_HIGH'].sum():,.2f} credits",
            "20 or all bundled skills turned off",
            delta_color="off",
        )
        st.dataframe(savings.set_index("USER_NAME"), use_container_width=True)

# ---------------------------------------------------------------- one chat
with tab_chat:
    st.subheader("One chat, request by request")
    if chats.empty:
        st.info("No chats in this period.")
    else:
        ordered = chats.sort_values("Credits", ascending=False)
        labels = {
            int(row["Thread"]): f"{int(row['Thread'])}  |  {row['Chat name'] or 'unnamed'}  |  "
            f"{row['User']}  |  {row['Credits']:.4f} credits"
            for _, row in ordered.iterrows()
        }
        thread = st.selectbox("Chat", list(labels.keys()), format_func=lambda t: labels[t])
        one = in_chats[in_chats["THREAD_ID"] == thread].sort_values("REQUEST_NO")
        view = one[
            ["REQUEST_NO", "USAGE_TIME", "REQUEST_KIND", "SECONDS_SINCE_PREVIOUS", "TOTAL_TOKENS",
             "CACHE_WRITE_TOKENS", "CACHE_READ_TOKENS", "INPUT_TOKENS", "OUTPUT_TOKENS", "CREDITS"]
        ].copy()
        view["RUNNING_CREDITS"] = view["CREDITS"].cumsum().round(4)
        view["CREDITS"] = view["CREDITS"].round(4)
        st.dataframe(view, use_container_width=True, hide_index=True)
        st.bar_chart(view.set_index("REQUEST_NO")[["CREDITS"]])

st.caption(
    "Source: SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY through the coco-token-meter views. "
    "Data is cached for 5 minutes; use Refresh data in the sidebar to reload."
)
