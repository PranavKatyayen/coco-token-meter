-- ===========================================================================
-- coco-token-meter: install from a Snowsight worksheet. No CLI needed.
--
--   1. In Snowsight open Projects > Workspaces > + Add new > SQL File.
--   2. Paste this whole file into it.
--   3. At the top of the worksheet choose the role ACCOUNTADMIN (or another
--      role that can read SNOWFLAKE.ACCOUNT_USAGE and create a database and
--      roles) and a warehouse.
--   4. Run all of it (the arrow next to Run > Run All).
--
-- It creates the database COCO_TOKEN_METER with the usage views, the admin
-- dashboard, and the CoCo skills, and installs the skills for you. The last
-- result tells you what to do next. Safe to run again to update.
--
-- Other users then install the skill for themselves with one statement:
--   CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS();
--
-- GENERATED FILE. Do not edit it; change sql/setup.sql, the skills or the
-- dashboard and run tools/build_snowsight_install.ps1.
-- ===========================================================================
-- coco-token-meter: per-chat token and credit usage for Snowflake CoCo
-- (Cortex Code), in Snowsight, the CLI and anywhere else CoCo runs.
--
-- Run once as a role that can read SNOWFLAKE.ACCOUNT_USAGE and create a
-- database and roles (ACCOUNTADMIN is the simple choice):
--
--   snow sql -c <connection> -f sql/setup.sql
--
-- Everything lives in the database COCO_TOKEN_METER. Nothing is copied: these
-- are views over SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY, so they
-- cost nothing until somebody queries them. Safe to re-run.

CREATE DATABASE IF NOT EXISTS COCO_TOKEN_METER
  COMMENT = 'coco-token-meter: per-chat token and credit usage for Snowflake CoCo';
CREATE SCHEMA IF NOT EXISTS COCO_TOKEN_METER.USAGE;
USE SCHEMA COCO_TOKEN_METER.USAGE;

-- ---------------------------------------------------------------------------
-- SETTINGS: optional key/value settings, changed with SET_SETTING.
--   CREDIT_PRICE      what you pay for one credit; turns credits into COST
--   CURRENCY          label for COST, for example USD
-- CHAT_TITLES: chat names, filled by SYNC_MY_CHAT_TITLES. Snowflake's usage
-- history has thread ids only, so names are fetched per user on request.
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS SETTINGS (
  KEY        STRING NOT NULL,
  VALUE      STRING,
  UPDATED_AT TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
  UPDATED_BY STRING
);

CREATE TABLE IF NOT EXISTS CHAT_TITLES (
  THREAD_ID          NUMBER NOT NULL,
  USER_NAME          STRING,
  CHAT_NAME          STRING,
  ORIGIN_APPLICATION STRING,
  SYNCED_AT          TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP()
);

-- ---------------------------------------------------------------------------
-- REQUESTS: one row per CoCo request, all users. A request is one billed
-- call; a single chat message can produce several of them.
--
-- TOKENS_GRANULAR and CREDITS_GRANULAR are {model: {input, cache_read_input,
-- cache_write_input, output}}. A request can use more than one model, so the
-- split is summed over models. The usage history is read once per query:
-- every other view is built on this one.
--
-- Snowflake fills in USER_NAME from its user list, which can run up to two
-- hours behind. Until then a new user's requests have no name; they are shown
-- as '(user id N)' and that user's MY_* views stay empty.
--
-- For requests that belong to a chat (THREAD_ID is not null) the view also
-- numbers them, gives the idle time before each one, running totals, and
-- REQUEST_KIND, which explains requests that paid for a large cache write
-- (at least 10,000 cache-write tokens making up at least half of the
-- request's credits):
--   'cold start'     first request of a chat: the starting context was
--                    written to the prompt cache
--   'idle reload'    later request after 2+ minutes idle: the cache had
--                    expired and the chat so far was written again
--   'large addition' later request with no idle gap: a lot of new content
--                    (usually a big tool result) was added to the chat
--   'normal'         everything else in a chat
--   'background'     requests with no THREAD_ID; they belong to no chat
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW REQUESTS
  COMMENT = 'One row per CoCo request with token and credit split and REQUEST_KIND. All users.'
AS
WITH split AS (
  SELECT
    u.REQUEST_ID,
    ANY_VALUE(u.THREAD_ID)                              AS THREAD_ID,
    ANY_VALUE(u.PARENT_REQUEST_ID)                      AS PARENT_REQUEST_ID,
    ANY_VALUE(COALESCE(u.USER_NAME, '(user id ' || u.USER_ID || ')')) AS USER_NAME,
    ANY_VALUE(u.INTERFACE)                              AS INTERFACE,
    ANY_VALUE(u.USAGE_TIME)                             AS USAGE_TIME,
    ANY_VALUE(u.TOKENS)                                 AS TOTAL_TOKENS,
    ANY_VALUE(u.TOKEN_CREDITS)                          AS CREDITS,
    ANY_VALUE(u.METADATA:role_name::STRING)             AS ROLE_NAME,
    ANY_VALUE(u.METADATA:trigger_type::STRING)          AS TRIGGER_TYPE,
    SUM(COALESCE(m.value:input::NUMBER, 0))             AS INPUT_TOKENS,
    SUM(COALESCE(m.value:cache_read_input::NUMBER, 0))  AS CACHE_READ_TOKENS,
    SUM(COALESCE(m.value:cache_write_input::NUMBER, 0)) AS CACHE_WRITE_TOKENS,
    SUM(COALESCE(m.value:output::NUMBER, 0))            AS OUTPUT_TOKENS,
    SUM(COALESCE(u.CREDITS_GRANULAR[m.key]:input::NUMBER(38,9), 0))             AS INPUT_CREDITS,
    SUM(COALESCE(u.CREDITS_GRANULAR[m.key]:cache_read_input::NUMBER(38,9), 0))  AS CACHE_READ_CREDITS,
    SUM(COALESCE(u.CREDITS_GRANULAR[m.key]:cache_write_input::NUMBER(38,9), 0)) AS CACHE_WRITE_CREDITS,
    SUM(COALESCE(u.CREDITS_GRANULAR[m.key]:output::NUMBER(38,9), 0))            AS OUTPUT_CREDITS,
    ARRAY_AGG(DISTINCT m.key::STRING) WITHIN GROUP (ORDER BY m.key::STRING)     AS MODELS
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY u,
       LATERAL FLATTEN(INPUT => u.TOKENS_GRANULAR, OUTER => TRUE) m
  GROUP BY u.REQUEST_ID
),
numbered AS (
  SELECT
    s.*,
    IFF(THREAD_ID IS NULL, NULL,
        ROW_NUMBER() OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID)) AS REQUEST_NO,
    IFF(THREAD_ID IS NULL, NULL,
        DATEDIFF('second',
                 LAG(USAGE_TIME) OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID),
                 USAGE_TIME))                                                       AS SECONDS_SINCE_PREVIOUS,
    IFF(THREAD_ID IS NULL, NULL,
        SUM(TOTAL_TOKENS) OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS RUNNING_TOKENS,
    IFF(THREAD_ID IS NULL, NULL,
        SUM(CREDITS)      OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID
                                ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)) AS RUNNING_CREDITS,
    (CACHE_WRITE_TOKENS >= 10000 AND CACHE_WRITE_CREDITS >= 0.5 * CREDITS)         AS IS_LARGE_CACHE_WRITE
  FROM split s
)
SELECT
  THREAD_ID,
  REQUEST_NO,
  REQUEST_ID,
  PARENT_REQUEST_ID,
  USER_NAME,
  INTERFACE,
  USAGE_TIME,
  SECONDS_SINCE_PREVIOUS,
  TOTAL_TOKENS,
  INPUT_TOKENS,
  CACHE_READ_TOKENS,
  CACHE_WRITE_TOKENS,
  OUTPUT_TOKENS,
  CREDITS,
  INPUT_CREDITS,
  CACHE_READ_CREDITS,
  CACHE_WRITE_CREDITS,
  OUTPUT_CREDITS,
  CASE
    WHEN THREAD_ID IS NULL             THEN 'background'
    WHEN NOT IS_LARGE_CACHE_WRITE      THEN 'normal'
    WHEN REQUEST_NO = 1                THEN 'cold start'
    WHEN SECONDS_SINCE_PREVIOUS >= 120 THEN 'idle reload'
    ELSE 'large addition'
  END AS REQUEST_KIND,
  RUNNING_TOKENS,
  RUNNING_CREDITS,
  MODELS,
  ROLE_NAME,
  TRIGGER_TYPE
