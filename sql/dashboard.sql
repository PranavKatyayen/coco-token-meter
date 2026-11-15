-- coco-token-meter admin dashboard (optional, Streamlit in Snowflake).
-- Run after sql/setup.sql, as the same role, from the repository root, and
-- name the warehouse the dashboard should run its queries on:
--
--   snow sql -c <connection> -f sql/dashboard.sql -D "warehouse=COMPUTE_WH"
--
-- Open it in Snowsight under Projects > Streamlit > "CoCo Token Meter".
--
-- The dashboard shows every user's usage and runs with the rights of the role
-- that owns it. Only COCO_TOKEN_METER_ADMIN is given access.

USE SCHEMA COCO_TOKEN_METER.USAGE;

CREATE STAGE IF NOT EXISTS DASHBOARD_STAGE
  DIRECTORY = (ENABLE = TRUE)
  COMMENT = 'coco-token-meter: files of the admin dashboard';

PUT 'file://dashboard/streamlit_app.py' @DASHBOARD_STAGE
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

CREATE OR REPLACE STREAMLIT COCO_TOKEN_METER_DASHBOARD
  ROOT_LOCATION = '@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE'
  MAIN_FILE = 'streamlit_app.py'
  QUERY_WAREHOUSE = <% warehouse %>
  TITLE = 'CoCo Token Meter'
  COMMENT = 'coco-token-meter: CoCo usage per chat and per user (admins)';

GRANT USAGE ON STREAMLIT COCO_TOKEN_METER_DASHBOARD TO ROLE COCO_TOKEN_METER_ADMIN;

SHOW STREAMLITS LIKE 'COCO_TOKEN_METER_DASHBOARD' IN SCHEMA COCO_TOKEN_METER.USAGE;
