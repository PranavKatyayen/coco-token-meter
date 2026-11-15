# CoCo Token Meter

Per-chat token and credit usage for Snowflake CoCo (Cortex Code).

After installing, let the application read the usage history and create its
views (replace the application name if you chose another one):

```sql
GRANT IMPORTED PRIVILEGES ON DATABASE SNOWFLAKE TO APPLICATION COCO_TOKEN_METER_APP;
CALL COCO_TOKEN_METER_APP.USAGE.ACTIVATE();
```

Then give people access:

```sql
GRANT APPLICATION ROLE COCO_TOKEN_METER_APP.APP_ADMIN TO ROLE <admin role>;
GRANT APPLICATION ROLE COCO_TOKEN_METER_APP.APP_USER  TO ROLE <any role>;
```

`APP_ADMIN` sees every user's chats and the dashboard. `APP_USER` sees only
the chats of the user running the query, through the `MY_*` views.