FROM numbered;

-- ---------------------------------------------------------------------------
-- CHAT_REQUESTS: the requests that belong to a chat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW CHAT_REQUESTS
  COMMENT = 'One row per request inside a chat, with running totals and REQUEST_KIND. All users.'
AS
SELECT * EXCLUDE (PARENT_REQUEST_ID)
FROM REQUESTS
WHERE THREAD_ID IS NOT NULL;
-- ---------------------------------------------------------------------------
-- CHATS: one row per chat (THREAD_ID).
-- CHAT_NAME is filled once the chat's owner has run SYNC_MY_CHAT_TITLES.
-- COST is CREDITS x the CREDIT_PRICE setting, or NULL when no price is set.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW CHATS
  COMMENT = 'One row per CoCo chat (THREAD_ID) with token, credit and cost totals. All users.'
AS
WITH agg AS (
  SELECT
    THREAD_ID,
    MIN(USER_NAME)           AS USER_NAME,
    MIN(INTERFACE)           AS INTERFACE,
    MIN(USAGE_TIME)          AS STARTED_AT,
    MAX(USAGE_TIME)          AS LAST_ACTIVITY_AT,
    COUNT(*)                 AS REQUESTS,
    SUM(TOTAL_TOKENS)        AS TOTAL_TOKENS,
    SUM(INPUT_TOKENS)        AS INPUT_TOKENS,
    SUM(CACHE_READ_TOKENS)   AS CACHE_READ_TOKENS,
    SUM(CACHE_WRITE_TOKENS)  AS CACHE_WRITE_TOKENS,
    SUM(OUTPUT_TOKENS)       AS OUTPUT_TOKENS,
    SUM(CREDITS)             AS CREDITS,
    SUM(INPUT_CREDITS)       AS INPUT_CREDITS,
    SUM(CACHE_READ_CREDITS)  AS CACHE_READ_CREDITS,
    SUM(CACHE_WRITE_CREDITS) AS CACHE_WRITE_CREDITS,
    SUM(OUTPUT_CREDITS)      AS OUTPUT_CREDITS,
    SUM(IFF(REQUEST_KIND = 'cold start', CACHE_WRITE_CREDITS, 0))     AS COLD_START_CREDITS,
    COUNT_IF(REQUEST_KIND = 'idle reload')                            AS IDLE_RELOADS,
    SUM(IFF(REQUEST_KIND = 'idle reload', CACHE_WRITE_CREDITS, 0))    AS IDLE_RELOAD_CREDITS,
    COUNT_IF(REQUEST_KIND = 'large addition')                         AS LARGE_ADDITIONS,
    SUM(IFF(REQUEST_KIND = 'large addition', CACHE_WRITE_CREDITS, 0)) AS LARGE_ADDITION_CREDITS,
    MAX(TOTAL_TOKENS)        AS LARGEST_REQUEST_TOKENS
  FROM CHAT_REQUESTS
  GROUP BY THREAD_ID
),
titles AS (
  SELECT THREAD_ID, CHAT_NAME
  FROM CHAT_TITLES
  QUALIFY ROW_NUMBER() OVER (PARTITION BY THREAD_ID ORDER BY SYNCED_AT DESC) = 1
)
SELECT
  a.THREAD_ID,
  t.CHAT_NAME,
  a.* EXCLUDE (THREAD_ID),
  ROUND(a.CREDITS * (SELECT TRY_TO_DOUBLE(MAX(VALUE)) FROM SETTINGS WHERE KEY = 'CREDIT_PRICE'), 4) AS COST,
  (SELECT MAX(VALUE) FROM SETTINGS WHERE KEY = 'CURRENCY')                                         AS CURRENCY
