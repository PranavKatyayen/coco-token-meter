"""coco-token-meter admin dashboard (Streamlit in Snowflake).

Shows CoCo (Cortex Code) usage for all users from the coco-token-meter views.
It runs with the rights of the role that owns it, so give access to it only to
people who may see every user's usage.
"""

import html

import pandas as pd
import plotly.graph_objects as go
import streamlit as st
from snowflake.snowpark.context import get_active_session

st.set_page_config(page_title="CoCo Token Meter", layout="wide")
session = get_active_session()

# The views live in the USAGE schema of the database this dashboard is in:
# COCO_TOKEN_METER for the SQL install, the application itself for the native app.
_database = (session.get_current_database() or "COCO_TOKEN_METER").strip('"')
SCHEMA = f'"{_database}".USAGE'

# ------------------------------------------------------------------ palette
BG = "#05070f"
TEXT = "#e6f1ff"
MUTED = "#8492b8"
CYAN = "#22d3ee"
VIOLET = "#8b5cf6"
PINK = "#f472b6"
AMBER = "#fbbf24"
GREEN = "#34d399"
BLUE = "#60a5fa"
SLATE = "#64748b"
FONT = "'Segoe UI', Inter, system-ui, -apple-system, sans-serif"
MONO = "ui-monospace, 'Cascadia Code', 'SF Mono', Consolas, monospace"

KIND_COLORS = {
    "Cold starts (new chats)": PINK,
    "Idle reloads": AMBER,
    "Large additions": VIOLET,
    "Other cache writes": BLUE,
    "Cache reads": CYAN,
    "Output (answers)": GREEN,
    "Fresh input": SLATE,
}
REQUEST_KIND_COLORS = {
    "cold start": PINK,
    "idle reload": AMBER,
    "large addition": VIOLET,
    "normal": CYAN,
    "background": SLATE,
}

