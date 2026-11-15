-- Copies the skills into YOUR Snowsight personal workspace, where CoCo in
-- Snowsight loads skills from (.snowflake/cortex/skills/).
--
-- Each user runs this once, from the root of this repository, with any role:
--
--   snow sql -c <connection> -f sql/install_snowsight_skills.sql
--
-- USER$ is your personal database and "DEFAULT$" your default workspace.
-- To remove the skills again, run sql/uninstall_snowsight_skills.sql.

PUT 'file://skills/coco-token-usage/SKILL.md'
    'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-token-usage/'
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

PUT 'file://skills/coco-lean-mode/SKILL.md'
    'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-lean-mode/'
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

PUT 'file://skills/coco-admin-limits/SKILL.md'
    'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-admin-limits/'
    AUTO_COMPRESS = FALSE OVERWRITE = TRUE;

LS 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/';
