# coco-token-meter

See what every Snowflake CoCo (Cortex Code) chat cost, in tokens, credits and
money, per chat and per user, and find out where the credits go.

## Before and after

Ask CoCo in Snowsight: **"token usage for this chat"**.

**Without coco-token-meter** it cannot tell you:

> I can't see a token count for this chat. My context doesn't include a
> per-conversation token meter, and I can't measure my own usage.

**With coco-token-meter** it answers from Snowflake's own billing data:

| Request | Time (UTC) | Total tokens | Cache read | Cache write | Output | Credits | Kind |
|---|---|---|---|---|---|---|---|
| 1 | 2026-11-14 17:32 | 240,020 | 156,440 | 81,936 | 1,636 | 0.2605 | cold start |

Ask **"where do my CoCo credits go?"** and you get the split, with the habits
that cost the most:

| Where it went | Credits | Share |
|---|---|---|
| Cold starts (49 new chats) | 10.66 | 75.6% |
| Idle reloads (3) | 0.86 | 6.1% |
| Cache reads | 1.25 | 8.9% |
| Output (answers) | 0.77 | 5.5% |

(Both are real answers from the test account.)

## What you get

- **Per-chat usage** for every chat, with its name: tokens and credits split
  into fresh input, cache read, cache write and output.
- **Request-by-request view** of any chat, with running totals and a label on
  the expensive requests (cold start, idle reload, large addition).
- **For admins**: credits per user, each user's most expensive chats, a
  dashboard, and a skill that sets Snowflake's daily credit limit per user.
- **Cost in money**, once you set what you pay per credit.
- **A savings estimate**: what follow-ups instead of new chats, fewer pauses,
  and `/slim` could have saved.
- **`/slim` for CoCo CLI**: turns off bundled skills you never use, which
  makes every chat cheaper.
- **The previous chat's usage** on the first message of a new CLI chat
  (Windows, opt-in).

It works in CoCo in Snowsight and in the CoCo CLI. Everything is views over
Snowflake's usage history plus a few skills. Nothing leaves your account.

## Install

There are two ways to install. Both create the same thing: the database
`COCO_TOKEN_METER` with the usage views, the admin dashboard and the CoCo
skills. Either is done once per account, by a role that can read
`SNOWFLAKE.ACCOUNT_USAGE` and create a database and roles (`ACCOUNTADMIN` is
the simple choice).

### A. From Snowsight (no CLI, nothing to download)

1. Open [`install_in_snowsight.sql`](install_in_snowsight.sql) on GitHub and
   copy the whole file (the "Copy raw file" button at the top right of the
   file view).
2. In Snowsight, open Projects > Workspaces > **+ Add new** > **SQL File** and
   paste it in.
3. At the top of the worksheet choose the role `ACCOUNTADMIN` and a warehouse.
4. Run all of it (the arrow next to Run > **Run All**). It takes a few
   minutes.

The last result says `coco-token-meter is installed` and how many chats it
found. The file also creates the dashboard on the warehouse you chose and
installs the skills for you. Run it again at any time to update.

### B. With the Snowflake CLI

You need the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
(`snow`) and a copy of this repository. Run these from the repository root:

```bash
snow sql -c <connection> -f sql/setup.sql
```

```bash
snow sql -c <connection> -f sql/dashboard.sql -D "warehouse=<warehouse>"
```

Then install the skills for yourself, in any Snowsight worksheet:

```sql
CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS(TRUE);
```

### After installing: give people access

| Role | Sees |
|---|---|
| `COCO_TOKEN_METER_USER` | only the chats of the user running the query |
| `COCO_TOKEN_METER_ADMIN` | every user's chats, settings and the dashboard |

To let everyone see their own usage:

```sql
GRANT ROLE COCO_TOKEN_METER_USER TO ROLE PUBLIC;
```

Users need no access to `SNOWFLAKE.ACCOUNT_USAGE`. They do need a warehouse.
### C. Native app (optional)

The same views and dashboard packaged as a Snowflake Native App, with the CLI:

