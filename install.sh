#!/bin/bash
# install.sh — copy the hooks (and optionally the repo-radar skill) into your
# ~/.claude directory, then print the settings snippet to merge by hand.
#
# This script deliberately does NOT edit your settings.json: hooks decide what
# runs without a prompt, so wiring them up should stay a conscious step you
# review yourself. It also does not install the per-repo git pre-push hook
# (that is opt-in per repository — see hooks/githooks/pre-push).
#
# Usage:
#   ./install.sh              # install core hooks only
#   ./install.sh --all        # also install the bash-guards, repo-radar + worktree skills
#   ./install.sh --guards     # core hooks + opinionated bash-guards
#   ./install.sh --radar      # core hooks + repo-radar skill
#   ./install.sh --worktree   # core hooks + worktree skill
#   CLAUDE_DIR=/path ./install.sh   # install into a non-default ~/.claude

set -euo pipefail

SRC="$(cd "$(dirname "$0")" && pwd)"
DEST="${CLAUDE_DIR:-$HOME/.claude}"
WANT_GUARDS=0; WANT_RADAR=0; WANT_WORKTREE=0
for a in "$@"; do
  case "$a" in
    --all)      WANT_GUARDS=1; WANT_RADAR=1; WANT_WORKTREE=1 ;;
    --guards)   WANT_GUARDS=1 ;;
    --radar)    WANT_RADAR=1 ;;
    --worktree) WANT_WORKTREE=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

copy() {  # copy src -> dest, backing up an existing, differing file once
  local s="$1" d="$2"
  mkdir -p "$(dirname "$d")"
  if [ -e "$d" ] && ! cmp -s "$s" "$d"; then
    cp "$d" "$d.bak"
    echo "note: $d differed — backed up to $(basename "$d").bak"
  fi
  cp "$s" "$d"
  case "$s" in *.sh|*.py) chmod +x "$d" ;; esac
  echo "installed: $d"
}

# --- core hooks (always) ---
copy "$SRC/hooks/auto-approve-readonly.sh"      "$DEST/hooks/auto-approve-readonly.sh"
copy "$SRC/hooks/deny-secret-file-reads.sh"     "$DEST/hooks/deny-secret-file-reads.sh"
copy "$SRC/hooks/secret-scan.sh"                "$DEST/hooks/secret-scan.sh"
copy "$SRC/hooks/playwright-screenshot-guard.sh" "$DEST/hooks/playwright-screenshot-guard.sh"

# --- opinionated bash guards (opt-in) ---
if [ "$WANT_GUARDS" = 1 ]; then
  for g in "$SRC"/hooks/bash-guards/*.sh; do
    copy "$g" "$DEST/hooks/bash-guards/$(basename "$g")"
  done
fi

# --- repo-radar skill (opt-in) ---
if [ "$WANT_RADAR" = 1 ]; then
  for f in "$SRC"/skills/repo-radar/scripts/*.py; do
    copy "$f" "$DEST/skills/repo-radar/scripts/$(basename "$f")"
  done
  copy "$SRC/skills/repo-radar/SKILL.md" "$DEST/skills/repo-radar/SKILL.md"
  copy "$SRC/skills/repo-radar/references/classify-heuristics.md" \
       "$DEST/skills/repo-radar/references/classify-heuristics.md"
fi

# --- worktree skill (opt-in) ---
if [ "$WANT_WORKTREE" = 1 ]; then
  copy "$SRC/skills/worktree/scripts/worktree.sh" "$DEST/skills/worktree/scripts/worktree.sh"
  copy "$SRC/skills/worktree/SKILL.md"            "$DEST/skills/worktree/SKILL.md"
fi

cat <<EOF

Done. Next: wire the hooks into $DEST/settings.json — see settings.example.json
for a full example (and a recommended permissions.deny baseline). Restart your
Claude Code session (or run /hooks) to pick up the change, then sanity-check
with e.g. \`git status\` — it should run without a permission prompt.

The git pre-push secret scanner is per-repo and opt-in:
  cp hooks/githooks/pre-push <repo>/.git/hooks/pre-push && chmod +x <repo>/.git/hooks/pre-push
EOF
