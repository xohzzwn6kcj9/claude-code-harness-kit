#!/bin/bash
# PreToolUse hook: steer temp files to ~/tmp, block writes to /tmp family.
#
# Blocks (exit 2) only WRITE intent into /tmp, /var/tmp, /private/tmp,
# /private/var/tmp. Reads from those paths (cat/grep/head ...) pass through —
# external tools legitimately leave artifacts there.
#
# ~/tmp is the sanctioned scratch location. This guard enforces the convention
# of keeping throwaway files under ~/tmp (which you pre-authorize in settings)
# instead of the system /tmp dirs — opt-in: skip this guard if you don't use it.
#
# Exit codes: 0 = pass (normal permission flow), 2 = block with stderr message.

set -euo pipefail

INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')

MSG='BLOCKED: writing to /tmp (or /var/tmp, $TMPDIR) is not allowed by this guard. Put temp files in ~/tmp instead (pre-authorize it in your settings so it never prompts).'

# tmp-family path prefix: /tmp, /var/tmp, /private/tmp, /private/var/tmp
TMP_PREFIX='/(private/)?(var/)?tmp/'

case "$TOOL_NAME" in
  Write)
    FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty')
    if [[ "$FILE_PATH" =~ ^${TMP_PREFIX} ]]; then
      echo "$MSG" >&2
      exit 2
    fi
    exit 0
    ;;

  Bash)
    COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')
    [[ -z "$COMMAND" ]] && exit 0

    # 1. Redirect into tmp family:  > /tmp/x   >> "/var/tmp/y"
    if printf '%s\n' "$COMMAND" | grep -qE ">>?[[:space:]]*\"?'?${TMP_PREFIX}"; then
      echo "$MSG" >&2
      exit 2
    fi

    # 2. tee into tmp family
    if printf '%s\n' "$COMMAND" | grep -qE "\btee[[:space:]]+(-[a-zA-Z]+[[:space:]]+)*\"?'?${TMP_PREFIX}"; then
      echo "$MSG" >&2
      exit 2
    fi

    # 3. mkdir / touch / dd of=... targeting tmp family
    if printf '%s\n' "$COMMAND" | grep -qE "\b(mkdir|touch)[[:space:]]+([^|&;]*[[:space:]])?\"?'?${TMP_PREFIX}"; then
      echo "$MSG" >&2
      exit 2
    fi
    if printf '%s\n' "$COMMAND" | grep -qE "\bdd[[:space:]].*\bof=\"?'?${TMP_PREFIX}"; then
      echo "$MSG" >&2
      exit 2
    fi

    # 4. mktemp without an explicit ~/tmp template/dir (default is $TMPDIR or /tmp)
    if printf '%s\n' "$COMMAND" | grep -qE '\bmktemp\b'; then
      if ! printf '%s\n' "$COMMAND" | grep -qE 'mktemp[^|&;]*(~/tmp/|\$HOME/tmp/|/Users/[^/]+/tmp/)'; then
        echo "$MSG" >&2
        exit 2
      fi
    fi

    # 5. cp / mv whose DESTINATION (last token) is under tmp family.
    #    Source-in-/tmp (reading) is allowed; only block writing INTO /tmp.
    if printf '%s\n' "$COMMAND" | grep -qE '\b(cp|mv)[[:space:]]'; then
      LAST=$(printf '%s\n' "$COMMAND" | awk '{print $NF}')
      LAST="${LAST%\"}"; LAST="${LAST%\'}"
      LAST="${LAST#\"}"; LAST="${LAST#\'}"
      if [[ "$LAST" =~ ^${TMP_PREFIX} ]]; then
        echo "$MSG" >&2
        exit 2
      fi
    fi

    exit 0
    ;;

  *)
    exit 0
    ;;
esac
