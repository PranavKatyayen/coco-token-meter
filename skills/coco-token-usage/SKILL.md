---
name: coco-token-usage
description: Show CoCo (Cortex Code) token and credit usage per chat. Use when the user asks how many tokens or credits a chat used, asks for "token usage", "my chats", "usage for this chat", "which chat cost the most", or runs /tokens.
---

# CoCo token usage per chat

Report token and credit usage for CoCo chats from the `COCO_TOKEN_METER.USAGE`
views. Run the SQL below with your SQL tool. Do not estimate numbers and do not
read `SNOWFLAKE.ACCOUNT_USAGE` directly: the views already do that.

## Views

| View | Rows | Role needed |
|---|---|---|
| `MY_CHATS` | one per chat of the current user | `COCO_TOKEN_METER_USER` |
| `MY_CHAT_REQUESTS` | one per request inside those chats | `COCO_TOKEN_METER_USER` |
| `MY_BACKGROUND_USAGE` | requests billed outside any chat, per day | `COCO_TOKEN_METER_USER` |
| `CHATS`, `CHAT_REQUESTS`, `BACKGROUND_USAGE`, `REQUESTS` | the same for all users | `COCO_TOKEN_METER_ADMIN` |

- A chat is a `THREAD_ID`.
- A request is one billed call inside a chat. One user message can produce
  several requests, so never call a request a "message".
- `REQUEST_KIND` explains expensive requests: `cold start` (first request of
  a chat, starting context written to the cache), `idle reload` (chat resumed
  after the cache expired, whole chat written again), `large addition` (a lot
  of new content, usually a big tool result), otherwise `normal`.
- Token columns: `TOTAL_TOKENS`, `INPUT_TOKENS`, `CACHE_READ_TOKENS`,
  `CACHE_WRITE_TOKENS`, `OUTPUT_TOKENS`. Cost is `CREDITS`.
- `INTERFACE` says where the chat ran, for example `snowsight`, `cli` or
  `automation`.

Use the `MY_*` views unless the user asks about other users or the whole
account. If an all-users view fails with a privilege error, say it needs the
`COCO_TOKEN_METER_ADMIN` role and fall back to the `MY_*` view.

## Finding "this chat"

1. If you can run shell commands, read the environment variable
   `CORTEX_THREAD_ID` (`echo $CORTEX_THREAD_ID`, or `echo $env:CORTEX_THREAD_ID`
   in PowerShell). CoCo CLI sets it to the thread id of the open chat. Use it.
2. Otherwise (for example in Snowsight) use the user's most recently active
   chat, and say that this is what you did:

```sql
SELECT THREAD_ID FROM COCO_TOKEN_METER.USAGE.MY_CHATS
ORDER BY LAST_ACTIVITY_AT DESC LIMIT 1;
```

## Queries

**Recent chats** (default when no chat is named):

```sql
SELECT THREAD_ID, INTERFACE, STARTED_AT, LAST_ACTIVITY_AT, REQUESTS,
       TOTAL_TOKENS, INPUT_TOKENS, CACHE_READ_TOKENS, CACHE_WRITE_TOKENS,
       OUTPUT_TOKENS, ROUND(CREDITS, 4) AS CREDITS
FROM COCO_TOKEN_METER.USAGE.MY_CHATS
ORDER BY LAST_ACTIVITY_AT DESC
LIMIT 20;
```

**One chat, request by request** (for "this chat" or a given thread id):

```sql
SELECT REQUEST_NO, USAGE_TIME, TOTAL_TOKENS, INPUT_TOKENS, CACHE_READ_TOKENS,
       CACHE_WRITE_TOKENS, OUTPUT_TOKENS, ROUND(CREDITS, 4) AS CREDITS,
       RUNNING_TOKENS, ROUND(RUNNING_CREDITS, 4) AS RUNNING_CREDITS,
       REQUEST_KIND, MODELS
FROM COCO_TOKEN_METER.USAGE.MY_CHAT_REQUESTS
WHERE THREAD_ID = <thread_id>
ORDER BY REQUEST_NO;
```

**Most expensive chats:**

```sql
SELECT THREAD_ID, INTERFACE, STARTED_AT, REQUESTS, TOTAL_TOKENS,
       ROUND(CREDITS, 4) AS CREDITS
FROM COCO_TOKEN_METER.USAGE.MY_CHATS
ORDER BY CREDITS DESC
LIMIT 10;
```

