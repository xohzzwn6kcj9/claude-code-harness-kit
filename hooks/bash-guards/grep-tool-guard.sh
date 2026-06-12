#!/usr/bin/env bash
# PreToolUse(Bash) guard for read-only repo/code search.
#   Tier 1 (BLOCK): `grep --include=<unquoted glob>` aborts under zsh (glob nomatch:
#                   "no matches found: --include=*.kt"). Recurs 4+ times across sessions.
#   Tier 2 (NUDGE, non-blocking): recursive shell code-search (`grep -r…`) or `find -name/-path`
#                   → suggest the Grep tool / repo-radar skill.
# Fails OPEN: any parse/dep error exits 0 (never blocks the user's command).

input=$(cat)

# Fast path: skip the parse entirely unless the raw payload could be relevant.
case "$input" in
  *include=* | *grep* | *find*) : ;;
  *) exit 0 ;;
esac

cmd=$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

# Tier 1 — block the zsh glob-nomatch trap: a `grep`/`rg` invocation with an UNquoted --include=*glob*
if printf '%s' "$cmd" | grep -Eq -- "(grep|rg)[^|;&]*--include=[^'\"[:space:]]*[*]"; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"zsh aborts `grep --include=*.py` (glob nomatch: 'no matches found'). Use the Grep tool with glob:\"*.py\" + output_mode:\"files_with_matches\", or single-quote it: --include='*.py'."}}
JSON
  exit 0
fi

# Tier 2 — non-blocking nudge for ad-hoc shell code search (read-only inspection)
if printf '%s' "$cmd" | grep -Eq -- "(^|[;&|[:space:]])grep[[:space:]]+-[A-Za-z]*[rR]" ||
  printf '%s' "$cmd" | grep -Eq -- "(^|[;&|[:space:]])find[[:space:]].*[[:space:]]-(name|path)([[:space:]]|=)"; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"Read-only repo/code inspection via bash — prefer the Grep tool (glob/type params) or the repo-radar skill; ad-hoc grep -r / find trips zsh globbing and chained-command prompts."}}
JSON
  exit 0
fi

exit 0
