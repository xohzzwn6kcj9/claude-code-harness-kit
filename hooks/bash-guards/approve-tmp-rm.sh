#!/bin/bash
# approve-tmp-rm.sh — Claude Code PreToolUse hook (companion to temp-dir-guard.sh).
#
# Auto-approves `rm` ONLY when every target is a plain file under ~/tmp, the
# sanctioned scratch location. Lets you clean up throwaway files without a
# permission prompt, while leaving rm everywhere else on the normal flow.
#
# This is the ONE approver among the bash-guards: temp-dir-guard.sh steers
# *writes* into ~/tmp, and this completes the convention by letting you *delete*
# from ~/tmp prompt-free. It is opt-in like the rest — skip it if you do not use
# the ~/tmp scratch convention, or if you would rather every rm still prompt.
#
# This hook NEVER blocks. Its only two outcomes are:
#   approve : print {"hookSpecificOutput":{"permissionDecision":"allow",...}}, exit 0
#   defer   : exit 0 with no output  -> normal permission flow decides
#
# Fail-open by design (when in doubt, defer — a false defer costs one prompt;
# a false approve silently deletes). Scope guards:
#   - single simple command (no pipe / ; / & / newline / $() / backtick)
#   - command word is `rm` (bare or absolute path, e.g. /bin/rm)
#   - NO recursive flag (any flag containing r/R) — a `set -f` string hook can't resolve
#     symlinks, so a `~/tmp/<symlink>/…` pointing outside could escape; recursive stays manual
#   - NO leading env prefix (VAR=…) — the exec shell's effective HOME could diverge from ours
#   - every non-flag arg is a STRICT subpath under ~/tmp (≥1 segment, so bare `~/tmp` and
#     `~/tmp/` defer) ; no `..` traversal
#
# Requirements: bash 3.2+, jq. If jq is missing the hook fails open (defers).
# If your scratch dir differs from ~/tmp, edit TMP_DIR below.

set -uo pipefail
set -f   # no glob expansion — decide on the literal command tokens

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq -> defer

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

TMP_DIR="$HOME/tmp"

# Reject compound / substitution / multi-line outright.
case "$COMMAND" in
  *'|'* | *';'* | *'&'* | *'$('* | *'`'* ) exit 0 ;;
esac
[[ "$COMMAND" == *$'\n'* ]] && exit 0

# Strip leading whitespace, split off the command word.
CMD="${COMMAND#"${COMMAND%%[![:space:]]*}"}"
FIRST="${CMD%%[[:space:]]*}"
REST="${CMD#"$FIRST"}"
# reject a leading env assignment (HOME=… rm …): we expand ~ against the hook's $HOME, but the
# exec shell would use the command's effective HOME -> divergence. Defer to the normal prompt.
case "$FIRST" in [A-Za-z_]*=*) exit 0 ;; esac
[ "${FIRST##*/}" = "rm" ] || exit 0   # bare rm or /bin/rm etc.

SAW_TARGET=0
for tok in $REST; do
  case "$tok" in
    --) continue ;;
    -*)
      # any flag containing r/R = recursive removal -> defer (also defers the
      # rare long form --force; harmless, just one prompt — fail-open).
      case "$tok" in *[rR]*) exit 0 ;; esac
      continue ;;
  esac
  # expand a leading ~ / ~/
  case "$tok" in
    '~')   tok="$HOME" ;;
    '~/'*) tok="$HOME/${tok#\~/}" ;;
  esac
  case "$tok" in *..*) exit 0 ;; esac          # no traversal
  case "$tok" in
    "$TMP_DIR"/?*) SAW_TARGET=1 ;;             # strict subpath (>=1 char; bare ~/tmp & ~/tmp/ defer)
    *) exit 0 ;;
  esac
done

[ "$SAW_TARGET" = 1 ] || exit 0   # rm with no concrete ~/tmp target -> defer

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"rm of file(s) under ~/tmp scratch dir"}}\n'
exit 0
