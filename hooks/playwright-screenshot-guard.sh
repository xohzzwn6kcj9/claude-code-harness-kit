#!/usr/bin/env bash
# PreToolUse(browser_take_screenshot) guard: keep verification screenshots inside the
# git-ignored .playwright-mcp/ dir. An explicit *relative* filename is resolved against cwd
# (the repo root), escaping the ignore rule and leaving an untracked PNG in the repo root.
#
# Auto-named screenshots (no filename) already land in .playwright-mcp/. The leak only happens
# when an explicit RELATIVE filename is passed. Allowed targets (pass through):
#   - no filename            -> auto-named into .playwright-mcp/
#   - .playwright-mcp/...    -> already in the ignored dir
#   - any ABSOLUTE path      -> an explicit, intentional destination you chose
# A relative filename outside .playwright-mcp/ is denied with a self-correcting message.
#
# Requires python3 (used only to parse/emit JSON). Wire it on the
# mcp__*playwright*__browser_take_screenshot matcher (see settings.example.json).
#
# Fails OPEN: any parse error / unknown shape exits 0 and never blocks a legit call.
input=$(cat)

fn=$(printf '%s' "$input" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("tool_input",{}).get("filename",""))' 2>/dev/null) || exit 0

[ -z "$fn" ] && exit 0

case "$fn" in
  .playwright-mcp/*) exit 0 ;;
  /*) exit 0 ;;                 # any absolute path is an explicit, intentional target
esac

reason="browser_take_screenshot filename \"$fn\" would save OUTSIDE the git-ignored .playwright-mcp/ dir. A relative filename resolves against the repo root and leaves an untracked PNG there. Fix: omit 'filename' (auto-names into .playwright-mcp/), OR prefix it -> filename: \".playwright-mcp/$fn\", OR pass an absolute path to an intentional location."
printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":%s}}\n' \
  "$(printf '%s' "$reason" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read()))')"
exit 0