FROM agg a
LEFT JOIN titles t ON t.THREAD_ID = a.THREAD_ID;
-- ---------------------------------------------------------------------------
-- BACKGROUND_USAGE: requests CoCo bills that carry no THREAD_ID, per user,
-- interface and day. They cannot be attributed to a chat.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW BACKGROUND_USAGE
  COMMENT = 'CoCo requests with no THREAD_ID, per user, interface and day. All users.'
AS
SELECT
  USER_NAME,
  INTERFACE,
  USAGE_TIME::DATE  AS USAGE_DATE,
  COUNT(*)          AS REQUESTS,
  SUM(TOTAL_TOKENS) AS TOTAL_TOKENS,
  SUM(CREDITS)      AS CREDITS
FROM REQUESTS
WHERE THREAD_ID IS NULL
GROUP BY USER_NAME, INTERFACE, USAGE_TIME::DATE;

-- ---------------------------------------------------------------------------
-- DAILY_USAGE: everything CoCo billed per user, interface and day, with the
-- credit split, so you can see what the money is spent on.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW DAILY_USAGE
  COMMENT = 'CoCo usage per user, interface and day with credit split. All users.'
AS
SELECT
  USER_NAME,
  INTERFACE,
  USAGE_TIME::DATE           AS USAGE_DATE,
  COUNT(DISTINCT THREAD_ID)  AS CHATS,
  COUNT(*)                   AS REQUESTS,
  SUM(TOTAL_TOKENS)          AS TOTAL_TOKENS,
  SUM(CREDITS)               AS CREDITS,
  SUM(INPUT_CREDITS)         AS INPUT_CREDITS,
  SUM(CACHE_READ_CREDITS)    AS CACHE_READ_CREDITS,
  SUM(CACHE_WRITE_CREDITS)   AS CACHE_WRITE_CREDITS,
  SUM(OUTPUT_CREDITS)        AS OUTPUT_CREDITS,
  COUNT_IF(REQUEST_KIND = 'cold start')                           AS COLD_STARTS,
  SUM(IFF(REQUEST_KIND = 'cold start', CACHE_WRITE_CREDITS, 0))   AS COLD_START_CREDITS,
  COUNT_IF(REQUEST_KIND = 'idle reload')                          AS IDLE_RELOADS,
  SUM(IFF(REQUEST_KIND = 'idle reload', CACHE_WRITE_CREDITS, 0))  AS IDLE_RELOAD_CREDITS,
  ROUND(SUM(CREDITS) * (SELECT TRY_TO_DOUBLE(MAX(VALUE)) FROM SETTINGS WHERE KEY = 'CREDIT_PRICE'), 4) AS COST,
  (SELECT MAX(VALUE) FROM SETTINGS WHERE KEY = 'CURRENCY')        AS CURRENCY
FROM REQUESTS
GROUP BY USER_NAME, INTERFACE, USAGE_TIME::DATE;
-- ---------------------------------------------------------------------------
-- SAVINGS_ESTIMATE: per user, last 30 days, what three changes of habit could
-- have saved. These are estimates and upper bounds, not promises.
--   QUICK_RESTART_SAVING  chats started cold within 5 minutes of the same
--                         user's previous chat on the same interface. As a
--                         follow-up in that chat the starting context would
--                         have been read from the cache instead of written.
--   IDLE_RELOAD_SAVING    chats resumed after the cache expired.
--   SLIM_SAVING_LOW/HIGH  CoCo CLI cold starts with 20 / all bundled skills
--                         turned off (16% / 46% less starting context,
--                         measured with CoCo CLI 1.2.45).
-- 0.96 is the share saved when context is read from the cache instead of
-- written (cache read 0.11 vs cache write 2.75 credits per million tokens).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW SAVINGS_ESTIMATE
  COMMENT = 'Estimated avoidable CoCo credits per user over the last 30 days. All users.'
