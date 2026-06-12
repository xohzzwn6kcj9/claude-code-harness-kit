#!/usr/bin/env bash
# PreToolUse(Bash) guard — block `xargs` and process substitution `<(...)`.
#
# Opinionated style enforcement: both are easy to misuse in agent-generated
# one-liners (xargs splitting on whitespace; `<()` not being auto-approvable by
# the permission matcher and behaving differently across shells). The guard
# nudges the model to use a `for` loop / `sed` instead of xargs, and `git diff`
# / a temp file instead of process substitution.
#
# Quoted occurrences (inside "..." or '...') are ignored, so a literal "xargs"
# in a commit message or an awk program does not trip it.
#
# Exit codes: 0 = pass, 2 = block (stderr fed back to the model, which rewrites).

COMMAND=$(jq -r '.tool_input.command' 2>/dev/null) || exit 0
[ -z "$COMMAND" ] && exit 0

# Strip quoted strings so matches only fire on real shell tokens.
STRIPPED=$(printf '%s\n' "$COMMAND" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

if printf '%s\n' "$STRIPPED" | grep -qE '(^|[|&;])[[:space:]]*xargs([[:space:]]|$)'; then
  echo 'BLOCKED: Do not use xargs. Use a for loop or sed instead.' >&2
  exit 2
fi

if printf '%s\n' "$STRIPPED" | grep -qE '<\('; then
  echo 'BLOCKED: Do not use process substitution <(). Use git diff or a temp file instead.' >&2
  exit 2
fi

exit 0
