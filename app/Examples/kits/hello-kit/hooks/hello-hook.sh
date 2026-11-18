#!/bin/sh
# SessionStart hook: one line to stderr, exit 0. KIT_GREETING comes from the kit's setting.
printf '%s\n' "${KIT_GREETING:-Hello from hello-kit}" >&2
exit 0