AS
WITH chat AS (
  SELECT
    THREAD_ID,
    MIN(USER_NAME)   AS USER_NAME,
    MIN(INTERFACE)   AS INTERFACE,
    MIN(USAGE_TIME)  AS STARTED_AT,
    MAX(USAGE_TIME)  AS LAST_ACTIVITY_AT,
    SUM(CREDITS)     AS CREDITS,
    SUM(IFF(REQUEST_KIND = 'cold start', CACHE_WRITE_CREDITS, 0))  AS COLD_START_CREDITS,
    COUNT_IF(REQUEST_KIND = 'idle reload')                         AS IDLE_RELOADS,
    SUM(IFF(REQUEST_KIND = 'idle reload', CACHE_WRITE_CREDITS, 0)) AS IDLE_RELOAD_CREDITS
  FROM REQUESTS
  WHERE THREAD_ID IS NOT NULL
    AND USAGE_TIME >= DATEADD('day', -30, CURRENT_TIMESTAMP())
  GROUP BY THREAD_ID
),
seq AS (
  SELECT
    c.*,
    DATEDIFF('second',
             LAG(LAST_ACTIVITY_AT) OVER (PARTITION BY USER_NAME, INTERFACE ORDER BY STARTED_AT),
             STARTED_AT) AS SECONDS_AFTER_PREVIOUS_CHAT
  FROM chat c
)
SELECT
  USER_NAME,
  COUNT(*)                                   AS CHATS,
  ROUND(SUM(CREDITS), 4)                     AS CREDITS,
  COUNT_IF(COLD_START_CREDITS > 0)           AS COLD_STARTS,
  ROUND(SUM(COLD_START_CREDITS), 4)          AS COLD_START_CREDITS,
  COUNT_IF(COLD_START_CREDITS > 0 AND SECONDS_AFTER_PREVIOUS_CHAT BETWEEN 0 AND 300) AS QUICK_RESTARTS,
  ROUND(0.96 * SUM(IFF(COLD_START_CREDITS > 0 AND SECONDS_AFTER_PREVIOUS_CHAT BETWEEN 0 AND 300,
                       COLD_START_CREDITS, 0)), 4)                                   AS QUICK_RESTART_SAVING,
  SUM(IDLE_RELOADS)                          AS IDLE_RELOADS,
  ROUND(0.96 * SUM(IDLE_RELOAD_CREDITS), 4)  AS IDLE_RELOAD_SAVING,
  ROUND(0.16 * SUM(IFF(INTERFACE = 'cli', COLD_START_CREDITS, 0)), 4) AS SLIM_SAVING_LOW,
  ROUND(0.46 * SUM(IFF(INTERFACE = 'cli', COLD_START_CREDITS, 0)), 4) AS SLIM_SAVING_HIGH
FROM seq
GROUP BY USER_NAME;
-- ---------------------------------------------------------------------------
-- ROLLING_24H_USAGE: credits per user and interface over the past 24 hours,
-- the same window Snowflake's daily per-user CoCo credit limits use
-- (CORTEX_CODE_<surface>_DAILY_EST_CREDIT_LIMIT_PER_USER). Snowflake enforces
-- on estimated credits, which can differ a little from these billed credits.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW ROLLING_24H_USAGE
  COMMENT = 'CoCo credits per user and interface over the past 24 hours. All users.'
AS
SELECT
  USER_NAME,
  INTERFACE,
  COUNT(DISTINCT THREAD_ID) AS CHATS,
  COUNT(*)                  AS REQUESTS,
  SUM(TOTAL_TOKENS)         AS TOTAL_TOKENS,
  SUM(CREDITS)              AS CREDITS,
  MAX(USAGE_TIME)           AS LAST_ACTIVITY_AT
FROM REQUESTS
WHERE USAGE_TIME >= DATEADD('hour', -24, CURRENT_TIMESTAMP())
GROUP BY USER_NAME, INTERFACE;

-- ---------------------------------------------------------------------------
-- MODEL_RATES: credits per million tokens for each model and token category,
-- computed from what this account was actually billed. No per-user data.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW MODEL_RATES
  COMMENT = 'Observed credits per million tokens by model and token category.'
AS
SELECT
  f.key::STRING                                   AS MODEL,
  c.key::STRING                                   AS TOKEN_CATEGORY,
  SUM(t.value::NUMBER)                            AS TOKENS,
  SUM(c.value::NUMBER(38,9))                      AS CREDITS,
  ROUND(SUM(c.value::NUMBER(38,9)) / NULLIF(SUM(t.value::NUMBER), 0) * 1000000, 4)
                                                  AS CREDITS_PER_MILLION_TOKENS,
  MAX(u.USAGE_TIME)                               AS LAST_SEEN_AT
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY u,
     LATERAL FLATTEN(INPUT => u.CREDITS_GRANULAR) f,
     LATERAL FLATTEN(INPUT => f.value) c,
     LATERAL FLATTEN(INPUT => u.TOKENS_GRANULAR[f.key]) t
WHERE t.key = c.key
GROUP BY f.key, c.key;

-- ---------------------------------------------------------------------------
-- MY_* views: the same data limited to the user running the query. They are
-- SECURE views owned by the installing role, so a user needs no access to
-- SNOWFLAKE.ACCOUNT_USAGE to see their own chats.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE SECURE VIEW MY_CHATS
  COMMENT = 'CHATS limited to CURRENT_USER().'
AS
SELECT * FROM CHATS WHERE USER_NAME = CURRENT_USER();

CREATE OR REPLACE SECURE VIEW MY_CHAT_REQUESTS
  COMMENT = 'CHAT_REQUESTS limited to CURRENT_USER().'
AS
SELECT * FROM CHAT_REQUESTS WHERE USER_NAME = CURRENT_USER();

CREATE OR REPLACE SECURE VIEW MY_BACKGROUND_USAGE
  COMMENT = 'BACKGROUND_USAGE limited to CURRENT_USER().'
AS
SELECT * FROM BACKGROUND_USAGE WHERE USER_NAME = CURRENT_USER();

CREATE OR REPLACE SECURE VIEW MY_SAVINGS_ESTIMATE
  COMMENT = 'SAVINGS_ESTIMATE limited to CURRENT_USER().'
AS
SELECT * FROM SAVINGS_ESTIMATE WHERE USER_NAME = CURRENT_USER();

CREATE OR REPLACE SECURE VIEW MY_DAILY_USAGE
  COMMENT = 'DAILY_USAGE limited to CURRENT_USER().'
AS
SELECT * FROM DAILY_USAGE WHERE USER_NAME = CURRENT_USER();

