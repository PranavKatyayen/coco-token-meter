# coco-token-meter

See what every Snowflake CoCo (Cortex Code) chat cost you, in tokens and
credits, and find out where the credits actually go.

CoCo shows how full the context window is. It does not show what a chat cost.
This project adds that, for CoCo in Snowsight and for the CoCo CLI:

- **Per-chat usage**: tokens and credits for each chat, split into fresh
  input, cache read, cache write and output.
- **Request-by-request view** of any chat, with running totals.
- **The previous chat's usage**, shown automatically when you start a new chat
  in the CLI.
- **Where your credits went** over the last 30 days, and which habits cost the
  most.
- **Lean mode**, a set of working rules that keeps CoCo from pulling more into
  a chat than the task needs.

It is a set of views over Snowflake's own usage history, two skills, two slash
commands and one hook. There is no service to run and nothing is copied out of
your account.

## Example

```
> /tokens top

| Thread ID | Interface | Started (UTC)    | Requests | Total tokens | Credits |
|-----------|-----------|------------------|----------|--------------|---------|
| 93082116  | snowsight | 2026-10-24 05:19 | 10       | 1,560,580    | 0.9664  |
| 93082240  | snowsight | 2026-11-07 18:01 | 9        | 1,401,796    | 0.8478  |
| 93082124  | snowsight | 2026-10-24 06:39 | 3        | 448,979      | 0.3254  |
```

When you start a new CLI chat, the first reply begins with one line about the
chat before it:

```
[coco-token-meter] Previous chat "What is the Product of 17 and 23?" (thread 23829020961):
82,774 tokens (cache write 82,662, cache read 0, fresh input 4, output 108),
about 0.2285 credits (estimate). Run /tokens for billed figures.
```

## Install

There are three parts. Part 1 is done once per account by an administrator.
Parts 2 and 3 are done by each user, for the CLI, Snowsight or both.

