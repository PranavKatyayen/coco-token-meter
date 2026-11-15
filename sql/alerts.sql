-- coco-token-meter budget alerts (optional). Run after sql/setup.sql, as the
-- same role:
--
--   snow sql -c <connection> -f sql/alerts.sql
--
-- Then set at least one limit and switch the alert on:
--
--   CALL COCO_TOKEN_METER.USAGE.SET_SETTING('DAILY_USER_CREDIT_LIMIT', '5');
--   CALL COCO_TOKEN_METER.USAGE.SET_SETTING('CHAT_CREDIT_LIMIT', '1');
--   ALTER ALERT COCO_TOKEN_METER.USAGE.COCO_BUDGET_ALERT RESUME;
--
-- Every hour the alert records each new breach in ALERT_LOG. To also get an
-- email, name an email notification integration and the recipients:
--
--   CALL COCO_TOKEN_METER.USAGE.SET_SETTING('ALERT_EMAIL_INTEGRATION', 'MY_EMAIL_INT');
--   CALL COCO_TOKEN_METER.USAGE.SET_SETTING('ALERT_EMAIL_TO', 'admin@example.com');
--
-- The alert is created suspended and costs nothing until you resume it. It is
-- a serverless alert, so the role needs the EXECUTE MANAGED ALERT privilege
-- (ACCOUNTADMIN has it).

USE SCHEMA COCO_TOKEN_METER.USAGE;

CREATE TABLE IF NOT EXISTS ALERT_LOG (
  BREACH_KEY   STRING NOT NULL,
  KIND         STRING,
  USER_NAME    STRING,
  THREAD_ID    NUMBER,
  USAGE_DATE   DATE,
  CREDITS      NUMBER(38,9),
  CREDIT_LIMIT NUMBER(38,9),
  DETECTED_AT  TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP(),
  EMAILED      BOOLEAN DEFAULT FALSE
);

-- ---------------------------------------------------------------------------
-- BUDGET_BREACHES: what is over a limit right now, looking back two days.
--   'user day'  a user's CoCo credits for one day exceed DAILY_USER_CREDIT_LIMIT
--   'chat'      one chat's credits exceed CHAT_CREDIT_LIMIT
-- A limit that is not set produces no rows.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW BUDGET_BREACHES
  COMMENT = 'Users and chats currently over a configured credit limit.'
AS
WITH limits AS (
  SELECT
    (SELECT TRY_TO_DOUBLE(MAX(VALUE)) FROM SETTINGS WHERE KEY = 'DAILY_USER_CREDIT_LIMIT') AS DAILY_LIMIT,
    (SELECT TRY_TO_DOUBLE(MAX(VALUE)) FROM SETTINGS WHERE KEY = 'CHAT_CREDIT_LIMIT')       AS CHAT_LIMIT
),
user_days AS (
  SELECT USER_NAME, USAGE_DATE, SUM(CREDITS) AS CREDITS
  FROM DAILY_USAGE
  WHERE USAGE_DATE >= DATEADD('day', -2, CURRENT_DATE())
  GROUP BY USER_NAME, USAGE_DATE
)
SELECT
  'DAY|' || d.USER_NAME || '|' || TO_CHAR(d.USAGE_DATE, 'YYYY-MM-DD') AS BREACH_KEY,
  'user day'      AS KIND,
  d.USER_NAME,
  NULL::NUMBER    AS THREAD_ID,
  NULL::STRING    AS CHAT_NAME,
  d.USAGE_DATE,
  d.CREDITS,
  l.DAILY_LIMIT   AS CREDIT_LIMIT
FROM user_days d CROSS JOIN limits l
WHERE d.CREDITS > l.DAILY_LIMIT
UNION ALL
SELECT
  'CHAT|' || c.THREAD_ID,
  'chat',
  c.USER_NAME,
  c.THREAD_ID,
  c.CHAT_NAME,
  c.LAST_ACTIVITY_AT::DATE,
  c.CREDITS,
  l.CHAT_LIMIT
FROM CHATS c CROSS JOIN limits l
WHERE c.CREDITS > l.CHAT_LIMIT
  AND c.LAST_ACTIVITY_AT >= DATEADD('day', -2, CURRENT_TIMESTAMP());

