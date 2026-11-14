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
-- REQUESTS: one row per CoCo request, all users. A request is one billed
-- call; a single chat message can produce several of them.
--
-- TOKENS_GRANULAR and CREDITS_GRANULAR are {model: {input, cache_read_input,
-- cache_write_input, output}}. A request can use more than one model, so the
-- split is summed over models.
--
-- IS_LARGE_CACHE_WRITE marks a request with at least 10,000 cache-write
-- tokens that make up at least half of its credits. CHAT_REQUESTS turns it
-- into REQUEST_KIND.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW REQUESTS
  COMMENT = 'One row per CoCo request with token and credit split. All users.'
AS
WITH tok AS (
  SELECT
    r.REQUEST_ID,
    SUM(COALESCE(m.value:input::NUMBER, 0))             AS INPUT_TOKENS,
    SUM(COALESCE(m.value:cache_read_input::NUMBER, 0))  AS CACHE_READ_TOKENS,
    SUM(COALESCE(m.value:cache_write_input::NUMBER, 0)) AS CACHE_WRITE_TOKENS,
    SUM(COALESCE(m.value:output::NUMBER, 0))            AS OUTPUT_TOKENS,
    ARRAY_AGG(DISTINCT m.key::STRING) WITHIN GROUP (ORDER BY m.key::STRING) AS MODELS
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY r,
       LATERAL FLATTEN(INPUT => r.TOKENS_GRANULAR) m
  GROUP BY r.REQUEST_ID
),
cred AS (
  SELECT
    r.REQUEST_ID,
    SUM(COALESCE(m.value:input::NUMBER(38,9), 0))             AS INPUT_CREDITS,
    SUM(COALESCE(m.value:cache_read_input::NUMBER(38,9), 0))  AS CACHE_READ_CREDITS,
    SUM(COALESCE(m.value:cache_write_input::NUMBER(38,9), 0)) AS CACHE_WRITE_CREDITS,
    SUM(COALESCE(m.value:output::NUMBER(38,9), 0))            AS OUTPUT_CREDITS
  FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY r,
       LATERAL FLATTEN(INPUT => r.CREDITS_GRANULAR) m
  GROUP BY r.REQUEST_ID
)
SELECT
  u.THREAD_ID,
  u.REQUEST_ID,
  u.PARENT_REQUEST_ID,
  u.USER_NAME,
  u.INTERFACE,
  u.USAGE_TIME,
  u.TOKENS                              AS TOTAL_TOKENS,
  COALESCE(t.INPUT_TOKENS, 0)           AS INPUT_TOKENS,
  COALESCE(t.CACHE_READ_TOKENS, 0)      AS CACHE_READ_TOKENS,
  COALESCE(t.CACHE_WRITE_TOKENS, 0)     AS CACHE_WRITE_TOKENS,
  COALESCE(t.OUTPUT_TOKENS, 0)          AS OUTPUT_TOKENS,
  u.TOKEN_CREDITS                       AS CREDITS,
  COALESCE(c.INPUT_CREDITS, 0)          AS INPUT_CREDITS,
  COALESCE(c.CACHE_READ_CREDITS, 0)     AS CACHE_READ_CREDITS,
  COALESCE(c.CACHE_WRITE_CREDITS, 0)    AS CACHE_WRITE_CREDITS,
  COALESCE(c.OUTPUT_CREDITS, 0)         AS OUTPUT_CREDITS,
  (COALESCE(t.CACHE_WRITE_TOKENS, 0) >= 10000
     AND COALESCE(c.CACHE_WRITE_CREDITS, 0) >= 0.5 * u.TOKEN_CREDITS) AS IS_LARGE_CACHE_WRITE,
  COALESCE(t.MODELS, ARRAY_CONSTRUCT()) AS MODELS,
  u.METADATA:role_name::STRING          AS ROLE_NAME,
  u.METADATA:trigger_type::STRING       AS TRIGGER_TYPE
FROM SNOWFLAKE.ACCOUNT_USAGE.SNOWFLAKE_COCO_USAGE_HISTORY u
LEFT JOIN tok  t ON t.REQUEST_ID = u.REQUEST_ID
LEFT JOIN cred c ON c.REQUEST_ID = u.REQUEST_ID;

