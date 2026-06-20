#!/usr/bin/env bash
# PreToolUse:Bash guard — block an absolute interpreter path that is IDENTICAL to
# what the bare command name resolves to on this machine (`command -v <name>`).
#
# Why: the permission matcher keys Bash(<name>:*) allow rules on the literal first
# token. An absolute path like /opt/homebrew/bin/python3 does NOT start with
# `python3`, so it matches NO allow rule and forces a human approval prompt
# (kills unattended /loop ticks) — even though bare `python3` would auto-approve
# and, when `command -v python3` == that path, runs the EXACT same interpreter.
# A compound command makes it worse: EVERY segment must auto-approve, so one
# absolute interpreter defeats the whole chain.
#
# Block ONLY when the absolute path == `command -v <basename>` (provably redundant,
# so a rewrite to the bare name is always semantics-preserving):
#   /opt/homebrew/bin/python3      == PATH's python3            -> BLOCK (use bare)
#   /usr/bin/python3               (PATH's python3 is brew)     -> PASS  (deliberate
#                                                                distinct interpreter)
#   /opt/homebrew/bin/python3.13   (basename not in NAMES)      -> PASS  (version-pinned)
#   /Users/.../venv/bin/python     (!= `command -v python`)     -> PASS  (venv)
#
# Only COMMAND-position tokens are inspected (start, or after | & ; ( ), so an
# absolute path used as an ARGUMENT (`ls -l /opt/homebrew/bin/python3`) is ignored.
# Fails OPEN: any parse/dep error, or a basename that doesn't resolve, exits 0.
# Assumes the hook's PATH matches the Bash tool's login PATH (both inherit the
# user's profile — homebrew bin first); if they diverged, command -v could differ,
# but the fail-open + exact-match design only ever blocks a provably-redundant path.
#
# exit 2 + stderr => message is fed back to the model, which rewrites & retries
# itself (no human prompt) — same mechanism as the xargs / compound-cd guards.

COMMAND=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$COMMAND" ] && exit 0

# Drop quoted strings so an absolute path inside a quote / commit message / heredoc
# arg never triggers.
STRIPPED=$(printf '%s\n' "$COMMAND" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

# Interpreters / package managers that have a bare Bash(<name>:*) allow rule and
# get absolute-pathed out of habit (copy from `which`, tab-complete, etc.).
NAMES=" python3 python pip3 pip uv pipx node npm npx pnpm yarn go cargo make "

# Candidate = absolute path token at a COMMAND position (start, or after | & ; ( ).
candidates=$(printf '%s\n' "$STRIPPED" | grep -oE '(^|[|&;(])[[:space:]]*/[A-Za-z0-9_@.+/-]+' 2>/dev/null) || exit 0
[ -z "$candidates" ] && exit 0

while IFS= read -r raw; do
  [ -z "$raw" ] && continue
  tok="/${raw#*/}"          # strip leading operator/whitespace up to the first /
  base="${tok##*/}"         # basename
  case "$NAMES" in *" $base "*) ;; *) continue ;; esac
  resolved=$(command -v "$base" 2>/dev/null) || resolved=""
  if [ -n "$resolved" ] && [ "$resolved" = "$tok" ]; then
    echo "BLOCKED: '$tok' is exactly what bare '$base' resolves to on this machine (command -v $base). The absolute path matches NO Bash($base:*) allow rule, so it forces a permission prompt (stalls unattended /loop ticks) — in a compound command it defeats the whole chain. Bare '$base' auto-approves and runs the identical interpreter: rewrite '$tok' -> '$base' and retry. (A deliberately distinct interpreter — /usr/bin/python3, a version-pinned python3.13, or a venv path — is not flagged.)" >&2
    exit 2
  fi
done <<EOF
$candidates
EOF

exit 0