CSS = """
<style>
:root {
  --ctm-bg: #05070f; --ctm-text: #e6f1ff; --ctm-muted: #8492b8;
  --ctm-cyan: #22d3ee; --ctm-violet: #8b5cf6; --ctm-pink: #f472b6;
  --ctm-line: rgba(120, 160, 255, 0.16);
  --ctm-panel: rgba(16, 22, 46, 0.62);
  --ctm-mono: ui-monospace, 'Cascadia Code', 'SF Mono', Consolas, monospace;
}
.stApp, [data-testid="stAppViewContainer"] {
  background:
    radial-gradient(1100px 520px at 12% -10%, rgba(34, 211, 238, 0.13), transparent 60%),
    radial-gradient(900px 520px at 95% 0%, rgba(139, 92, 246, 0.16), transparent 62%),
    radial-gradient(800px 600px at 50% 120%, rgba(244, 114, 182, 0.08), transparent 60%),
    var(--ctm-bg) !important;
  color: var(--ctm-text);
}
[data-testid="stAppViewContainer"]::before {
  content: ""; position: fixed; inset: 0; pointer-events: none; z-index: 0;
  background-image:
    linear-gradient(rgba(120, 160, 255, 0.045) 1px, transparent 1px),
    linear-gradient(90deg, rgba(120, 160, 255, 0.045) 1px, transparent 1px);
  background-size: 44px 44px;
  -webkit-mask-image: radial-gradient(ellipse at 50% 0%, #000 0%, transparent 75%);
          mask-image: radial-gradient(ellipse at 50% 0%, #000 0%, transparent 75%);
}
[data-testid="stHeader"] { background: transparent !important; }
.block-container { padding-top: 1.6rem; max-width: 1500px; position: relative; z-index: 1; }
.stApp, .stApp p, .stApp li, .stApp label, .stApp span { color: var(--ctm-text); }
.stApp h1, .stApp h2, .stApp h3 { color: var(--ctm-text); letter-spacing: 0.01em; }
[data-testid="stSidebar"] {
  background: linear-gradient(180deg, rgba(10, 14, 32, 0.96), rgba(6, 8, 18, 0.98)) !important;
  border-right: 1px solid var(--ctm-line);
}
[data-testid="stSidebar"] * { color: var(--ctm-text); }

/* hero */
.ctm-hero {
  position: relative; overflow: hidden; border-radius: 22px; padding: 26px 30px 24px;
  border: 1px solid var(--ctm-line);
  background: linear-gradient(135deg, rgba(20, 28, 60, 0.78), rgba(10, 13, 30, 0.72));
  box-shadow: 0 0 0 1px rgba(34, 211, 238, 0.05), 0 24px 60px -30px rgba(34, 211, 238, 0.45);
  animation: ctm-rise 0.7s cubic-bezier(.2,.8,.2,1) both;
}
.ctm-hero::after {
  content: ""; position: absolute; left: -40%; top: 0; width: 40%; height: 100%;
  background: linear-gradient(90deg, transparent, rgba(34, 211, 238, 0.10), transparent);
  animation: ctm-scan 6.5s ease-in-out infinite;
}
.ctm-eyebrow {
  font-family: var(--ctm-mono); font-size: 11px; letter-spacing: 0.28em; text-transform: uppercase;
  color: var(--ctm-cyan); display: flex; align-items: center; gap: 10px;
}
.ctm-dot {
  width: 8px; height: 8px; border-radius: 50%; background: var(--ctm-cyan);
  box-shadow: 0 0 0 0 rgba(34, 211, 238, 0.7); animation: ctm-pulse 2s infinite;
}
.ctm-title {
  font-size: 44px; line-height: 1.05; font-weight: 700; margin: 10px 0 6px;
  background: linear-gradient(92deg, #ffffff 0%, #a5f3fc 38%, #c4b5fd 72%, #f9a8d4 100%);
  -webkit-background-clip: text; background-clip: text; color: transparent !important;
}
.ctm-sub { color: var(--ctm-muted) !important; font-size: 15px; max-width: 880px; }
.ctm-insight {
  margin-top: 16px; padding: 12px 16px; border-radius: 12px; font-size: 15px;
  border: 1px solid rgba(244, 114, 182, 0.28); background: rgba(244, 114, 182, 0.07);
}
.ctm-insight b { color: #fbcfe8; }

/* metric cards */
.ctm-grid { display: grid; grid-template-columns: repeat(5, minmax(0, 1fr)); gap: 14px; margin: 18px 0 6px; }
.ctm-grid.three { grid-template-columns: repeat(3, minmax(0, 1fr)); }
@media (max-width: 1100px) { .ctm-grid, .ctm-grid.three { grid-template-columns: repeat(2, minmax(0, 1fr)); } }
.ctm-card {
  position: relative; border-radius: 18px; padding: 18px 18px 16px; overflow: hidden;
  background: var(--ctm-panel); border: 1px solid var(--ctm-line);
  -webkit-backdrop-filter: blur(10px); backdrop-filter: blur(10px);
  transition: transform .25s ease, border-color .25s ease, box-shadow .25s ease;
  animation: ctm-rise 0.7s cubic-bezier(.2,.8,.2,1) both;
}
.ctm-card:nth-child(2) { animation-delay: .06s; } .ctm-card:nth-child(3) { animation-delay: .12s; }
.ctm-card:nth-child(4) { animation-delay: .18s; } .ctm-card:nth-child(5) { animation-delay: .24s; }
.ctm-card:hover {
  transform: translateY(-3px); border-color: var(--accent, var(--ctm-cyan));
  box-shadow: 0 18px 40px -22px var(--accent, var(--ctm-cyan));
}
.ctm-card::before {
  content: ""; position: absolute; left: 0; top: 0; height: 2px; width: 100%;
  background: linear-gradient(90deg, transparent, var(--accent, var(--ctm-cyan)), transparent);
}
.ctm-label {
  font-family: var(--ctm-mono); font-size: 10.5px; letter-spacing: 0.2em; text-transform: uppercase;
  color: var(--ctm-muted) !important;
}
.ctm-value {
  font-family: var(--ctm-mono); font-size: 34px; font-weight: 600; margin-top: 8px; line-height: 1.1;
  color: #ffffff !important; text-shadow: 0 0 22px var(--accent, var(--ctm-cyan));
  font-variant-numeric: tabular-nums;
}
.ctm-value small { font-size: 15px; color: var(--ctm-muted); font-weight: 400; margin-left: 4px; }
.ctm-note { margin-top: 6px; font-size: 12.5px; color: var(--ctm-muted) !important; min-height: 18px; }
.ctm-bar { margin-top: 12px; height: 4px; border-radius: 4px; background: rgba(255, 255, 255, 0.07); overflow: hidden; }
.ctm-bar > i {
  display: block; height: 100%; border-radius: 4px; transform-origin: left center;
  background: linear-gradient(90deg, var(--accent, var(--ctm-cyan)), #ffffff);
  animation: ctm-grow 1.1s cubic-bezier(.2,.8,.2,1) both;
}
.acc-cyan { --accent: #22d3ee; } .acc-violet { --accent: #8b5cf6; } .acc-pink { --accent: #f472b6; }
.acc-amber { --accent: #fbbf24; } .acc-green { --accent: #34d399; } .acc-blue { --accent: #60a5fa; }

/* section titles and panels */
.ctm-h {
  font-family: var(--ctm-mono); font-size: 12px; letter-spacing: 0.24em; text-transform: uppercase;
  color: var(--ctm-cyan) !important; margin: 22px 0 8px; display: flex; align-items: center; gap: 10px;
}
.ctm-h::after { content: ""; flex: 1; height: 1px; background: linear-gradient(90deg, var(--ctm-line), transparent); }
.ctm-hint { color: var(--ctm-muted) !important; font-size: 13px; margin: -2px 0 8px; }
[data-testid="stPlotlyChart"] {
  border-radius: 18px; border: 1px solid var(--ctm-line); background: var(--ctm-panel); padding: 10px 8px 4px;
}

/* tables */
.ctm-table { width: 100%; border-collapse: separate; border-spacing: 0; font-size: 13.5px; }
.ctm-wrap { border-radius: 18px; border: 1px solid var(--ctm-line); background: var(--ctm-panel); overflow: hidden; }
.ctm-table th {
  text-align: left; padding: 11px 14px; font-family: var(--ctm-mono); font-size: 10.5px; font-weight: 500;
  letter-spacing: 0.16em; text-transform: uppercase; color: var(--ctm-muted) !important;
  border-bottom: 1px solid var(--ctm-line); background: rgba(255, 255, 255, 0.02);
}
.ctm-table td { padding: 10px 14px; border-bottom: 1px solid rgba(120, 160, 255, 0.08); color: var(--ctm-text); }
.ctm-table tr:last-child td { border-bottom: none; }
.ctm-table tbody tr { transition: background .18s ease; }
.ctm-table tbody tr:hover { background: rgba(34, 211, 238, 0.07); }
.ctm-table td.num, .ctm-table th.num { text-align: right; font-family: var(--ctm-mono); font-variant-numeric: tabular-nums; }
.ctm-table td.dim { color: var(--ctm-muted) !important; }
.ctm-chip {
  display: inline-block; padding: 2px 9px; border-radius: 999px; font-family: var(--ctm-mono); font-size: 11px;
  border: 1px solid currentColor; color: var(--ctm-cyan); background: rgba(255, 255, 255, 0.03);
  white-space: nowrap;
}
.ctm-meter { display: inline-block; vertical-align: middle; width: 90px; height: 5px; border-radius: 5px;
  background: rgba(255, 255, 255, 0.07); margin-left: 10px; overflow: hidden; }
.ctm-meter > i { display: block; height: 100%;
  background: linear-gradient(90deg, var(--ctm-violet), var(--ctm-cyan)); }

/* tabs as pills */
[data-baseweb="tab-list"] { gap: 6px; border-bottom: none !important; margin-top: 10px; }
[data-baseweb="tab"] {
  border-radius: 999px !important; padding: 8px 18px !important; height: auto !important;
  border: 1px solid var(--ctm-line) !important; background: rgba(255, 255, 255, 0.02) !important;
  transition: all .2s ease;
}
[data-baseweb="tab"] p { font-family: var(--ctm-mono); font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase; }
[data-baseweb="tab"]:hover { border-color: var(--ctm-cyan) !important; }
[data-baseweb="tab"][aria-selected="true"] {
  background: linear-gradient(90deg, rgba(34, 211, 238, 0.20), rgba(139, 92, 246, 0.20)) !important;
  border-color: var(--ctm-cyan) !important; box-shadow: 0 0 22px -8px var(--ctm-cyan);
}
[data-baseweb="tab-highlight"], [data-baseweb="tab-border"] { display: none !important; }

/* navigation pills (a horizontal radio, so only the chosen view is drawn) */
.block-container [role="radiogroup"] { gap: 8px; flex-wrap: wrap; margin: 12px 0 2px; }
.block-container [role="radiogroup"] > label {
  border-radius: 999px; padding: 8px 18px; margin: 0; cursor: pointer;
  border: 1px solid var(--ctm-line); background: rgba(255, 255, 255, 0.02); transition: all .2s ease;
}
.block-container [role="radiogroup"] > label > div:first-child { display: none; }
.block-container [role="radiogroup"] > label p {
  font-family: var(--ctm-mono); font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase;
}
.block-container [role="radiogroup"] > label:hover { border-color: var(--ctm-cyan); }
.block-container [role="radiogroup"] > label:has(input:checked) {
  background: linear-gradient(90deg, rgba(34, 211, 238, 0.20), rgba(139, 92, 246, 0.20));
  border-color: var(--ctm-cyan); box-shadow: 0 0 22px -8px var(--ctm-cyan);
}

/* sidebar */
[data-testid="stSidebar"] > div:first-child { padding-top: 0.6rem; }
.ctm-brand { display: flex; align-items: center; gap: 12px; padding: 4px 0 14px; }
.ctm-brand-mark {
  width: 40px; height: 40px; border-radius: 12px; flex: none; position: relative;
  background: conic-gradient(from 210deg, #22d3ee, #8b5cf6, #f472b6, #22d3ee);
  box-shadow: 0 0 26px -6px #22d3ee; animation: ctm-rise .7s ease both;
}
.ctm-brand-mark::after { content: ""; position: absolute; inset: 3px; border-radius: 9px; background: #070a18; }
.ctm-brand-mark::before {
  content: ""; position: absolute; z-index: 1; left: 50%; top: 50%; width: 12px; height: 12px;
  margin: -6px 0 0 -6px; border-radius: 50%; background: #22d3ee; box-shadow: 0 0 14px 2px #22d3ee;
}
.ctm-brand-name { font-size: 17px; font-weight: 700; line-height: 1.15; color: #ffffff !important; }
.ctm-brand-tag { font-family: var(--ctm-mono); font-size: 10px; letter-spacing: 0.2em; text-transform: uppercase;
  color: var(--ctm-muted) !important; }
.ctm-side-card {
  border-radius: 14px; border: 1px solid var(--ctm-line); background: rgba(255, 255, 255, 0.025);
  padding: 12px 14px; margin: 10px 0 4px;
}
.ctm-side-row { display: flex; justify-content: space-between; align-items: baseline; padding: 4px 0;
  font-size: 12.5px; color: var(--ctm-muted) !important; }
.ctm-side-row b { font-family: var(--ctm-mono); font-weight: 500; color: #ffffff !important; }
.ctm-legend { display: flex; align-items: center; gap: 9px; padding: 4px 0; font-size: 12.5px; }
.ctm-swatch { width: 10px; height: 10px; border-radius: 3px; flex: none; }
[data-testid="stSidebar"] label p {
  font-family: var(--ctm-mono); font-size: 10.5px; letter-spacing: 0.18em; text-transform: uppercase;
  color: var(--ctm-muted) !important;
}
[data-testid="stSidebar"] [data-baseweb="select"] > div {
  background: rgba(255, 255, 255, 0.03) !important; border: 1px solid var(--ctm-line) !important;
  border-radius: 12px !important; transition: border-color .2s ease, box-shadow .2s ease;
}
[data-testid="stSidebar"] [data-baseweb="select"] > div:hover,
[data-testid="stSidebar"] [data-baseweb="select"] > div:focus-within {
  border-color: var(--ctm-cyan) !important; box-shadow: 0 0 18px -8px var(--ctm-cyan);
}
[data-testid="stSidebar"] [data-baseweb="tag"] {
  background: rgba(34, 211, 238, 0.14) !important; border: 1px solid rgba(34, 211, 238, 0.5);
  border-radius: 999px !important;
}
[data-testid="stSidebar"] .stButton > button {
  width: 100%; border-radius: 12px; border: 1px solid rgba(34, 211, 238, 0.45);
  background: linear-gradient(90deg, rgba(34, 211, 238, 0.14), rgba(139, 92, 246, 0.14));
  color: #ffffff; font-family: var(--ctm-mono); font-size: 12px; letter-spacing: 0.14em; text-transform: uppercase;
  transition: all .2s ease;
}
[data-testid="stSidebar"] .stButton > button:hover {
  border-color: var(--ctm-cyan); box-shadow: 0 0 22px -8px var(--ctm-cyan); transform: translateY(-1px);
}

.ctm-foot { margin-top: 26px; color: var(--ctm-muted) !important; font-size: 12px; font-family: var(--ctm-mono); }

@keyframes ctm-rise { from { opacity: 0; transform: translateY(14px); } to { opacity: 1; transform: none; } }
@keyframes ctm-grow { from { transform: scaleX(0); } to { transform: scaleX(1); } }
@keyframes ctm-scan { 0% { left: -40%; } 55%, 100% { left: 120%; } }
@keyframes ctm-pulse {
  0% { box-shadow: 0 0 0 0 rgba(34, 211, 238, 0.7); }
  70% { box-shadow: 0 0 0 10px rgba(34, 211, 238, 0); }
  100% { box-shadow: 0 0 0 0 rgba(34, 211, 238, 0); }
}
@media (prefers-reduced-motion: reduce) {
  .ctm-hero, .ctm-hero::after, .ctm-card, .ctm-bar > i, .ctm-dot, .ctm-brand-mark { animation: none !important; }
}
</style>
"""