```bash
snow app run -c <connection>
```

```sql
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO APPLICATION COCO_TOKEN_METER_APP;
```

```sql
CALL COCO_TOKEN_METER_APP.USAGE.ACTIVATE();
```

Then grant `COCO_TOKEN_METER_APP.APP_ADMIN` or `APP_USER` to your roles. The
app does not include chat names yet, and the skills look for
the SQL install first (see Limits).

### D. Skills for every other user

CoCo in Snowsight loads skills from each user's own workspace, which only
that user can write to. The installer does this for the person who runs it.
Every other user runs one statement in any Snowsight worksheet, once:

```sql
CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS();
```

Then they open a new CoCo chat and ask *show my CoCo token usage per chat*.
Admins add the limits skill with `INSTALL_MY_SKILLS(TRUE)`. To remove them,
`CALL COCO_TOKEN_METER.USAGE.UNINSTALL_MY_SKILLS();`. No CLI and no files are
needed; the user needs the `COCO_TOKEN_METER_USER` role.

With the Snowflake CLI and a clone of the repository, this does the same and
also installs the experimental lean-mode skill:

```bash
snow sql -c <connection> -f sql/install_snowsight_skills.sql
```

### E. Plugin for CoCo CLI

```bash
cortex plugin install PranavKatyayen/coco-token-meter
```

This adds the `/tokens`, `/slim`, `/limits` and `/lean` commands and their
skills.
Restart CoCo or run `/plugin reload`.

## Use

| In the CLI | In Snowsight, ask | Shows |
|---|---|---|
| `/tokens` | "show my CoCo token usage per chat" | your 20 most recent chats |
| `/tokens this` | "token usage for this chat" | the open chat, request by request |
| `/tokens last` | "usage of my previous chat" | the chat before this one |
| `/tokens 93082240` | "usage for thread 93082240" | one chat, request by request |
| `/tokens top` | "my most expensive chats" | your 10 most expensive chats |
| `/tokens tips` | "where do my CoCo credits go?" | credit split and what to change |
| `/tokens all` | "CoCo usage for all users" | all users (admin role) |
| `/slim` | | bundled skills you can turn off (CLI only) |
| `/limits` | "show the CoCo credit limits" | daily credit limit per user (admins) |

Or query the views directly:

```sql
SELECT * FROM COCO_TOKEN_METER.USAGE.MY_CHATS ORDER BY LAST_ACTIVITY_AT DESC;
```

## For admins

Snowflake records CoCo usage per request, with a user and a thread id, but
gives no per-chat view of it. With `COCO_TOKEN_METER_ADMIN` you get one:

```sql
SELECT USER_NAME, COUNT(*) AS CHATS, ROUND(SUM(CREDITS), 4) AS CREDITS,
       ROUND(MAX(CREDITS), 4) AS MOST_EXPENSIVE_CHAT
FROM COCO_TOKEN_METER.USAGE.CHATS
GROUP BY USER_NAME ORDER BY CREDITS DESC;
```

**Dashboard.** Open Projects > Streamlit >
"CoCo Token Meter" in Snowsight. It has an overview, the most expensive
chats, usage per user, the savings estimate, and a request-by-request view of
any chat. It shows every user's usage, so only the admin role can open it.

**Chat names.** Snowflake's usage history has thread ids but no chat titles.
Each user adds the titles of their own chats with one call, which the skill
makes for them before it lists chats:

```sql
CALL COCO_TOKEN_METER.USAGE.SYNC_MY_CHAT_TITLES();
```

It stores a name only for threads the usage history says belong to that user.
Chat names say what a chat was about and admins can see them; a user who
never syncs shares none.

**Cost in money.** Set the price you pay per credit, and `CHATS`, `MY_CHATS`
and `DAILY_USAGE` show a `COST` column:

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CREDIT_PRICE', '3');
```

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CURRENCY', 'USD');
```

**Credit limits per user.** Snowflake has a built-in daily CoCo credit limit
per user, one per surface (CLI, Snowsight, Desktop). The `coco-admin-limits`
skill reads and changes it from CoCo, and always shows the statement and asks
before changing anything. Ask, for example:

- "show the CoCo credit limits"
- "who is close to their CoCo limit?"
- "what daily limit should I set, based on usage?"
- "set a 10 credit daily CLI limit for user JSMITH"
- "block JSMITH from CoCo in Snowsight"

`ROLLING_24H_USAGE` shows credits per user and surface over the same rolling
24 hours the limit uses. For monthly limits, groups of users, or an automatic
action at the limit, use Snowflake's per-user quotas and budgets.

## What the numbers mean

- A **chat** is one `THREAD_ID` in Snowflake's usage history.
- A **request** is one billed call inside a chat. In the CLI every step CoCo
  takes (each tool call) is its own request. In Snowsight the single-message
  chats we checked were one request each, with their steps added together.
- **Cache write** tokens are context being stored in the model's prompt
  cache. **Cache read** tokens are that context read back on a later request.
- **REQUEST_KIND** labels requests that paid for a large cache write:
  `cold start` (first request of a chat), `idle reload` (chat resumed after
  2+ minutes idle, when the cache had expired) and `large addition` (a big
  tool result).
- **Background** requests carry no thread id. They are small and belong to no
  chat.

## What we measured

Measured on 2026-11-14 and 2026-11-15 in one Enterprise trial account (AWS
Tokyo), with CoCo CLI 1.2.45 and the model CoCo picked by default
(`claude-opus-5-5`). Your rates, model and numbers can differ. Ask
"where do my CoCo credits go?" to see your own.

**The views match Snowflake's totals.** Requests, tokens and credits equal
`SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY` exactly, and the token
and credit split adds up to the total on every row.

**Usage shows up fast.** Snowflake documents up to an hour of latency. In
every check we made, a request was visible within about a minute.

**Most of the money is cache writes, not answers.**

| Token category | Credits per million tokens | Share of credits |
|---|---|---|
| Cache write | 2.75 | 76% |
| Cache read | 0.11 | 13% |
| Output | 11.00 | 10% |
| Fresh input | 2.20 | under 1% |