-- ---------------------------------------------------------------------------
-- SET_SETTING: change a setting. Admins only.
--   CALL SET_SETTING('CREDIT_PRICE', '3');   CALL SET_SETTING('CURRENCY', 'USD');
--   CALL SET_SETTING('CREDIT_PRICE', NULL);  -- remove it again
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE SET_SETTING(SETTING_KEY STRING, SETTING_VALUE STRING)
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
BEGIN
  IF (UPPER(SETTING_KEY) NOT IN ('CREDIT_PRICE', 'CURRENCY')) THEN
    RETURN 'Unknown setting: ' || SETTING_KEY;
  END IF;
  IF (UPPER(SETTING_KEY) = 'CREDIT_PRICE'
      AND SETTING_VALUE IS NOT NULL AND TRY_TO_DOUBLE(SETTING_VALUE) IS NULL) THEN
    RETURN SETTING_KEY || ' must be a number.';
  END IF;
  DELETE FROM COCO_TOKEN_METER.USAGE.SETTINGS WHERE KEY = UPPER(:SETTING_KEY);
  IF (SETTING_VALUE IS NOT NULL) THEN
    INSERT INTO COCO_TOKEN_METER.USAGE.SETTINGS (KEY, VALUE, UPDATED_BY)
      VALUES (UPPER(:SETTING_KEY), :SETTING_VALUE, CURRENT_USER());
    RETURN UPPER(SETTING_KEY) || ' set to ' || SETTING_VALUE;
  END IF;
  RETURN UPPER(SETTING_KEY) || ' removed';
END;
$$;

-- ---------------------------------------------------------------------------
-- Chat names. SYNC_MY_CHAT_TITLES runs as the caller, asks Snowflake's Threads
-- API for the caller's own chats, and hands them to STORE_MY_CHAT_TITLES,
-- which keeps a name only for a thread that the usage history says belongs
-- to the calling user. A user cannot name somebody else's chat.
-- Chat names describe what a chat was about, and admins can see them in
-- CHATS. A user who never calls SYNC_MY_CHAT_TITLES shares no names.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE STORE_MY_CHAT_TITLES(THREADS VARIANT)
  RETURNS NUMBER
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  STORED NUMBER DEFAULT 0;
BEGIN
  MERGE INTO COCO_TOKEN_METER.USAGE.CHAT_TITLES tgt
  USING (
    SELECT DISTINCT
      f.value:thread_id::NUMBER          AS THREAD_ID,
      f.value:thread_name::STRING        AS CHAT_NAME,
      f.value:origin_application::STRING AS ORIGIN_APPLICATION
    FROM TABLE(FLATTEN(INPUT => :THREADS)) f
    WHERE f.value:thread_name::STRING IS NOT NULL
      AND f.value:thread_id::NUMBER IN (
        SELECT THREAD_ID
        FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY
        WHERE USER_NAME = CURRENT_USER() AND THREAD_ID IS NOT NULL)
    QUALIFY ROW_NUMBER() OVER (PARTITION BY f.value:thread_id::NUMBER ORDER BY f.index) = 1
  ) src
  ON tgt.THREAD_ID = src.THREAD_ID
  WHEN MATCHED THEN UPDATE SET
    CHAT_NAME = src.CHAT_NAME, ORIGIN_APPLICATION = src.ORIGIN_APPLICATION,
    USER_NAME = CURRENT_USER(), SYNCED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (THREAD_ID, USER_NAME, CHAT_NAME, ORIGIN_APPLICATION)
    VALUES (src.THREAD_ID, CURRENT_USER(), src.CHAT_NAME, src.ORIGIN_APPLICATION);
  STORED := SQLROWCOUNT;
  RETURN STORED;
END;
$$;

CREATE OR REPLACE PROCEDURE SYNC_MY_CHAT_TITLES()
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
  EXECUTE AS CALLER
AS
$$
import json
import _snowflake

def run(session):
    response = _snowflake.send_snow_api_request(
        "GET", "/api/v2/cortex/threads", {}, {}, {}, None, 30000)
    if response.get("status") != 200:
        return "Could not read chat names (status %s)." % response.get("status")
    threads = json.loads(response.get("content") or "[]")
    slim = [{"thread_id": t.get("thread_id"),
             "thread_name": t.get("thread_name"),
             "origin_application": t.get("origin_application")}
            for t in threads if t.get("thread_name")]
    if not slim:
        return "No named chats found."
    stored = session.call("COCO_TOKEN_METER.USAGE.STORE_MY_CHAT_TITLES", slim)
    return "Chat names stored or refreshed: %s" % stored
$$;
-- ---------------------------------------------------------------------------
-- Skills for CoCo in Snowsight. CoCo loads skills from each user's own
-- workspace, which only that user can write to. So the skill files are kept
-- on a stage here, and every user copies them into their workspace with one
-- statement, from any worksheet:
--
--   CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS();       -- usage skill
--   CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS(TRUE);   -- plus the admin limits skill
--   CALL COCO_TOKEN_METER.USAGE.UNINSTALL_MY_SKILLS();
--
-- The PUT statements below read the files from this repository, so run this
-- script from the repository root.
-- ---------------------------------------------------------------------------
CREATE STAGE IF NOT EXISTS SKILLS_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'coco-token-meter: skill files that INSTALL_MY_SKILLS copies into a user workspace';


-- Snowsight cannot upload local files, so the skill files and the dashboard
-- are written to their stages from the text embedded further down.
CREATE OR REPLACE PROCEDURE WRITE_STAGE_FILE(STAGE_PATH STRING, CONTENT STRING)
  RETURNS STRING
  LANGUAGE PYTHON
  RUNTIME_VERSION = '3.11'
  PACKAGES = ('snowflake-snowpark-python')
  HANDLER = 'run'
  EXECUTE AS OWNER
AS
$$
import io

def run(session, stage_path, content):
    session.file.put_stream(io.BytesIO(content.encode("utf-8")), stage_path,
                            auto_compress=False, overwrite=True)
    return "written " + stage_path