# ------------------------------------------------------------------ data
@st.cache_data(ttl=600, show_spinner="Reading CoCo usage...")
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
    for col in df.columns:
        if col.endswith("_TOKENS") or col.endswith("CREDITS"):
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0).astype(float)
    df["USAGE_TIME"] = pd.to_datetime(df["USAGE_TIME"], utc=True)
    return df


@st.cache_data(ttl=600, show_spinner=False)
def load_titles() -> pd.DataFrame:
    return session.sql(
        f"""
        SELECT THREAD_ID, CHAT_NAME FROM {SCHEMA}.CHAT_TITLES
        QUALIFY ROW_NUMBER() OVER (PARTITION BY THREAD_ID ORDER BY SYNCED_AT DESC) = 1
        """
    ).to_pandas()


@st.cache_data(ttl=600, show_spinner=False)
def load_settings() -> dict:
    df = session.sql(f"SELECT KEY, VALUE FROM {SCHEMA}.SETTINGS").to_pandas()
    return dict(zip(df["KEY"], df["VALUE"]))


@st.cache_data(ttl=600, show_spinner=False)
def load_savings() -> pd.DataFrame:
    df = session.sql(f"SELECT * FROM {SCHEMA}.SAVINGS_ESTIMATE").to_pandas()
    for col in df.columns:
        if col != "USER_NAME":
            df[col] = pd.to_numeric(df[col], errors="coerce").fillna(0.0).astype(float)
    return df


