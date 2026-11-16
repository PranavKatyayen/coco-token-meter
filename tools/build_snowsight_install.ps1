# Builds install_in_snowsight.sql: one self-contained SQL file that installs
# coco-token-meter from a Snowsight worksheet, with no CLI and no local files.
#
#   powershell -ExecutionPolicy Bypass -File tools\build_snowsight_install.ps1
#
# It takes sql/setup.sql, replaces the PUT statements (which only work from a
# client) with the skill files written inline, adds the dashboard, and ends by
# installing the skills for the person running it. Run it again whenever
# sql/setup.sql, a skill or the dashboard changes.

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
function ReadText($relative) {
    [IO.File]::ReadAllText((Join-Path $root $relative)).Replace("`r`n", "`n")
}

$setup = ReadText 'sql\setup.sql'
$files = [ordered]@{
    '@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-token-usage/SKILL.md'  = ReadText 'skills\coco-token-usage\SKILL.md'
    '@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-admin-limits/SKILL.md' = ReadText 'skills\coco-admin-limits\SKILL.md'
    '@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/streamlit_app.py'        = ReadText 'dashboard\streamlit_app.py'
    '@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/environment.yml'         = ReadText 'dashboard\environment.yml'
}
foreach ($path in $files.Keys) {
    if ($files[$path].Contains('$$')) { throw "File for $path contains `$`$ and cannot be embedded." }
}

# --- 1. setup.sql without its client-side PUT statements
$putPattern = "(?m)^PUT 'file://[^']+' @SKILLS_STAGE/[^\n]+\n\s+AUTO_COMPRESS = FALSE OVERWRITE = TRUE;\n"
$putCount = [regex]::Matches($setup, $putPattern).Count
if ($putCount -ne 2) { throw "Expected 2 PUT statements in sql/setup.sql, found $putCount." }
$setup = [regex]::Replace($setup, $putPattern, '')
$marker = "CREATE OR REPLACE PROCEDURE INSTALL_MY_SKILLS("
if (-not $setup.Contains($marker)) { throw 'INSTALL_MY_SKILLS not found in sql/setup.sql.' }

# --- 2. a helper that writes text to a stage, and the skill files
$helper = @'
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

'@.Replace("`r`n", "`n")

function WriteCall($path) {
    "CALL WRITE_STAGE_FILE('$path', `$`$" + $files[$path] + "`$`$);`n`n"
}
$skillCalls = (WriteCall '@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-token-usage/SKILL.md') +
              (WriteCall '@COCO_TOKEN_METER.USAGE.SKILLS_STAGE/coco-admin-limits/SKILL.md')
$setup = $setup.Replace($marker, $helper + $skillCalls + $marker)

# --- 3. the dashboard, on the warehouse the worksheet is using
$dashboard = @'

-- ---------------------------------------------------------------------------
-- Admin dashboard (Streamlit in Snowflake). It runs its queries on the
-- warehouse this worksheet is using.
-- ---------------------------------------------------------------------------
USE SCHEMA COCO_TOKEN_METER.USAGE;

CREATE STAGE IF NOT EXISTS DASHBOARD_STAGE
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = 'coco-token-meter: files of the admin dashboard';

'@.Replace("`r`n", "`n")
$dashboard += (WriteCall '@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/streamlit_app.py') +
              (WriteCall '@COCO_TOKEN_METER.USAGE.DASHBOARD_STAGE/environment.yml')
$dashboard += @'
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
'@.Replace("`r`n", "`n")

$header = @'
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

'@.Replace("`r`n", "`n")

$out = Join-Path $root 'install_in_snowsight.sql'
[IO.File]::WriteAllText($out, $header + $setup.TrimEnd() + "`n" + $dashboard, (New-Object Text.UTF8Encoding $false))
"Wrote $out ({0:N0} characters)" -f (Get-Item $out).Length
