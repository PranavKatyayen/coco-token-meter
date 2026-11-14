---
description: Show CoCo token and credit usage per chat (this, top, all, or a thread id)
---

Use the `coco-token-usage` skill to report CoCo token usage.

Arguments given by the user: $ARGUMENTS

- No arguments: list my 20 most recent chats with their token and credit totals.
- `this` or `current`: show the chat that is open now, request by request.
- A number: treat it as a `THREAD_ID` and show that chat request by request.
- `last` or `previous`: show the chat before this one, request by request.
- `top`: show my 10 most expensive chats.
- `tips`: show where my credits went in the last 30 days and how to spend less.
- `all`: list recent chats for all users (needs the `COCO_TOKEN_METER_ADMIN` role).