# ------------------------------------------------------------------ helpers
def esc(value) -> str:
    return html.escape("" if value is None or (isinstance(value, float) and pd.isna(value)) else str(value))


ACCENT_CLASS = {CYAN: "acc-cyan", VIOLET: "acc-violet", PINK: "acc-pink", AMBER: "acc-amber", GREEN: "acc-green", BLUE: "acc-blue"}


def card(label: str, value: str, note: str = "", accent: str = CYAN, bar=None, unit: str = "") -> str:
    bar_html = ""
    if bar is not None:
        width = max(0.0, min(100.0, float(bar)))
        bar_html = f'<div class="ctm-bar"><i style="width:{width:.1f}%"></i></div>'
    unit_html = f"<small>{esc(unit)}</small>" if unit else ""
    return (
        f'<div class="ctm-card {ACCENT_CLASS.get(accent, "acc-cyan")}">'
        f'<div class="ctm-label">{esc(label)}</div>'
        f'<div class="ctm-value">{esc(value)}{unit_html}</div>'
        f'<div class="ctm-note">{esc(note)}</div>{bar_html}</div>'
    )


def cards(items, three: bool = False) -> None:
    cls = "ctm-grid three" if three else "ctm-grid"
    st.markdown(f'<div class="{cls}">{"".join(items)}</div>', unsafe_allow_html=True)


def heading(text: str, hint: str = "") -> None:
    st.markdown(f'<div class="ctm-h">{esc(text)}</div>', unsafe_allow_html=True)
    if hint:
        st.markdown(f'<div class="ctm-hint">{esc(hint)}</div>', unsafe_allow_html=True)


def table(rows, columns) -> None:
    """columns: list of (header, key, kind) where kind is text, num, dim or raw."""
    head = "".join(
        f'<th class="{"num" if kind == "num" else ""}">{esc(header)}</th>' for header, _, kind in columns
    )
    body = []
    for row in rows:
        cells = []
        for _, key, kind in columns:
            value = row.get(key, "")
            if kind == "raw":
                cells.append(f"<td>{value}</td>")
            else:
                cls = {"num": "num", "dim": "dim"}.get(kind, "")
                cells.append(f'<td class="{cls}">{esc(value)}</td>')
        body.append(f"<tr>{''.join(cells)}</tr>")
    st.markdown(
        f'<div class="ctm-wrap"><table class="ctm-table"><thead><tr>{head}</tr></thead>'
        f'<tbody>{"".join(body)}</tbody></table></div>',
        unsafe_allow_html=True,
    )


def chip(text: str, color: str) -> str:
    return f'<span class="ctm-chip" style="color:{color};border-color:{color}">{esc(text)}</span>'


def meter(share: float) -> str:
    return f'<span class="ctm-meter"><i style="width:{max(0.0, min(100.0, share)):.1f}%"></i></span>'


def styled(fig: go.Figure, height: int = 340) -> go.Figure:
    fig.update_layout(
        paper_bgcolor="rgba(0,0,0,0)",
        plot_bgcolor="rgba(0,0,0,0)",
        font=dict(color=TEXT, family=FONT, size=12),
        margin=dict(l=10, r=10, t=10, b=10),
        height=height,
        legend=dict(orientation="h", yanchor="bottom", y=1.02, x=0, bgcolor="rgba(0,0,0,0)"),
        hoverlabel=dict(bgcolor="#0b1024", bordercolor=CYAN, font=dict(color=TEXT, family=FONT)),
        bargap=0.25,
    )
    fig.update_xaxes(gridcolor="rgba(120,160,255,0.08)", zeroline=False, linecolor="rgba(120,160,255,0.22)")
    fig.update_yaxes(gridcolor="rgba(120,160,255,0.08)", zeroline=False, linecolor="rgba(120,160,255,0.22)")
    return fig