You need the [Snowflake CLI](https://docs.snowflake.com/en/developer-guide/snowflake-cli/index)
(`snow`) for parts 1 and 3.

```bash
git clone https://github.com/PranavKatyayen/coco-token-meter.git
```

```bash
cd coco-token-meter
```

### 1. Create the views (once per account)

Run as a role that can read `SNOWFLAKE.ACCOUNT_USAGE` and create a database
and roles. `ACCOUNTADMIN` is the simple choice.

```bash
snow sql -c <connection> -f sql/setup.sql
```

This creates the database `COCO_TOKEN_METER` and two roles:

| Role | Sees |
|---|---|
| `COCO_TOKEN_METER_USER` | only the chats of the user running the query |
| `COCO_TOKEN_METER_ADMIN` | every user's chats |

Grant them. To let everyone see their own usage:

```sql
GRANT ROLE COCO_TOKEN_METER_USER TO ROLE PUBLIC;
```

Users do not need access to `SNOWFLAKE.ACCOUNT_USAGE`. They do need a
warehouse to run the queries on.

### 2. CoCo CLI

```bash
cortex plugin install PranavKatyayen/coco-token-meter
```

This adds the `/tokens`, `/lean` and `/slim` commands and their skills. Install and uninstall from GitHub were tested with CoCo CLI 1.2.45 on Windows. Slash commands are not expanded in headless `-p` mode, where the skills answer instead. Restart CoCo or run `/plugin reload`.

### 3. CoCo in Snowsight

Each user runs this once from the repository root. It copies the two skills
into your Snowsight personal workspace, under `.snowflake/cortex/skills/`.

```bash
snow sql -c <connection> -f sql/install_snowsight_skills.sql
```

Then ask CoCo in Snowsight, for example: *show my CoCo token usage per chat*.

## Use

| In the CLI | In Snowsight, ask | Shows |
|---|---|---|
| `/tokens` | "show my CoCo token usage" | your 20 most recent chats |
| `/tokens this` | "token usage for this chat" | the open chat, request by request |
| `/tokens last` | "usage of my previous chat" | the chat before this one |
| `/tokens 93082240` | "usage for thread 93082240" | one chat, request by request |
| `/tokens top` | "my most expensive chats" | your 10 most expensive chats |
| `/tokens tips` | "where do my CoCo credits go?" | credit split and what to change |
| `/tokens all` | "CoCo usage for all users" | all users (admin role) |
| `/lean` | "use lean mode" | turns lean mode on for the chat |
| `/lean <task>` | | does the task in lean mode |

You can also query the views directly:

```sql
SELECT * FROM COCO_TOKEN_METER.USAGE.MY_CHATS ORDER BY LAST_ACTIVITY_AT DESC;
```

## What the numbers mean

- A **chat** is one `THREAD_ID` in Snowflake's usage history.
- A **request** is one billed call inside a chat. One message from you can
  produce several requests: in the CLI, every step CoCo takes (each tool call)
  is its own request. In Snowsight, the two single-message chats we checked
  were one request each, with all their steps added together.
- **Cache write** tokens are context being stored in the model's prompt cache.
  **Cache read** tokens are that context being read back on a later request.
- A **context reload** is a request that paid to write the chat's whole
  context into the cache: at least 10,000 cache-write tokens that make up at
  least half of the request's credits.
- **Background usage** is requests Snowflake bills with no thread id. They are
  small and belong to no chat, so they are reported separately.

## What we measured

Everything below was measured on 2026-11-14 in one Enterprise trial account
(AWS Tokyo), with CoCo CLI 1.2.45, on the model CoCo picked by default
(`claude-opus-5-5`). Your rates, model and numbers can differ. Run
`/tokens tips` to see your own.

**The views match Snowflake's totals.** Requests, tokens and credits in
`REQUESTS` equal `SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY`
exactly, and the four-way token and credit split adds up to the total on
every row.

**Usage shows up fast.** Snowflake documents up to an hour of latency for the
usage views. In every check we made, a CLI request was visible in the views
within about a minute.

**Most of the money is cache writes, not answers.**

| Token category | Credits per million tokens | Share of all credits |
|---|---|---|
| Cache write | 2.75 | 76% |
| Output | 11.00 | 10% |
| Cache read | 0.11 | 13% |
| Fresh input | 2.20 | under 1% |

(Shares are from the account's first 62 requests, before our own testing
added many short chats.)

**A new chat costs about 0.23 credits before it does anything.** Every new
CLI chat started with about 84,000 tokens of fixed context (instructions and
tool definitions). Writing that to the cache cost about 0.23 credits. The
same context read back from the cache cost about 0.009 credits, 25 times
less.

**Starting a new chat right after another one usually does not avoid that
cost.** Of 40 new CLI chats started within two minutes of the previous chat,
27 paid the full context write again and 13 reused the cache. Inside a chat,
every follow-up request we saw reused the cache.

**The cache expires after a few minutes.** A repeat was still served from the
cache after 2.5 minutes idle and was not after 6.5 minutes. A Snowsight chat
resumed after 15 minutes idle paid 0.32 credits for one request, because its
whole history was written again.

**Loading fewer plugins, skills and MCP servers barely changes the cost.**
Starting the CLI with `--only-explicit-skills --only-explicit-plugins
--no-mcp` reduced the fixed context from 84,333 to 83,916 tokens.

**The CLI's own counters match the bill.** The token counts the CLI keeps
locally for each session equalled what Snowflake billed for that chat, and
the hook's credit estimate matched the billed credits to four decimals in the
chats we compared.

### What this means for your bill

1. Ask related questions as follow-ups in one chat. Each new chat is likely
   to cost another context write.
2. Finish a task without long pauses. After a few idle minutes the next
   request pays to write the whole chat again, and that grows with the chat.
3. When you return to a long chat after a break, a new chat with a short
   summary can cost less than resuming, because the new chat only writes the
   starting context.
4. Shorter answers save little on their own: output was about 10% of credits.

## Lean mode

`/lean` gives CoCo a short set of rules: ask SQL for the answer and not the
data, take fewer steps, and write less, without skipping any check the task
needs.

**Experimental, and so far it has not saved anything.** In two A/B tests (three runs and two runs per side, same task, all answers correct) lean mode cost the same or slightly more than normal mode: 0.055 to 0.090 credits per chat against 0.048 to 0.083, cold starts excluded. Output tokens did not drop. CoCo was already economical on these tasks. It may help on chats that pull in large query results; that is not measured yet.

## Slim (CoCo CLI)

`/slim` turns off bundled skills you never use, through the CLI setting `disableBundledSkills` in `~/.snowflake/cortex/settings.json`. The description of every bundled skill is loaded into every chat. Measured: 83,916 tokens of starting context with all 93 bundled skills, 70,091 with 20 disabled, 45,205 with all disabled. A disabled skill is only hidden; enable it again with `/slim enable <name>` or `/slim reset`.

## Previous-chat line (Windows, opt-in)

```bash
powershell -ExecutionPolicy Bypass -File hooks\enable-windows.ps1
```

Add `-Disable` to turn it off. It is opt-in because the hook is a PowerShell script and a failing hook prints an error on every message.

## For admins

Snowflake records CoCo usage per request, with a user and a thread id, but
gives no per-chat view of it. With the `COCO_TOKEN_METER_ADMIN` role you get
one:

```sql
-- Credits per user, and each user's most expensive chat
SELECT USER_NAME, COUNT(*) AS CHATS, ROUND(SUM(CREDITS), 4) AS CREDITS,
       ROUND(MAX(CREDITS), 4) AS MOST_EXPENSIVE_CHAT
FROM COCO_TOKEN_METER.USAGE.CHATS
GROUP BY USER_NAME ORDER BY CREDITS DESC;
```

In CoCo, ask "CoCo usage for all users" or "most expensive chat per user".

### Chat names

Snowflake's usage history has thread ids but no chat titles. Each user can
add the titles of their own chats:

```sql
CALL COCO_TOKEN_METER.USAGE.SYNC_MY_CHAT_TITLES();
```

The skill runs this for you before it lists chats. It reads the user's own
chats from Snowflake's Threads API and stores a name only for threads the
usage history says belong to that user. Chat names say what a chat was about
and admins can see them in `CHATS`; a user who never syncs shares none.

### Cost in money

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CREDIT_PRICE', '3');
```

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CURRENCY', 'USD');
```

Use the price you pay per credit. `CHATS`, `MY_CHATS` and `DAILY_USAGE` then
show a `COST` column. Pass `NULL` to remove a setting.

### Budget alerts (optional)

```bash
snow sql -c <connection> -f sql/alerts.sql
```

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('DAILY_USER_CREDIT_LIMIT', '5');
```

```sql
CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CHAT_CREDIT_LIMIT', '1');
```

```sql
ALTER ALERT COCO_TOKEN_METER.USAGE.COCO_BUDGET_ALERT RESUME;
```

Every hour the alert writes each new breach (a user over the daily limit, or
a chat over the chat limit) to `ALERT_LOG`. `BUDGET_BREACHES` shows what is
over a limit right now. The alert is created suspended and is serverless, so
it needs the `EXECUTE MANAGED ALERT` privilege. To also get an email, set
`ALERT_EMAIL_INTEGRATION` to an email notification integration and
`ALERT_EMAIL_TO` to the recipients. Email sending has not been tested.

## How it works

| Object | What it is |
|---|---|
| `REQUESTS` | one row per request, with token and credit split |
| `CHAT_REQUESTS` | requests inside chats, numbered, with running totals and idle time |
| `CHATS` | one row per chat, with `CHAT_NAME` and `COST` when available |
| `DAILY_USAGE` | per user, interface and day |
| `BACKGROUND_USAGE` | requests with no thread id |
| `MODEL_RATES` | credits per million tokens actually billed, by model and category |
| `SETTINGS`, `CHAT_TITLES` | small tables behind `SET_SETTING` and `SYNC_MY_CHAT_TITLES` |
| `BUDGET_BREACHES`, `ALERT_LOG`, `COCO_BUDGET_ALERT` | budget alerts, from `sql/alerts.sql` |
| `MY_CHATS`, `MY_CHAT_REQUESTS`, `MY_DAILY_USAGE`, `MY_BACKGROUND_USAGE` | the same, limited to `CURRENT_USER()` |

The usage views all read
`SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY`, once per query. On the
test account (223 requests) each view answered in 3 to 7 seconds on an X-Small
warehouse. Larger accounts have not been tested. The `MY_*` views are
secure views owned by the installing role.

`/tokens this` finds the open chat from the `CORTEX_THREAD_ID` environment
variable that CoCo sets for shell commands, in the CLI and in Snowsight.

The previous-chat hook runs on the first message of a chat. It reads the
token counters CoCo CLI keeps in `~/.snowflake/cortex/stats/usage.json`,
multiplies them by the rates in `hooks/rates.json`, and asks CoCo to print the
line. It does not connect to Snowflake. Update `hooks/rates.json` from
`MODEL_RATES` if your rates differ or you use another model; for a model with
no rate it prints tokens only.

## Limits

- **Snowsight was tested by hand, once.** On 2026-11-14 CoCo in Snowsight
  loaded the `coco-token-usage` skill from the workspace and answered "show
  my CoCo token usage per chat" and "where do my CoCo credits go" correctly.
  The role in use needs `COCO_TOKEN_METER_USER` or `COCO_TOKEN_METER_ADMIN`.
- **"This chat" shows nothing on the first message of a chat.** A request is
  recorded after it finishes, so a brand-new chat is not in the usage history
  yet. From the second message on it works, in the CLI and in Snowsight
  (both expose the thread id to shell commands; seen on 2026-11-14).
- **The previous-chat hook is Windows only for now.** It is a PowerShell
  script. macOS and Linux have not been tested.
- **Tested on Windows only**, with CoCo CLI 1.2.45.
- **Chat names depend on each user syncing them**, and use
  `_snowflake.send_snow_api_request`, an interface Snowflake does not document
  for this purpose. If it stops working, everything else still does.
- **Not live to the second.** The views are as fresh as Snowflake's usage
  history. The newest requests of the open chat can be missing.
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

## License

MIT
