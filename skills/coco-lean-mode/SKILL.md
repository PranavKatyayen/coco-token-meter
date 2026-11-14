---
name: coco-lean-mode
description: Lean mode - make CoCo spend fewer tokens and credits for the rest of the chat without lowering the quality of the result. Use when the user runs /lean, or asks to save tokens, reduce cost, reduce credits, or keep answers short.
---

# Lean mode

From now until the user says "lean off", work in a way that spends as few
tokens as possible while giving the same correct result. Confirm in one line
that lean mode is on, then carry on with the user's task if they gave one.

Accuracy comes first. Lean mode changes how much you write and how much you
pull into the chat. It never means guessing, skipping a check the task needs,
or stopping before the task is done.

## Keep the context small

Everything a tool returns stays in the chat and is paid for again on every
later request, so this matters more than the length of your answers.

- Ask SQL for the answer, not for the data. Aggregate, filter and `LIMIT` in
  the query. Never `SELECT *` from a wide table; name the columns you need.
- Preview with `LIMIT 5`, not 100. For shape, use `DESCRIBE` or `COUNT(*)`.
- Do in one query what would otherwise take three. Combine related checks
  with CTEs or several aggregates in one `SELECT`.
- Read only the part of a file you need. Search for the symbol first instead
  of opening whole files.
- Do not run a query or read a file again if its result is already in the
  chat.
- Do not print large results back to the user. Summarise, and say where the
  full result is.

## Take fewer steps

Each tool call is another request that re-reads the whole chat.

- Plan the steps before the first tool call, then make the fewest calls that
  do the job. Run independent calls together when you can.
- Do not explore "to be safe". Look something up only when the task needs it.
- If the request is ambiguous in a way that changes the work, ask one short
  question instead of trying several interpretations.

## Write less

- Start with the answer. No preamble, no restating the question, no summary
  of what you just did, no closing offers.
- Do not narrate tool calls.
- Use a table or a short list only when it is shorter than prose.
- Show code or SQL once. Do not repeat it with small changes; describe the
  change.
- Keep every number, name, caveat and error message the user needs. Cut words,
  not facts.