def show(fig: go.Figure) -> None:
    st.plotly_chart(fig, use_container_width=True, config={"displayModeBar": False})


def money(credits: float, price, currency: str) -> str:
    if price is None:
        return ""
    return f"{credits * price:,.2f} {currency}".strip()


# ------------------------------------------------------------------ page
st.markdown(CSS, unsafe_allow_html=True)

with st.sidebar:
    st.markdown(
        '<div class="ctm-brand"><div class="ctm-brand-mark"></div><div>'
        '<div class="ctm-brand-name">CoCo Token Meter</div>'
        '<div class="ctm-brand-tag">admin console</div></div></div>',
        unsafe_allow_html=True,
    )
    st.markdown('<div class="ctm-h">Filters</div>', unsafe_allow_html=True)
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
    st.markdown(
        '<div class="ctm-hero"><div class="ctm-eyebrow"><span class="ctm-dot"></span>CoCo Token Meter</div>'
        '<div class="ctm-title">No usage yet</div>'
        '<div class="ctm-sub">No CoCo requests were found in this period.</div></div>',
        unsafe_allow_html=True,
    )
    st.stop()

with st.sidebar:
    users = sorted(requests["USER_NAME"].dropna().unique())
    picked_users = st.multiselect("Users", users, default=[])
    interfaces = sorted(requests["INTERFACE"].dropna().unique())
    picked_interfaces = st.multiselect("Interfaces", interfaces, default=[])
    side_slot = st.container()

data = requests
if picked_users:
    data = data[data["USER_NAME"].isin(picked_users)]
if picked_interfaces:
    data = data[data["INTERFACE"].isin(picked_interfaces)]
if data.empty:
    st.info("Nothing matches these filters.")
    st.stop()

in_chats = data[data["THREAD_ID"].notna()]
total_credits = float(data["CREDITS"].sum())
chat_count = int(in_chats["THREAD_ID"].nunique())
cold_credits = float(in_chats[in_chats["REQUEST_KIND"] == "cold start"]["CACHE_WRITE_CREDITS"].sum())
idle_credits = float(in_chats[in_chats["REQUEST_KIND"] == "idle reload"]["CACHE_WRITE_CREDITS"].sum())
large_credits = float(in_chats[in_chats["REQUEST_KIND"] == "large addition"]["CACHE_WRITE_CREDITS"].sum())
other_writes = float(data["CACHE_WRITE_CREDITS"].sum()) - cold_credits - idle_credits - large_credits
cold_share = 100 * cold_credits / total_credits if total_credits else 0.0
per_chat = float(in_chats["CREDITS"].sum()) / chat_count if chat_count else 0.0
per_cold_start = (
    cold_credits / int((in_chats["REQUEST_KIND"] == "cold start").sum())
    if (in_chats["REQUEST_KIND"] == "cold start").any()
    else 0.0
)
latest = data["USAGE_TIME"].max()

parts = pd.DataFrame(
    {
        "Part": list(KIND_COLORS.keys()),
        "Credits": [
            cold_credits,
            idle_credits,
            large_credits,
            max(other_writes, 0.0),
            float(data["CACHE_READ_CREDITS"].sum()),
            float(data["OUTPUT_CREDITS"].sum()),
            float(data["INPUT_CREDITS"].sum()),
        ],
    }
)
parts["Share"] = (100 * parts["Credits"] / total_credits) if total_credits else 0.0
parts = parts.sort_values("Credits", ascending=False).reset_index(drop=True)
top_part = parts.iloc[0]

with side_slot:
    st.markdown(
        '<div class="ctm-h">In view</div><div class="ctm-side-card">'
        f'<div class="ctm-side-row"><span>Credits</span><b>{total_credits:,.2f}</b></div>'
        f'<div class="ctm-side-row"><span>Chats</span><b>{chat_count:,}</b></div>'
        f'<div class="ctm-side-row"><span>Requests</span><b>{len(data):,}</b></div>'
        f'<div class="ctm-side-row"><span>Data through</span><b>{esc(latest.strftime("%b %d %H:%M"))} UTC</b></div>'
        "</div>"
        '<div class="ctm-h">Request kinds</div><div class="ctm-side-card">'
        + "".join(
            f'<div class="ctm-legend"><span class="ctm-swatch" style="background:{color}"></span>{esc(text)}</div>'
            for text, color in [
                ("Cold start: a new chat loads its context", PINK),
                ("Idle reload: resumed after a pause", AMBER),
                ("Large addition: big tool result", VIOLET),
                ("Normal request", CYAN),
            ]
        )
        + "</div>"
        '<div class="ctm-foot">Empty filter = everything.<br>Data is cached for 10 minutes.</div>',
        unsafe_allow_html=True,
    )

# ---- hero
scope = []
if picked_users:
    scope.append(", ".join(picked_users[:3]) + ("..." if len(picked_users) > 3 else ""))
if picked_interfaces:
    scope.append(", ".join(picked_interfaces))
scope_text = " / ".join(scope) if scope else "all users, all interfaces"
st.markdown(
    f"""
    <div class="ctm-hero">
      <div class="ctm-eyebrow"><span class="ctm-dot"></span>
        CoCo Token Meter &nbsp;/&nbsp; data through {esc(latest.strftime("%Y-%m-%d %H:%M"))} UTC</div>
      <div class="ctm-title">Where your CoCo credits go</div>
      <div class="ctm-sub">Last {int(days)} days &middot; {esc(scope_text)} &middot;
        {len(data):,} requests in {chat_count:,} chats</div>
      <div class="ctm-insight"><b>{top_part["Share"]:.0f}%</b> of the credits went to
        <b>{esc(top_part["Part"].lower())}</b>.
        A new chat cost about <b>{per_cold_start:.2f} credits</b> before it did any work.</div>
    </div>
    """,
    unsafe_allow_html=True,
)

