---
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
- A value set on a user overrides the account value for that user.
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

Suggest a limit a little above `BUSY_USER_DAY` so normal work is not blocked,
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