**Usage outside any chat:**

```sql
SELECT USAGE_DATE, INTERFACE, REQUESTS, TOTAL_TOKENS, ROUND(CREDITS, 4) AS CREDITS
FROM COCO_TOKEN_METER.USAGE.MY_BACKGROUND_USAGE
ORDER BY USAGE_DATE DESC;
```

**The previous chat** ("last chat", "the chat before this one"): take the two
most recent rows of `MY_CHATS` by `LAST_ACTIVITY_AT`. If you know this chat's
thread id, the previous chat is the newest row with a different `THREAD_ID`.
Otherwise say which chat you picked.

**Where the credits go and how to spend less** ("tips", "why is it so
expensive", "how do I reduce cost"):

```sql
SELECT
  COUNT(DISTINCT THREAD_ID)                                              AS CHATS,
  COUNT(*)                                                               AS REQUESTS,
  ROUND(SUM(CREDITS), 4)                                                 AS CREDITS,
  ROUND(SUM(CACHE_WRITE_CREDITS), 4)                                     AS CACHE_WRITE_CREDITS,
  ROUND(SUM(CACHE_READ_CREDITS), 4)                                      AS CACHE_READ_CREDITS,
  ROUND(SUM(OUTPUT_CREDITS), 4)                                          AS OUTPUT_CREDITS,
  ROUND(SUM(INPUT_CREDITS), 4)                                           AS INPUT_CREDITS,
  COUNT_IF(REQUEST_KIND = 'cold start')                                  AS COLD_STARTS,
  ROUND(SUM(IFF(REQUEST_KIND = 'cold start', CACHE_WRITE_CREDITS, 0)), 4)     AS COLD_START_CREDITS,
  COUNT_IF(REQUEST_KIND = 'idle reload')                                 AS IDLE_RELOADS,
  ROUND(SUM(IFF(REQUEST_KIND = 'idle reload', CACHE_WRITE_CREDITS, 0)), 4)    AS IDLE_RELOAD_CREDITS,
  COUNT_IF(REQUEST_KIND = 'large addition')                              AS LARGE_ADDITIONS,
  ROUND(SUM(IFF(REQUEST_KIND = 'large addition', CACHE_WRITE_CREDITS, 0)), 4) AS LARGE_ADDITION_CREDITS
FROM COCO_TOKEN_METER.USAGE.MY_CHAT_REQUESTS
WHERE USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP());
```

Report each credit column as a share of `CREDITS`, largest first. Then give
only the tips the numbers support, most valuable first:

- `COLD_START_CREDITS`: what it cost to load the starting context at the
  beginning of chats. Divide by `COLD_STARTS` to show what one new chat costs
  before it does anything. If this is a large share: ask related questions as
  follow-ups in one chat instead of opening new chats, and in CoCo CLI run
  `/slim` to turn off bundled skills that are never used, which makes every
  chat's starting context smaller.
- `IDLE_RELOAD_CREDITS`: chats that were left idle for minutes and then
  resumed, so the whole chat was written to the cache again. If this is a
  large share: finish a task in one go, and when returning to a long chat
  after a break, consider a new chat with a short summary.
- `LARGE_ADDITION_CREDITS`: big tool results pulled into chats. If this is a
  large share: `/lean` asks CoCo to query for answers instead of raw data.
- `CACHE_READ_CREDITS`: the chat being re-read on every step. Large when
  chats are long and take many steps.
- `OUTPUT_CREDITS`: the answers themselves. Usually a small share; shorter
  answers save little.
- Do not promise a saving figure. State the shares and let the user decide.
## Presenting the result

- Show a table. Format token counts with thousands separators.
- Under a per-request table, add one line with the chat total: requests,
  total tokens, credits.
- Always add this note: the numbers come from Snowflake's usage history, which
  lags behind, so the newest requests (including this one) may be missing.
- `CACHE_READ_TOKENS` is context re-read from cache on each request. It is
  usually most of the total and is billed at a lower rate than fresh input.
  Mention this if the user is surprised by the size of the numbers.

## If the views are missing

If a query fails because `COCO_TOKEN_METER` does not exist or is not
authorized, do not try to create it. Tell the user that an administrator has
to run `sql/setup.sql` from the coco-token-meter repository once and grant
them the `COCO_TOKEN_METER_USER` role.