cards(
    [
        card("Credits", f"{total_credits:,.2f}", money(total_credits, price, currency) or "billed by Snowflake", CYAN),
        card("Chats", f"{chat_count:,}", f"{data['USER_NAME'].nunique():,} users", VIOLET),
        card("Requests", f"{len(data):,}", f"{len(in_chats) / chat_count:.1f} per chat" if chat_count else "", BLUE),
        card("Credits per chat", f"{per_chat:,.3f}", "average", GREEN),
        card("Cold starts", f"{cold_share:.0f}", "share of all credits", PINK, bar=cold_share, unit="%"),
    ]
)

view = st.radio(
    "View", ["Overview", "Chats", "Users", "Savings", "Chat explorer"], horizontal=True, label_visibility="collapsed"
)

# ------------------------------------------------------------------ overview
if view == "Overview":
    left, right = st.columns([3, 2])
    with left:
        heading("Credits per day", "Stacked by what the credits paid for.")
        daily = data.groupby("USAGE_DATE")[
            ["CACHE_WRITE_CREDITS", "CACHE_READ_CREDITS", "OUTPUT_CREDITS", "INPUT_CREDITS"]
        ].sum()
        fig = go.Figure()
        for column, label, color in [
            ("CACHE_WRITE_CREDITS", "Cache write", PINK),
            ("CACHE_READ_CREDITS", "Cache read", CYAN),
            ("OUTPUT_CREDITS", "Output", GREEN),
            ("INPUT_CREDITS", "Fresh input", SLATE),
        ]:
            fig.add_trace(
                go.Bar(
                    x=list(daily.index), y=list(daily[column]), name=label,
                    marker=dict(color=color, line=dict(width=0)),
                    hovertemplate="%{x}<br>" + label + ": %{y:.4f} credits<extra></extra>",
                )
            )
        fig.update_layout(barmode="stack")
        fig.update_yaxes(title_text="credits")
        show(styled(fig, 360))
    with right:
        heading("Where the credits went")
        fig = go.Figure(
            go.Pie(
                labels=list(parts["Part"]), values=list(parts["Credits"]), hole=0.68, sort=False,
                marker=dict(colors=[KIND_COLORS[p] for p in parts["Part"]], line=dict(color=BG, width=3)),
                textinfo="none",
                hovertemplate="%{label}<br>%{value:.4f} credits (%{percent})<extra></extra>",
            )
        )
        fig.update_layout(
            showlegend=False,
            annotations=[
                dict(text=f"<b>{total_credits:,.2f}</b>", x=0.5, y=0.55, showarrow=False,
                     font=dict(size=30, color="#ffffff", family=MONO)),
                dict(text="credits", x=0.5, y=0.40, showarrow=False, font=dict(size=13, color=MUTED)),
            ],
        )
        show(styled(fig, 250))
        table(
            [
                {
                    "part": chip(row["Part"], KIND_COLORS[row["Part"]]),
                    "credits": f"{row['Credits']:,.4f}",
                    "share": f"{row['Share']:.1f}%",
                }
                for _, row in parts.iterrows()
            ],
            [("Part", "part", "raw"), ("Credits", "credits", "num"), ("Share", "share", "num")],
        )

    heading(
        "When CoCo is used",
        "Credits by weekday and hour (UTC). Bright cells are the busiest hours.",
    )
    stamped = data.assign(HOUR=data["USAGE_TIME"].dt.hour, DAY=data["USAGE_TIME"].dt.dayofweek)
    grid = stamped.pivot_table(index="DAY", columns="HOUR", values="CREDITS", aggfunc="sum", fill_value=0.0)
    grid = grid.reindex(index=range(7), columns=range(24), fill_value=0.0)
    fig = go.Figure(
        go.Heatmap(
            z=grid.values.tolist(), x=[f"{h:02d}" for h in range(24)],
            y=["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"],
            colorscale=[[0, "rgba(34,211,238,0.03)"], [0.35, "#1e3a8a"], [0.7, VIOLET], [1, PINK]],
            xgap=3, ygap=3, showscale=False,
            hovertemplate="%{y} %{x}:00 UTC<br>%{z:.4f} credits<extra></extra>",
        )
    )
    fig.update_yaxes(autorange="reversed")
    show(styled(fig, 260))

    heading("By interface")
    by_interface = (
        data.groupby("INTERFACE")
        .agg(Chats=("THREAD_ID", "nunique"), Requests=("CREDITS", "size"), Credits=("CREDITS", "sum"))
        .sort_values("Credits", ascending=False)
        .reset_index()
    )
    table(
        [
            {
                "interface": chip(row["INTERFACE"], CYAN),
                "chats": f"{int(row['Chats']):,}",
                "requests": f"{int(row['Requests']):,}",
                "credits": f"{row['Credits']:,.4f}",
                "share": f"{(100 * row['Credits'] / total_credits if total_credits else 0):.1f}%"
                + meter(100 * row["Credits"] / total_credits if total_credits else 0),
            }
            for _, row in by_interface.iterrows()
        ],
        [("Interface", "interface", "raw"), ("Chats", "chats", "num"), ("Requests", "requests", "num"),
         ("Credits", "credits", "num"), ("Share", "share", "raw")],
    )

# ------------------------------------------------------------------ chats frame
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
    chats["Chat name"] = chats["Chat name"].fillna("")
    chats["Tokens"] = chats["Tokens"].astype("int64")
    chats = chats.sort_values("Credits", ascending=False).reset_index(drop=True)
max_chat_credits = float(chats["Credits"].max()) if not chats.empty else 0.0

