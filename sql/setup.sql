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
--   (sql/alerts.sql adds the budget settings)
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
    ANY_VALUE(u.USER_NAME)                              AS USER_NAME,
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
  IF (UPPER(SETTING_KEY) NOT IN ('CREDIT_PRICE', 'CURRENCY', 'DAILY_USER_CREDIT_LIMIT',
                                 'CHAT_CREDIT_LIMIT', 'ALERT_EMAIL_INTEGRATION', 'ALERT_EMAIL_TO')) THEN
    RETURN 'Unknown setting: ' || SETTING_KEY;
  END IF;
  IF (UPPER(SETTING_KEY) IN ('CREDIT_PRICE', 'DAILY_USER_CREDIT_LIMIT', 'CHAT_CREDIT_LIMIT')
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

GRANT USAGE ON PROCEDURE SYNC_MY_CHAT_TITLES()          TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE STORE_MY_CHAT_TITLES(VARIANT)   TO ROLE COCO_TOKEN_METER_USER;
GRANT USAGE ON PROCEDURE SET_SETTING(STRING, STRING)     TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON TABLE SETTINGS                           TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON TABLE CHAT_TITLES                        TO ROLE COCO_TOKEN_METER_ADMIN;

GRANT ROLE COCO_TOKEN_METER_ADMIN TO ROLE SYSADMIN;
