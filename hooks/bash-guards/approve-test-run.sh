#!/usr/bin/env bash
# PreToolUse(Bash) approve hook: auto-approve a SAFELY-SHAPED shell-test run.
#
# Replaces a broad `Bash(bash *.test.sh:*)` allow rule, which was exploitable: the glob `*`
# greedily absorbs flags, so a SINGLE segment `bash -c 'rm -rf ~' x.test.sh` matched that rule and
# ran arbitrary code WITHOUT a prompt (here x.test.sh is merely $0; the `-c` payload executes). The
# per-segment matching that protects compound commands does NOT catch this single-segment smuggle.
#
# This hook parses the command and approves ONLY when EVERY segment is one of:
#   (a) a safe test run: `bash [--] SCRIPT [ARGS...]` where SCRIPT ends in `.test.sh` AND the token
#       right after `bash` IS the script (no option like `-c`/`-s` precedes it) — so `bash -c …`
#       can never qualify. ARGS after SCRIPT are positional (passed to the trusted script, not
#       interpreted by bash), or
#   (b) a read-only inspector (tail/head/cat/grep/wc/jq/sort/…) — so `bash x.test.sh | tail -3`
#       and the original `… | tail -3 ; jq . settings.json` still auto-approve.
# At least ONE segment must be a test run (pure read-only chains are auto-approve-readonly's job).
#
# Defers (exit 0 → normal permission flow) on: bash with any option before the script, ANY leading
# env-var assignment (a stripped `BASH_ENV=…`/`ENV=…` would let bash source attacker code at startup
# while the rest still matched — so env prefixes are NOT stripped; they defer), a non-listed command,
# subshell `$(`/backtick, redirect `<`/`>`, background/`&` (also `&&`), an empty segment (e.g. from
# `||`), or a newline. NEVER denies; only ever emits allow or exits 0. Fails open on any parse error.
# (Creation-side pair: enforce-test-location.sh keeps *.test.sh files under tests/.)
#
# Exit codes: 0 always (allow JSON on stdout, or nothing = defer).

set -u

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$COMMAND" ] || exit 0

# NOTE: the raw command is used verbatim — NO comment/env-prefix stripping. Stripping a leading
# `VAR=val` would approve `BASH_ENV=~/tmp/evil.sh bash x.test.sh` (matcher sees `bash x.test.sh`)
# while the executed command still carries BASH_ENV → bash sources evil.sh at startup. A leading
# env assignment therefore makes the first word `VAR=…`, which matches neither bash nor a read-only
# tool → defer (prompt). Test runs don't need env prefixes.
EFFECTIVE_CMD="$COMMAND"

# --- reject subshell / command-substitution / redirect / background / newline (keep | and ; only) ---
case "$EFFECTIVE_CMD" in
  *'$('* | *'`'* | *'>'* | *'<'* | *'&'* | *$'\n'* ) exit 0 ;;
esac

# Read-only inspectors permitted as non-test segments (output shapers only — no write/exec).
READONLY=" cat head tail less more wc grep rg sort uniq cut jq yq diff comm column nl tr fold od xxd echo printf true "

SAW_TEST_RUN=0
SEGS=$(printf '%s' "$EFFECTIVE_CMD" | tr '|;' '\n\n')
while IFS= read -r SEG; do
  # trim
  SEG="${SEG#"${SEG%%[![:space:]]*}"}"
  SEG="${SEG%"${SEG##*[![:space:]]}"}"
  [ -n "$SEG" ] || exit 0   # empty segment (e.g. from ||) → defer

  FIRST_WORD="${SEG%%[[:space:]]*}"
  BASE="${FIRST_WORD##*/}"

  if [ "$BASE" = "bash" ]; then
    set -f
    # shellcheck disable=SC2086
    set -- $SEG
    set +f
    if [ "${2:-}" = "--" ]; then
      SCRIPT="${3:-}"
    else
      case "${2:-}" in -*) exit 0 ;; esac   # an option before the script (e.g. -c) → defer
      SCRIPT="${2:-}"
    fi
    [ -n "$SCRIPT" ] || exit 0
    case "$SCRIPT" in *.test.sh) ;; *) exit 0 ;; esac
    SAW_TEST_RUN=1
  else
    case "$READONLY" in *" $BASE "*) ;; *) exit 0 ;; esac
  fi
done <<EOF
$SEGS
EOF

[ "$SAW_TEST_RUN" = 1 ] || exit 0

printf '{"decision":"approve","hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"safely-shaped shell-test run (bash <script>.test.sh, optional read-only pipe; no bash options before the script)"}}\n'
exit 0
