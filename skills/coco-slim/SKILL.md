---
name: coco-slim
description: Make every CoCo CLI chat cheaper by turning off bundled skills the user never uses. Use when the user runs /slim (list, disable, enable, reset), or asks to shrink the context, reduce the fixed cost of a chat, or disable bundled skills. CoCo CLI only.
---

# Slim the fixed context (CoCo CLI)

CoCo CLI ships with many bundled skills. The name and description of every
one is loaded into every chat and paid for on every request. The setting
`disableBundledSkills` in the CLI settings file is a JSON array of bundled
skill names to leave out.

- Settings file: `~/.snowflake/cortex/settings.json`
  (on Windows `%USERPROFILE%\.snowflake\cortex\settings.json`).
- A disabled skill is only hidden. CoCo can no longer use its specialised
  guidance for that topic until it is enabled again, so only disable skills
  for things the user does not work with.
- The change applies to chats started after the file is saved.
- This works in CoCo CLI. It does not apply to CoCo in Snowsight.

## What to do

- **`list`, or no instruction:** run `cortex skill list`, then show the skills
  under `[BUNDLED]` grouped by topic in a compact list, and mark the ones
  already in `disableBundledSkills`. Ask which topics the user never works
  with. Change nothing yet.
- **`disable <names>`:** add those names to `disableBundledSkills`.
- **`enable <names>`:** remove those names from `disableBundledSkills`.
- **`reset`:** remove the `disableBundledSkills` key so every bundled skill is
  loaded again.

## Rules for editing the settings file

1. Read the file first. If it does not exist, create it containing only
   `{"disableBundledSkills": [...]}`.
2. Keep every other key exactly as it is. The file must stay valid JSON.
3. Only use names that appear under `[BUNDLED]` in `cortex skill list`. If the
   user gave a name that is not there, say so and skip it.
4. Never disable a skill the user did not name. If they named a topic instead
   of skill names, show the matching skills and ask before changing anything.
5. Afterwards, show the final `disableBundledSkills` list in one line, and
   say that it applies to new chats and how to undo it (`/slim enable <names>`
   or `/slim reset`).
