-- Removes the skills from your Snowsight personal workspace.
--
--   snow sql -c <connection> -f sql/uninstall_snowsight_skills.sql

RM 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-token-usage/SKILL.md';
RM 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-lean-mode/SKILL.md';
RM 'snow://workspace/USER$.PUBLIC."DEFAULT$"/versions/live/.snowflake/cortex/skills/coco-admin-limits/SKILL.md';