-- ---------------------------------------------------------------------------
-- CHECK_BUDGETS: log every breach that is not in ALERT_LOG yet and, when the
-- email settings are filled in, send one email listing the new ones.
-- Returns the number of new breaches. Safe to call by hand.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE CHECK_BUDGETS()
  RETURNS STRING
  LANGUAGE SQL
  EXECUTE AS OWNER
AS
$$
DECLARE
  RUN_AT      TIMESTAMP_TZ DEFAULT CURRENT_TIMESTAMP();
  NEW_COUNT   NUMBER DEFAULT 0;
  INTEGRATION STRING;
  RECIPIENTS  STRING;
  BODY        STRING;
BEGIN
  INSERT INTO COCO_TOKEN_METER.USAGE.ALERT_LOG
    (BREACH_KEY, KIND, USER_NAME, THREAD_ID, USAGE_DATE, CREDITS, CREDIT_LIMIT, DETECTED_AT)
  SELECT b.BREACH_KEY, b.KIND, b.USER_NAME, b.THREAD_ID, b.USAGE_DATE, b.CREDITS, b.CREDIT_LIMIT, :RUN_AT
  FROM COCO_TOKEN_METER.USAGE.BUDGET_BREACHES b
  WHERE NOT EXISTS (SELECT 1 FROM COCO_TOKEN_METER.USAGE.ALERT_LOG a WHERE a.BREACH_KEY = b.BREACH_KEY);
  NEW_COUNT := SQLROWCOUNT;
  IF (NEW_COUNT = 0) THEN
    RETURN 'No new breaches.';
  END IF;

  SELECT MAX(IFF(KEY = 'ALERT_EMAIL_INTEGRATION', VALUE, NULL)),
         MAX(IFF(KEY = 'ALERT_EMAIL_TO', VALUE, NULL))
    INTO :INTEGRATION, :RECIPIENTS
  FROM COCO_TOKEN_METER.USAGE.SETTINGS;
  IF (INTEGRATION IS NULL OR RECIPIENTS IS NULL) THEN
    RETURN NEW_COUNT || ' new breach(es) logged. No email settings, so no email sent.';
  END IF;

  SELECT LISTAGG(
           IFF(KIND = 'chat',
               'Chat ' || THREAD_ID || ' of ' || USER_NAME || ': ',
               USER_NAME || ' on ' || TO_CHAR(USAGE_DATE, 'YYYY-MM-DD') || ': ')
           || ROUND(CREDITS, 4) || ' credits (limit ' || CREDIT_LIMIT || ')', '\n')
         WITHIN GROUP (ORDER BY CREDITS DESC)
    INTO :BODY
  FROM COCO_TOKEN_METER.USAGE.ALERT_LOG
  WHERE DETECTED_AT = :RUN_AT;

  CALL SYSTEM$SEND_EMAIL(:INTEGRATION, :RECIPIENTS,
                         'CoCo budget alert: ' || :NEW_COUNT || ' new breach(es)', :BODY);
  UPDATE COCO_TOKEN_METER.USAGE.ALERT_LOG SET EMAILED = TRUE WHERE DETECTED_AT = :RUN_AT;
  RETURN NEW_COUNT || ' new breach(es) logged and emailed.';
END;
$$;

-- ---------------------------------------------------------------------------
-- The hourly alert. Created suspended; resume it to switch it on.
-- ---------------------------------------------------------------------------
CREATE ALERT IF NOT EXISTS COCO_BUDGET_ALERT
  SCHEDULE = '60 MINUTE'
  COMMENT = 'coco-token-meter: logs CoCo users and chats that pass a credit limit'
  IF (EXISTS (
    SELECT 1 FROM COCO_TOKEN_METER.USAGE.BUDGET_BREACHES b
    WHERE NOT EXISTS (SELECT 1 FROM COCO_TOKEN_METER.USAGE.ALERT_LOG a WHERE a.BREACH_KEY = b.BREACH_KEY)))
  THEN CALL COCO_TOKEN_METER.USAGE.CHECK_BUDGETS();

GRANT SELECT ON VIEW BUDGET_BREACHES       TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT SELECT ON TABLE ALERT_LOG            TO ROLE COCO_TOKEN_METER_ADMIN;
GRANT USAGE ON PROCEDURE CHECK_BUDGETS()   TO ROLE COCO_TOKEN_METER_ADMIN;