$$;
CALL WRITE_STAGE_FILE('@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-token-usage/SKILL.md', $$---
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
  `CACHE_WRITE_TOKENS`, `OUTPUT_TOKENS`. Usage is billed in `CREDITS`.
- `CHAT_NAME` is the chat's title. It is empty until the names have been
  synced (see below). Show it next to the thread id whenever it is filled.
- `COST` and `CURRENCY` are filled only when an admin has set a price per
  credit. Show a cost column only when `COST` is not null.
- `INTERFACE` says where the chat ran, for example `snowsight`, `cli` or
  `automation`.

Use the `MY_*` views unless the user asks about other users or the whole
account. If an all-users view fails with a privilege error, say it needs the
`COCO_TOKEN_METER_ADMIN` role and fall back to the `MY_*` view.

## Finding "this chat"

1. Run a shell command to read the environment variable `CORTEX_THREAD_ID`
   (`echo $CORTEX_THREAD_ID`, or `echo $env:CORTEX_THREAD_ID` in PowerShell).
   CoCo sets it to the thread id of the open chat, in the CLI and in
   Snowsight. Use it.
2. If that chat has no rows yet, say so: a request is recorded only after it
   finishes, so the first message of a new chat is never there. Tell the user
   to ask again after their next message, and do not show another chat's
   numbers as if they were this chat's.
3. Only if you cannot run shell commands, use the user's most recently active
   chat, and say that this is what you did:

```sql
SELECT THREAD_ID FROM COCO_TOKEN_METER.USAGE.MY_CHATS
ORDER BY LAST_ACTIVITY_AT DESC LIMIT 1;
```

## Queries

**Chat names.** Before the first query that lists chats, run this once per
chat. It stores the titles of the user's own chats. If it fails, carry on
without names and do not mention it.

```sql
CALL COCO_TOKEN_METER.USAGE.SYNC_MY_CHAT_TITLES();
```

**Recent chats** (default when no chat is named):

```sql
SELECT THREAD_ID, CHAT_NAME, INTERFACE, STARTED_AT, LAST_ACTIVITY_AT, REQUESTS,
       TOTAL_TOKENS, INPUT_TOKENS, CACHE_READ_TOKENS, CACHE_WRITE_TOKENS,
       OUTPUT_TOKENS, ROUND(CREDITS, 4) AS CREDITS, COST, CURRENCY
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
SELECT THREAD_ID, CHAT_NAME, INTERFACE, STARTED_AT, REQUESTS, TOTAL_TOKENS,
       ROUND(CREDITS, 4) AS CREDITS, COST, CURRENCY
FROM COCO_TOKEN_METER.USAGE.MY_CHATS
ORDER BY CREDITS DESC
LIMIT 10;
```

**All users** (admins: "usage for all users", "who uses the most", "most
expensive chat per user"). Needs `COCO_TOKEN_METER_ADMIN`. A chat has a name
only if its owner has synced their names.

```sql
SELECT USER_NAME, COUNT(*) AS CHATS, SUM(REQUESTS) AS REQUESTS,
       ROUND(SUM(CREDITS), 4) AS CREDITS, ROUND(MAX(CREDITS), 4) AS MOST_EXPENSIVE_CHAT,
       SUM(COST) AS COST, MAX(CURRENCY) AS CURRENCY
FROM COCO_TOKEN_METER.USAGE.CHATS
GROUP BY USER_NAME
ORDER BY CREDITS DESC;
```

```sql
SELECT USER_NAME, THREAD_ID, CHAT_NAME, INTERFACE, STARTED_AT, REQUESTS,
       ROUND(CREDITS, 4) AS CREDITS, COST, CURRENCY
FROM COCO_TOKEN_METER.USAGE.CHATS
QUALIFY ROW_NUMBER() OVER (PARTITION BY USER_NAME ORDER BY CREDITS DESC) <= 3
ORDER BY USER_NAME, CREDITS DESC;
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
Then show the savings estimate for the same 30 days:

```sql
SELECT CHATS, CREDITS, COLD_STARTS, QUICK_RESTARTS, QUICK_RESTART_SAVING,
       IDLE_RELOADS, IDLE_RELOAD_SAVING, SLIM_SAVING_LOW, SLIM_SAVING_HIGH
FROM COCO_TOKEN_METER.USAGE.MY_SAVINGS_ESTIMATE;
```

- `QUICK_RESTART_SAVING`: credits that `QUICK_RESTARTS` chats would have
  saved had they been follow-ups, because each was started within 5 minutes
  of the user's previous chat.
- `IDLE_RELOAD_SAVING`: credits spent re-loading chats after a pause.
- `SLIM_SAVING_LOW` to `SLIM_SAVING_HIGH`: what `/slim` could have saved in
  CoCo CLI, with 20 or all bundled skills turned off.
- Say that these are estimates and upper bounds, that they overlap and must
  not be added together, and do not promise a saving.
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

If `COCO_TOKEN_METER` does not exist, the account may use the native app
instead. Run the same queries against `COCO_TOKEN_METER_APP.USAGE` (skip
`SYNC_MY_CHAT_TITLES`, which the app does not have). Only if that fails too:


If a query fails because `COCO_TOKEN_METER` does not exist or is not
authorized, do not try to create it. Tell the user that an administrator has
to run `sql/setup.sql` from the coco-token-meter repository once and grant
them the `COCO_TOKEN_METER_USER` role.
$$);

CALL WRITE_STAGE_FILE('@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-admin-limits/SKILL.md', $$---
name: coco-admin-limits
description: For Snowflake admins - see and change the daily CoCo (Cortex Code) credit limit per user, see who is close to their limit, block or unblock a user, and suggest a sensible limit from real usage. Use when the user asks to "set a CoCo limit", "limit a user's credits", "block a user from CoCo", "who is near their limit", "what limit should I set", or runs /limits.
---

# CoCo credit limits for admins

Snowflake has a built-in daily credit limit per user for CoCo. This skill
reads and changes it, and uses the `COCO_TOKEN_METER.USAGE` views to show how
close each user is. It needs a role that can alter the account or users
(`ACCOUNTADMIN`) and, for the usage numbers, `COCO_TOKEN_METER_ADMIN`.

## The limits

One parameter per CoCo surface:

| Surface | Parameter |
|---|---|
| CoCo CLI | `CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER` |
| CoCo in Snowsight | `CORTEX_CODE_SNOWSIGHT_DAILY_EST_CREDIT_LIMIT_PER_USER` |
| CoCo Desktop | `CORTEX_CODE_DESKTOP_DAILY_EST_CREDIT_LIMIT_PER_USER` |

- `-1` (the default) means no limit. `0` blocks the user on that surface. A
  positive number blocks the user once their estimated credits over the past
  24 hours pass it; access comes back as older usage drops out of the window.
- The value must be a whole number. `0.5` is rejected with "invalid value".
- A value set on a user overrides the account value for that user.
- A user blocked with `0` sees: "Cortex Code access is currently disabled
  (daily usage limit is set to 0 credits). Contact your Snowflake administrator
  to enable access by setting a non-zero per-user credit limit."
- Snowflake counts *estimated* credits for the limit. They can differ a
  little from the billed credits in the usage views.

## Rules

1. Reading is always fine. **Before any `ALTER`, show the exact statement and
   what it will do, and wait for the user to say yes.** One confirmation per
   change.
2. Never change a limit the user did not ask about. If they name a person,
   change only that user. If they say "everyone", change the account value.
3. If they do not say which surface, ask: CLI, Snowsight, Desktop, or all.
4. Quote user names with double quotes exactly as `SHOW USERS` returns them.
5. After a change, run the `SHOW PARAMETERS` for it and report the new value.

## See the current limits

```sql
SHOW PARAMETERS LIKE 'CORTEX_CODE_%_DAILY_EST_CREDIT_LIMIT_PER_USER' IN ACCOUNT;
```

```sql
SHOW PARAMETERS LIKE 'CORTEX_CODE_%_DAILY_EST_CREDIT_LIMIT_PER_USER' IN USER "<user>";
```

In the result, `level` is `USER` when the value was set on that user and
empty or `ACCOUNT` when it comes from the account.

## Who is close to their limit

Usage over the same rolling 24 hours, per user and surface:

```sql
SELECT USER_NAME, INTERFACE, CHATS, REQUESTS, ROUND(CREDITS, 4) AS CREDITS_LAST_24H,
       LAST_ACTIVITY_AT
FROM COCO_TOKEN_METER.USAGE.ROLLING_24H_USAGE
ORDER BY CREDITS DESC;
```

`INTERFACE` is `cli`, `snowsight` or `desktop`; compare each row with that
surface's limit for that user. Report credits used, the limit, and the share
used, highest share first. Say that the usage history can lag by a few
minutes and that Snowflake enforces on estimated credits.

## Suggest a limit

Base it on what people actually use:

```sql
SELECT INTERFACE,
       COUNT(DISTINCT USER_NAME)                               AS USERS,
       ROUND(MEDIAN(CREDITS), 2)                               AS TYPICAL_USER_DAY,
       ROUND(PERCENTILE_CONT(0.95) WITHIN GROUP (ORDER BY CREDITS), 2) AS BUSY_USER_DAY,
       ROUND(MAX(CREDITS), 2)                                  AS HIGHEST_USER_DAY
FROM (
  SELECT USER_NAME, INTERFACE, USAGE_DATE, SUM(CREDITS) AS CREDITS
  FROM COCO_TOKEN_METER.USAGE.DAILY_USAGE
  WHERE USAGE_DATE >= DATEADD('day', -30, CURRENT_DATE())
  GROUP BY USER_NAME, INTERFACE, USAGE_DATE
)
GROUP BY INTERFACE;
```

Suggest a whole number a little above `BUSY_USER_DAY` so normal work is not blocked,
and say how many user-days in the period would have hit it. With fewer than
about 10 user-days of data, say that the sample is too small to size from.

## Change a limit

For one user:

```sql
ALTER USER "<user>" SET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER = <credits>;
```

Back to the account default for that user:

```sql
ALTER USER "<user>" UNSET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER;
```

For everyone:

```sql
ALTER ACCOUNT SET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER = <credits>;
```

```sql
ALTER ACCOUNT UNSET CORTEX_CODE_CLI_DAILY_EST_CREDIT_LIMIT_PER_USER;
```

Use the Snowsight or Desktop parameter name for those surfaces. To block a
user, set `0`; to unblock, `UNSET`. Setting the account value to `0` blocks
everyone who has no user-level value: say so clearly before doing it.

## Beyond a daily limit

For monthly limits, limits for a tagged group, or an automatic action when a
limit is reached, point the user to Snowflake's per-user quotas and budgets
in its cost management documentation. This skill does not set those up.
$$);

CREATE OR REPLACE PROCEDURE INSTALL_MY_SKILLS(INCLUDE_ADMIN_SKILL BOOLEAN DEFAULT FALSE)
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
$$
BEGIN
  COPY FILES INTO 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-token-usage/'
    FROM @COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-token-usage/;
  IF (INCLUDE_ADMIN_SKILL) THEN
    COPY FILES INTO 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-admin-limits/'
      FROM @COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-admin-limits/;
    RETURN 'Installed coco-token-usage and coco-admin-limits. Open a new CoCo chat and ask: show my CoCo token usage per chat';
  END IF;
  RETURN 'Installed coco-token-usage. Open a new CoCo chat and ask: show my CoCo token usage per chat';
END;
$$;

CREATE OR REPLACE PROCEDURE UNINSTALL_MY_SKILLS()
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS CALLER
AS
$$
BEGIN
  REMOVE 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-token-usage/';
  REMOVE 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-admin-limits/';
  RETURN 'Removed the coco-token-meter skills from your workspace.';
END;
$$;
-- ---------------------------------------------------------------------------
-- Access. COCO_TOKEN_METER_USER sees only their own usage;
-- COCO_TOKEN_METER_ADMIN sees every user's usage.
-- To let everyone see their own usage:
--   GRANT ROLE COCO_TOKEN_METER_USER TO ROLE PUBLIC;
-- ---------------------------------------------------------------------------
CREATE ROLE IF NOT EXISTS COCO_TOKEN_METER_USER
  COMMENT = 'coco-token-meter: read your own CoCo chat usage';
CREATE ROLE IF NOT EXISTS COCO_TOKEN_METER_ADMIN
  COMMENT = 'coco-token-meter: read CoCo chat usage for all users';

GRANT USAGE ON DATABASE COCO_TOKEN_METER TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON SCHEMA COCO_TOKEN_METER.USAGE TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MY_CHATS            TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MY_CHAT_REQUESTS    TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MY_BACKGROUND_USAGE TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MY_DAILY_USAGE      TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MY_SAVINGS_ESTIMATE TO ROLE COCO_TOKEN_METER_USER;
GRANT SELECT ON VIEW MODEL_RATES         TO ROLE COCO_TOKEN_METER_USER;

GRANT ROLE COCO_TOKEN_METER_USER TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW REQUESTS         TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW CHAT_REQUESTS    TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW CHATS            TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW BACKGROUND_USAGE TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW DAILY_USAGE      TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW SAVINGS_ESTIMATE TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW ROLLING_24H_USAGE TO ROLE COCO_TOKEN_METER_ADMIN;

GRANT USAGE ON PROCEDURE SYNC_MY_CHAT_TITLES()          TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE STORE_MY_CHAT_TITLES(VARIANT)   TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE SET_SETTING(STRING, STRING)     TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON TABLE SETTINGS                           TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON TABLE CHAT_TITLES                        TO ROLE COCO_TOKEN_METER_ADMIN;

GRANT READ ON STAGE SKILLS_STAGE                         TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE INSTALL_MY_SKILLS(BOOLEAN)      TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE UNINSTALL_MY_SKILLS()           TO ROLE COCO_TOKEN_METER_USER;

GRANT ROLE COCO_TOKEN_METER_ADMIN TO ROLE SYSADMIN;

-- ---------------------------------------------------------------------------
-- Admin dashboard (Streamlit in Snowflake). It runs its queries on the
-- warehouse this worksheet is using.
-- ---------------------------------------------------------------------------
USE SCHEMA COCO_TOKEN_METER.USAGE;

CREATE STAGE IF NOT EXISTS DASHBOARD_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'coco-token-meter: files of the admin dashboard';
CALL WRITE_STAGE_FILE('@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/streamlit_app.py', $$"""coco-token-meter admin dashboard (Streamlit in Snowflake).

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


def plain(value) -> str:
    """Text for chart labels: Plotly reads a few HTML tags, so remove angle brackets."""
    return str(value).replace("<", "(").replace(">", ")")


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
            plain((row["Chat name"] or f"thread {row['Thread']}")[:52] + f"  ·  {row['User']}") for _, row in top.iterrows()
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
                labels=[plain(u) for u in user_names]
                + [plain((n or f"thread {t}")[:40]) for n, t in zip(tree["Chat name"], tree["Thread"])],
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
$$);

CALL WRITE_STAGE_FILE('@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/environment.yml', $$name: coco_token_meter
channels:
  - snowflake
dependencies:
  - streamlit=1.44.1
  - plotly=5.24.1
  - pandas
$$);

EXECUTE IMMEDIATE
$$
DECLARE
  WH STRING DEFAULT CURRENT_WAREHOUSE();
BEGIN
  IF (WH IS NULL) THEN
    RETURN 'Dashboard skipped: select a warehouse for this worksheet and run this file again.';
  END IF;
  EXECUTE IMMEDIATE 'CREATE OR REPLACE STREAMLIT COCO_TOKEN_METER.USAGE.COCO_TOKEN_METER_DASHBOARD '
    || 'ROOT_LOCATION = ''@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE'' MAIN_FILE = ''streamlit_app.py'' '
    || 'QUERY_WAREHOUSE = "' || WH || '" TITLE = ''CoCo Token Meter'' '
    || 'COMMENT = ''coco-token-meter: CoCo usage per chat and per user (admins)''';
  GRANT USAGE ON STREAMLIT COCO_TOKEN_METER.USAGE.COCO_TOKEN_METER_DASHBOARD TO ROLE COCO_TOKEN_METER_ADMIN;
  RETURN 'Dashboard created on warehouse ' || WH || '.';
END;
$$;

DROP PROCEDURE IF EXISTS COCO_TOKEN_METER.USAGE.WRITE_STAGE_FILE(STRING, STRING);

-- ---------------------------------------------------------------------------
-- Install the skills for the person running this file, and show the result.
-- ---------------------------------------------------------------------------
CALL COCO_TOKEN_METER.USAGE.INSTALL_MY_SKILLS(TRUE);

SELECT 'coco-token-meter is installed. Open a new CoCo chat and ask: show my CoCo token usage per chat' AS NEXT_STEP,
       (SELECT COUNT(*) FROM COCO_TOKEN_METER.USAGE.CHATS)                 AS CHATS_FOUND,
       (SELECT ROUND(SUM(CREDITS), 4) FROM COCO_TOKEN_METER.USAGE.CHATS)   AS CREDITS_FOUND;