if view == "Chats":
    heading(
        "Most expensive chats",
        "A chat has a name once its owner has synced their chat names, which the CoCo skill does for them.",
    )
    if chats.empty:
        st.info("No chats in this period.")
    else:
        top = chats.head(15).iloc[::-1]
        labels = [
            (row["Chat name"] or f"thread {row['Thread']}")[:52] + f"  ·  {row['User']}" for _, row in top.iterrows()
        ]
        fig = go.Figure(
            go.Bar(
                x=list(top["Credits"]), y=labels, orientation="h",
                marker=dict(color=list(top["Credits"]), colorscale=[[0, VIOLET], [1, CYAN]], line=dict(width=0)),
                customdata=list(zip(top["Thread"], top["Requests"], top["Tokens"])),
                hovertemplate="%{y}<br>thread %{customdata[0]}<br>%{x:.4f} credits, "
                "%{customdata[1]} requests, %{customdata[2]:,} tokens<extra></extra>",
            )
        )
        fig.update_xaxes(title_text="credits")
        show(styled(fig, max(300, 34 * len(top) + 60)))
        table(
            [
                {
                    "thread": str(row["Thread"]),
                    "name": row["Chat name"] or "unnamed",
                    "user": row["User"],
                    "interface": chip(row["Interface"], CYAN),
                    "started": row["Started"].strftime("%Y-%m-%d %H:%M"),
                    "requests": f"{int(row['Requests']):,}",
                    "tokens": f"{int(row['Tokens']):,}",
                    "credits": f"{row['Credits']:,.4f}"
                    + meter(100 * row["Credits"] / max_chat_credits if max_chat_credits else 0),
                    "cost": money(row["Credits"], price, currency),
                }
                for _, row in chats.head(50).iterrows()
            ],
            [("Thread", "thread", "dim"), ("Chat name", "name", "text"), ("User", "user", "text"),
             ("Interface", "interface", "raw"), ("Started (UTC)", "started", "dim"),
             ("Requests", "requests", "num"), ("Tokens", "tokens", "num"), ("Credits", "credits", "raw")]
            + ([("Cost", "cost", "num")] if price is not None else []),
        )
        with st.expander("All chats as a sortable table"):
            st.dataframe(chats.set_index("Thread"), use_container_width=True)

# ------------------------------------------------------------------ users
if view == "Users":
    heading("Usage per user", "Each block is a chat. Its size is what the chat cost.")
    if chats.empty:
        st.info("No chats in this period.")
    else:
        per_user = (
            chats.groupby("User")
            .agg(Chats=("Thread", "count"), Requests=("Requests", "sum"), Credits=("Credits", "sum"),
                 Top=("Credits", "max"))
            .sort_values("Credits", ascending=False)
            .reset_index()
        )
        tree = chats.head(400)
        user_names = list(per_user["User"])
        fig = go.Figure(
            go.Treemap(
                labels=user_names + [(n or f"thread {t}")[:40] for n, t in zip(tree["Chat name"], tree["Thread"])],
                ids=[f"u:{u}" for u in user_names] + [f"c:{t}" for t in tree["Thread"]],
                parents=[""] * len(user_names) + [f"u:{u}" for u in tree["User"]],
                values=[0] * len(user_names) + list(tree["Credits"]),
                marker=dict(
                    colors=[0] * len(user_names) + list(tree["Credits"]),
                    colorscale=[[0, "#111a3a"], [0.5, VIOLET], [1, PINK]],
                    line=dict(color=BG, width=2),
                ),
                textfont=dict(color="#ffffff"),
                hovertemplate="%{label}<br>%{value:.4f} credits<extra></extra>",
            )
        )
        show(styled(fig, 420))
        user_total = float(per_user["Credits"].sum())
        table(
            [
                {
                    "user": row["User"],
                    "chats": f"{int(row['Chats']):,}",
                    "requests": f"{int(row['Requests']):,}",
                    "credits": f"{row['Credits']:,.4f}" + meter(100 * row["Credits"] / user_total if user_total else 0),
                    "per_chat": f"{row['Credits'] / row['Chats']:,.4f}",
                    "top": f"{row['Top']:,.4f}",
                    "cost": money(row["Credits"], price, currency),
                }
                for _, row in per_user.iterrows()
            ],
            [("User", "user", "text"), ("Chats", "chats", "num"), ("Requests", "requests", "num"),
             ("Credits", "credits", "raw"), ("Credits per chat", "per_chat", "num"),
             ("Most expensive chat", "top", "num")]
            + ([("Cost", "cost", "num")] if price is not None else []),
        )