-- ---------------------------------------------------------------------------
-- CHAT_REQUESTS: every request that belongs to a chat, numbered in order,
-- with running totals, the idle time before it, and REQUEST_KIND. Requests
-- with no THREAD_ID belong to no chat and are reported in BACKGROUND_USAGE.
--
-- REQUEST_KIND explains requests that paid for a large cache write (at least
-- 10,000 cache-write tokens making up at least half of the request's
-- credits):
--   'cold start'     first request of a chat: the starting context was
--                    written to the prompt cache
--   'idle reload'    later request after 2+ minutes idle: the cache had
--                    expired and the chat so far was written again
--   'large addition' later request with no idle gap: a lot of new content
--                    (usually a big tool result) was added to the chat
--   'normal'         everything else
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW CHAT_REQUESTS
  COMMENT = 'One row per request inside a chat, with running totals and REQUEST_KIND. All users.'
AS
WITH numbered AS (
  SELECT
    r.*,
    ROW_NUMBER() OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID) AS REQUEST_NO,
    DATEDIFF('second',
             LAG(USAGE_TIME) OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID),
             USAGE_TIME)                                                       AS SECONDS_SINCE_PREVIOUS,
    SUM(TOTAL_TOKENS) OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUNNING_TOKENS,
    SUM(CREDITS)      OVER (PARTITION BY THREAD_ID ORDER BY USAGE_TIME, REQUEST_ID
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW) AS RUNNING_CREDITS
  FROM REQUESTS r
  WHERE THREAD_ID IS NOT NULL
)
SELECT
  THREAD_ID,
  REQUEST_NO,
  REQUEST_ID,
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
    WHEN NOT IS_LARGE_CACHE_WRITE          THEN 'normal'
    WHEN REQUEST_NO = 1                    THEN 'cold start'
    WHEN SECONDS_SINCE_PREVIOUS >= 120     THEN 'idle reload'
    ELSE 'large addition'
  END AS REQUEST_KIND,
  RUNNING_TOKENS,
  RUNNING_CREDITS,
  MODELS,
  ROLE_NAME,
  TRIGGER_TYPE
FROM numbered;

-- ---------------------------------------------------------------------------
-- CHATS: one row per chat (THREAD_ID).
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW CHATS
  COMMENT = 'One row per CoCo chat (THREAD_ID) with token and credit totals. All users.'
AS
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
GROUP BY THREAD_ID;

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
  r.USER_NAME,
  r.INTERFACE,
  r.USAGE_TIME::DATE           AS USAGE_DATE,
  COUNT(DISTINCT r.THREAD_ID)  AS CHATS,
  COUNT(*)                     AS REQUESTS,
  SUM(r.TOTAL_TOKENS)          AS TOTAL_TOKENS,
  SUM(r.CREDITS)               AS CREDITS,
  SUM(r.INPUT_CREDITS)         AS INPUT_CREDITS,
  SUM(r.CACHE_READ_CREDITS)    AS CACHE_READ_CREDITS,
  SUM(r.CACHE_WRITE_CREDITS)   AS CACHE_WRITE_CREDITS,
  SUM(r.OUTPUT_CREDITS)        AS OUTPUT_CREDITS,
  COUNT_IF(c.REQUEST_KIND = 'cold start')                             AS COLD_STARTS,
  SUM(IFF(c.REQUEST_KIND = 'cold start', r.CACHE_WRITE_CREDITS, 0))   AS COLD_START_CREDITS,
  COUNT_IF(c.REQUEST_KIND = 'idle reload')                            AS IDLE_RELOADS,
  SUM(IFF(c.REQUEST_KIND = 'idle reload', r.CACHE_WRITE_CREDITS, 0))  AS IDLE_RELOAD_CREDITS
FROM REQUESTS r
LEFT JOIN CHAT_REQUESTS c ON c.REQUEST_ID = r.REQUEST_ID
GROUP BY r.USER_NAME, r.INTERFACE, r.USAGE_TIME::DATE;

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

CREATE OR REPLACE SECURE VIEW MY_DAILY_USAGE
  COMMENT = 'DAILY_USAGE limited to CURRENT_USER().'
AS
SELECT * FROM DAILY_USAGE WHERE USER_NAME = CURRENT_USER();

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
GRANT SELECT ON VIEW MODEL_RATES         TO ROLE COCO_TOKEN_METER_USER;

GRANT ROLE COCO_TOKEN_METER_USER TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW REQUESTS         TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW CHAT_REQUESTS    TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW CHATS            TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW BACKGROUND_USAGE TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON VIEW DAILY_USAGE      TO ROLE COCO_TOKEN_METER_ADMIN;

GRANT ROLE COCO_TOKEN_METER_ADMIN TO ROLE SYSADMIN;
