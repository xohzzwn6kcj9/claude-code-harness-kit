#!/bin/bash
# install.sh — copy the hooks into ~/.claude/hooks/ and print the settings
# snippet to merge into ~/.claude/settings.json.
#
# This script deliberately does NOT edit your settings.json: hooks decide what
# runs without a prompt, so the wiring step should stay a conscious, manual
# action you review yourself.

set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
HOOKS_DIR="${CLAUDE_DIR:-$HOME/.claude}/hooks"

mkdir -p "$HOOKS_DIR"

for f in auto-approve-readonly.sh deny-secret-file-reads.sh; do
  if [ -e "$HOOKS_DIR/$f" ] && ! cmp -s "$SRC_DIR/hooks/$f" "$HOOKS_DIR/$f"; then
    cp "$HOOKS_DIR/$f" "$HOOKS_DIR/$f.bak"
    echo "note: existing $HOOKS_DIR/$f differed — backed up to $f.bak"
  fi
  cp "$SRC_DIR/hooks/$f" "$HOOKS_DIR/$f"
  chmod +x "$HOOKS_DIR/$f"
  echo "installed: $HOOKS_DIR/$f"
done

cat <<'EOF'

Done. Now wire the hooks up — merge this into ~/.claude/settings.json
(create the file with just this content if it does not exist):

  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|Read",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/deny-secret-file-reads.sh" }
        ]
      },
      {
        "matcher": ".*",
        "hooks": [
          { "type": "command", "command": "~/.claude/hooks/auto-approve-readonly.sh" }
        ]
      }
    ]
  }

See settings.example.json for a full example including a recommended
permissions.deny baseline. Restart your Claude Code session (or run /hooks)
to pick up the change, then sanity-check with e.g. `git status` — it should
run without a permission prompt.
EOF
