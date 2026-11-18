# Hello Kit

A small example of an Agent Kit: it greets you when a Claude Code session starts.

## What it changes
- A block in CLAUDE.md that imports the kit's rules.
- One SessionStart hook that prints a greeting line to stderr.
- One tool, `hello`, that prints the same greeting.
- One setting, `greeting`, passed to the hook and the tool as KIT_GREETING.

## Requirements
Only `sh`, which every Mac has.

## Customise
Change the greeting in the Kit pane's settings. Put your own lines in `local.md` in the kit's config folder: Claude Code reads it last. If a line in local.md contradicts the kit, the result is undefined: switch the piece off instead. A script that needs to keep files between runs can use the folder named by KIT_STATE_DIR.

## Remove
Choose Remove in the Kit pane. Prosper takes back the CLAUDE.md block, the hook and the tool, and leaves the rest of your files as they were.