(Shares are from the account's first 62 requests, before our own testing.)

**A new chat costs about 0.23 credits before it does anything.** A new CLI
chat started with about 84,000 tokens of fixed context, and a new Snowsight
chat with about 82,000. Writing that to the cache cost about 0.23 credits;
reading it back cost about 0.009.

**Starting a new chat right after another one usually does not avoid that
cost.** Of 40 new CLI chats started within two minutes of the previous one,
27 paid the full context write again. Inside a chat, every follow-up request
we saw reused the cache.

**The cache expires after a few minutes.** A repeat was still served from
the cache after 2.5 minutes idle and was not after 6.5 minutes. Chats
resumed after 7 and 15 minutes paid 0.26 to 0.32 credits for one request.

**Bundled skills are most of the CLI's fixed context.** Turning off 20 of the
93 bundled skills cut it from 83,916 to 70,091 tokens; turning off all of
them cut it to 45,205. `/slim` does this through the CLI setting
`disableBundledSkills`. A disabled skill is only hidden and can be enabled
again.

**Shorter answers do not save much.** A lean-mode skill that asks CoCo to
write and fetch less made no measurable difference in two A/B tests (0.055 to
0.090 credits per chat against 0.048 to 0.083, all answers correct). It is in
the repository as `/lean`, marked experimental.

**The CLI's own counters match the bill.** The token counts the CLI keeps
locally equalled what Snowflake billed, and the previous-chat estimate
matched billed credits to four decimals in the chats we compared.

### What this means for your bill

1. Ask related questions as follow-ups in one chat.
2. Finish a task without long pauses.
3. When you return to a long chat after a break, a new chat with a short
   summary can cost less than resuming.
4. In the CLI, run `/slim`.

## Previous-chat line (CoCo CLI on Windows, opt-in)

```bash
powershell -ExecutionPolicy Bypass -File hooks\enable-windows.ps1
```

On the first message of a new CLI chat, CoCo then starts its reply with the
previous chat's tokens and an estimate of its credits. Add `-Disable` to turn
it off. It reads only local files the CLI writes and uses the rates in
`hooks/rates.json`.

## How it works

| Object | What it is |
|---|---|
| `REQUESTS` | one row per request, with token and credit split and `REQUEST_KIND` |
| `CHAT_REQUESTS` | the requests that belong to chats, numbered, with running totals |
| `CHATS` | one row per chat, with `CHAT_NAME` and `COST` when available |
| `DAILY_USAGE` | per user, interface and day |
| `BACKGROUND_USAGE` | requests with no thread id |
| `SAVINGS_ESTIMATE` | estimated avoidable credits per user, last 30 days |
| `MODEL_RATES` | credits per million tokens actually billed, by model and category |
| `MY_CHATS`, `MY_CHAT_REQUESTS`, `MY_DAILY_USAGE`, `MY_BACKGROUND_USAGE`, `MY_SAVINGS_ESTIMATE` | the same, limited to `CURRENT_USER()` |
| `SETTINGS`, `CHAT_TITLES` | small tables behind `SET_SETTING` and `SYNC_MY_CHAT_TITLES` |
| `ROLLING_24H_USAGE` | credits per user and surface over the past 24 hours |
| `COCO_TOKEN_METER_DASHBOARD` | the admin dashboard |
| `SKILLS_STAGE`, `INSTALL_MY_SKILLS` | skill files and the one-statement installer for users |

Every usage view reads
`SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY` once per query. On the
test account (223 requests) each answered in 3 to 7 seconds on an X-Small
warehouse. The `MY_*` views are secure views owned by the installing role.

"This chat" is found from the `CORTEX_THREAD_ID` environment variable that
CoCo sets for shell commands, in the CLI and in Snowsight.

## Limits

- **Tested in one small account.** A few hundred requests from four users,
  three of them temporary test users driving the CoCo CLI. Large accounts
  have not been tested.
- **A brand-new Snowflake user has no name at first.** Snowflake fills in the
  user name in its usage history a few minutes after the user's first
  request (about 10 minutes in our test; its user list can lag up to two
  hours). Until then the user appears as `(user id N)` and their own `MY_*`
  views are empty.
- **Tested on Windows only**, with CoCo CLI 1.2.45. macOS and Linux have not
  been tried, and the previous-chat line is a PowerShell script.
- **The dashboard's current design has not been reviewed in a browser.** Its
  code was run inside Snowflake against real data and every section produced
  output. It pins Streamlit 1.44.1 and Plotly 5.24.1 in `dashboard/environment.yml`.
- **Limits were tested at 0 and by setting and unsetting.** A user set to 0
  was blocked in the CLI with Snowflake's own message. A positive limit being
  reached was not tested. Limits must be whole numbers.
- **Slash commands were tested through their skills.** The CLI was run
  headless, where plugin commands are not expanded and the skills answer.
- **"This chat" shows nothing on the first message of a chat**, because a
  request is recorded after it finishes.
- **Chat names depend on each user syncing them**, and use
  `_snowflake.send_snow_api_request`, which Snowflake does not document for
  this purpose. If it stops working, everything else still does.
- **Savings are estimates and upper bounds.** The three figures overlap and
  must not be added up.
- **The native app has no chat names yet**, and the skills query
  `COCO_TOKEN_METER` first and fall back to `COCO_TOKEN_METER_APP`.
  `native-app/setup.sql` is generated from `sql/setup.sql`; keep them in step.
- **Not live to the second.** The views are as fresh as Snowflake's usage
  history.
- **Needs `SNOWFLAKE_COCO_USAGE_HISTORY`** in `SNOWFLAKE.ACCOUNT_USAGE`.

## Uninstall

```bash
cortex plugin uninstall coco-token-meter
```

```bash
snow sql -c <connection> -f sql/uninstall_snowsight_skills.sql
```

```bash
snow sql -c <connection> -f sql/teardown.sql
```

```bash
snow app teardown -c <connection>
```

## License

MIT
