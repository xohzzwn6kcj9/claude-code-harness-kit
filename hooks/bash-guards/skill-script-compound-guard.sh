#!/usr/bin/env bash
# PreToolUse(Bash) guard: worktree.sh CHAINED with `;` / `&&` / `||` into a compound Bash call.
#
# Why: this kit ships no `Bash(bash …)` allow rule (it would let `bash -c '<payload>'` smuggle
# arbitrary code through a single segment), so a bare worktree.sh call is auto-approved only by
# approve-worktree-skill.sh — which matches an EXACT single-command shape and defers on ANY shell
# metacharacter, including `;`, `&&`, `||`. Chaining worktree.sh with another command therefore
# always falls through to a human permission prompt, with no hint to split the call — stalling an
# unattended /loop. This guard closes that gap: DENY + a corrective hint that steers the model to
# one-operation-per-Bash-call, so the retry auto-approves via approve-worktree-skill.sh.
#
# Scope (deliberately narrow): fires ONLY on a real command separator `;` / `&&` / `||` alongside
# a worktree.sh invocation — NOT a lone redirect (`2>&1`), which a static allow rule may
# legitimately absorb; the redirect advice lives in the hint text instead. A pure pipe (`| tail`)
# is a separate concern and is not handled here. A single leading `cd <abs> &&` is stripped first
# so that common, benign prefix is never denied.
#
# Safety: emits ONLY a deny decision or exits 0 (defer to the normal permission flow). It NEVER
# approves, so the cd-strip / quote-strip can never manufacture an unsafe allow. Quoted
# substrings are stripped before the separator scan so a `;`/`&&` INSIDE a quoted argument (e.g.
# a commit message or PR body) never false-fires. Fails OPEN: any parse/dependency error exits 0
# (never blocks the command).
#
# Exit codes: 0 always (deny JSON on stdout, or nothing = defer). Targets bash 3.2+ (macOS).

set -u

input=$(cat)

# Fast path: only relevant when the payload invokes worktree.sh.
case "$input" in
  *worktree.sh*) : ;;
  *) exit 0 ;;
esac

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq -> defer

[ "$(printf '%s' "$input" | jq -r '.tool_name // empty' 2>/dev/null)" = "Bash" ] || exit 0
cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

# Strip quoted substrings so a separator INSIDE a string (e.g. a commit/PR body) is never parsed
# as a real command separator. Double- then single-quote (same idiom as the kit's other guards).
stripped=$(printf '%s\n' "$cmd" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")

# Strip ONE leading `cd <abs> && ` — a common, benign prefix — before the separator scan. The
# absolute-path char class excludes shell metacharacters, so a metachar-bearing `cd /a/$(evil) &&
# …` fails the match, is left intact, and the `;`/`&&` in the tail still triggers the deny below
# (safe direction — this guard only ever denies or defers, never approves).
stripped=$(printf '%s\n' "$stripped" | sed -E 's#^[[:space:]]*cd[[:space:]]+/[A-Za-z0-9._/-]+[[:space:]]*&&[[:space:]]*##')

# A worktree.sh path AND a real command separator (`;`, `&&`, `||`) in the stripped command.
# `2>&1` carries only a single `&` (not `&&`), so a lone redirect never matches -> out of scope.
if printf '%s' "$stripped" | grep -Eq '\.claude/skills/worktree/scripts/worktree\.sh' &&
   printf '%s' "$stripped" | grep -Eq '(;|&&|\|\|)'; then
  cat <<'JSON'
{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"Don't chain worktree.sh with ; / && / || into one Bash call - a command separator breaks approve-worktree-skill.sh's auto-approval (it matches an exact single-command shape and defers on any metacharacter) and forces a permission prompt. Run each operation as its own Bash tool call: the worktree.sh call alone, then the next command as a separate call. Also drop 2>&1 (the harness captures stderr)."}}
JSON
  exit 0
fi

exit 0