# ------------------------------------------------------------------ savings
if view == "Savings":
    heading(
        "What could have been saved",
        "Last 30 days. Estimates and upper bounds, not promises. The three figures overlap; do not add them up.",
    )
    savings = load_savings()
    if picked_users:
        savings = savings[savings["USER_NAME"].isin(picked_users)]
    if savings.empty:
        st.info("No chats in the last 30 days.")
    else:
        spent = float(savings["CREDITS"].sum())
        quick = float(savings["QUICK_RESTART_SAVING"].sum())
        idle = float(savings["IDLE_RELOAD_SAVING"].sum())
        slim_low = float(savings["SLIM_SAVING_LOW"].sum())
        slim_high = float(savings["SLIM_SAVING_HIGH"].sum())
        cards(
            [
                card("Follow-ups, not new chats", f"{quick:,.2f}",
                     f"{int(savings['QUICK_RESTARTS'].sum())} chats started within 5 min of the previous one",
                     PINK, bar=100 * quick / spent if spent else 0, unit="credits"),
                card("No long pauses in a chat", f"{idle:,.2f}",
                     f"{int(savings['IDLE_RELOADS'].sum())} chats resumed after the cache expired",
                     AMBER, bar=100 * idle / spent if spent else 0, unit="credits"),
                card("/slim in CoCo CLI", f"{slim_low:,.2f} - {slim_high:,.2f}",
                     "20 or all bundled skills turned off", GREEN,
                     bar=100 * slim_high / spent if spent else 0, unit="credits"),
            ],
            three=True,
        )
        fig = go.Figure()
        fig.add_trace(go.Bar(
            x=[spent], y=["Spent"], orientation="h", marker=dict(color="rgba(120,160,255,0.28)"),
            hovertemplate="Spent: %{x:.2f} credits<extra></extra>", showlegend=False))
        for label, value, color in [
            ("Follow-ups", quick, PINK), ("No long pauses", idle, AMBER), ("/slim (up to)", slim_high, GREEN)
        ]:
            fig.add_trace(go.Bar(
                x=[value], y=[label], orientation="h", marker=dict(color=color),
                hovertemplate=label + ": up to %{x:.2f} credits<extra></extra>", showlegend=False))
        fig.update_xaxes(title_text="credits")
        fig.update_yaxes(autorange="reversed")
        show(styled(fig, 240))
        table(
            [
                {
                    "user": row["USER_NAME"],
                    "credits": f"{row['CREDITS']:,.4f}",
                    "cold": f"{int(row['COLD_STARTS']):,}",
                    "quick": f"{row['QUICK_RESTART_SAVING']:,.4f}",
                    "idle": f"{row['IDLE_RELOAD_SAVING']:,.4f}",
                    "slim": f"{row['SLIM_SAVING_LOW']:,.4f} - {row['SLIM_SAVING_HIGH']:,.4f}",
                }
                for _, row in savings.sort_values("CREDITS", ascending=False).iterrows()
            ],
            [("User", "user", "text"), ("Credits spent", "credits", "num"), ("Cold starts", "cold", "num"),
             ("Follow-ups saving", "quick", "num"), ("Pauses saving", "idle", "num"), ("/slim saving", "slim", "num")],
        )

# ------------------------------------------------------------------ one chat
if view == "Chat explorer":
    heading("Chat explorer", "Pick a chat to see every request in it and what made it expensive.")
    if chats.empty:
        st.info("No chats in this period.")
    else:
        pool = chats.head(300)
        labels = {
            int(row["Thread"]): f"{row['Credits']:.4f} credits  |  {row['Chat name'] or 'unnamed'}  |  "
            f"{row['User']}  |  thread {int(row['Thread'])}"
            for _, row in pool.iterrows()
        }
        thread = st.selectbox("Chat", list(labels.keys()), format_func=lambda t: labels[t])
        one = in_chats[in_chats["THREAD_ID"] == thread].sort_values("REQUEST_NO").copy()
        one["RUNNING"] = one["CREDITS"].cumsum()
        chosen = pool[pool["Thread"] == thread].iloc[0]
        cards(
            [
                card("Credits", f"{chosen['Credits']:,.4f}", money(chosen["Credits"], price, currency), CYAN),
                card("Requests", f"{int(chosen['Requests']):,}", chosen["Interface"], VIOLET),
                card("Tokens", f"{int(chosen['Tokens']):,}", chosen["User"], BLUE),
            ],
            three=True,
        )
        fig = go.Figure()
        fig.add_trace(
            go.Bar(
                x=[int(n) for n in one["REQUEST_NO"]], y=list(one["CREDITS"]), name="Credits per request",
                marker=dict(color=[REQUEST_KIND_COLORS.get(k, CYAN) for k in one["REQUEST_KIND"]]),
                customdata=list(zip(one["REQUEST_KIND"], one["TOTAL_TOKENS"])),
                hovertemplate="Request %{x}<br>%{y:.4f} credits<br>%{customdata[0]}, "
                "%{customdata[1]:,.0f} tokens<extra></extra>",
            )
        )
        fig.add_trace(
            go.Scatter(
                x=[int(n) for n in one["REQUEST_NO"]], y=list(one["RUNNING"]), name="Running total",
                mode="lines+markers", yaxis="y2", line=dict(color="#ffffff", width=2, shape="spline"),
                marker=dict(size=6, color="#ffffff"),
                hovertemplate="After request %{x}: %{y:.4f} credits<extra></extra>",
            )
        )
        fig.update_layout(
            yaxis=dict(title="credits per request"),
            yaxis2=dict(title="running total", overlaying="y", side="right", showgrid=False),
            xaxis=dict(title="request", dtick=1),
        )
        show(styled(fig, 360))
        st.markdown(
            " ".join(chip(kind, color) for kind, color in REQUEST_KIND_COLORS.items() if kind != "background"),
            unsafe_allow_html=True,
        )
        table(
            [
                {
                    "no": str(int(row["REQUEST_NO"])),
                    "time": row["USAGE_TIME"].strftime("%Y-%m-%d %H:%M:%S"),
                    "kind": chip(row["REQUEST_KIND"], REQUEST_KIND_COLORS.get(row["REQUEST_KIND"], CYAN)),
                    "idle": "" if pd.isna(row["SECONDS_SINCE_PREVIOUS"]) else f"{int(row['SECONDS_SINCE_PREVIOUS']):,}",
                    "write": f"{int(row['CACHE_WRITE_TOKENS']):,}",
                    "read": f"{int(row['CACHE_READ_TOKENS']):,}",
                    "out": f"{int(row['OUTPUT_TOKENS']):,}",
                    "credits": f"{row['CREDITS']:,.4f}",
                    "running": f"{row['RUNNING']:,.4f}",
                }
                for _, row in one.iterrows()
            ],
            [("#", "no", "dim"), ("Time (UTC)", "time", "dim"), ("Kind", "kind", "raw"),
             ("Idle before (s)", "idle", "num"), ("Cache write", "write", "num"), ("Cache read", "read", "num"),
             ("Output", "out", "num"), ("Credits", "credits", "num"), ("Running", "running", "num")],
        )

st.markdown(
    '<div class="ctm-foot">Source: SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY '
    "through the coco-token-meter views.</div>",
    unsafe_allow_html=True,
)
