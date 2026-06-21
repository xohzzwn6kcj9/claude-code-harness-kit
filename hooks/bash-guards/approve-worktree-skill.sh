#!/bin/bash
# approve-worktree-skill.sh — Claude Code PreToolUse hook (opt-in companion to the worktree skill).
#
# Auto-approves a worktree.sh skill-script subcommand. The kit ships NO `Bash(bash …)` allow rule
# (such a glob would let `bash -c '<payload>'` smuggle code), so a plain
#   bash ~/.claude/skills/worktree/scripts/worktree.sh push foo
# would otherwise PROMPT — stalling an unattended /loop. On top of that, Claude Code's matcher does
# NOT strip a leading env-var assignment, so even a static allow rule could not cover the worktree
# skill's documented env-prefixed fast-path
#   WORKTREE_SKIP_TESTS=1 bash ~/.claude/skills/worktree/scripts/worktree.sh pr foo
# This hook closes both gaps: it strips ONLY an allowlisted env prefix (via lib/strip-safe-env.sh),
# then auto-approves ONLY a clean (no pipe / ; / && / redirect / subshell) worktree.sh subcommand.
# Limitation (fail-safe): a QUOTED multi-word value, e.g. WORKTREE_TEST_CMD='a b', is not fully
# stripped by the shared helper, so that form simply DEFERS to a prompt — never wrongly approved.
#
# Safety: this hook ONLY ever emits an "allow" decision or exits 0 (defer to the normal permission
# flow). It NEVER denies, and an allow does not override deny rules (deny-first precedence is kept by
# Claude Code). The env-prefix strip is an ALLOWLIST (lib/strip-safe-env.sh): a dangerous prefix
# (BASH_ENV / DYLD_* / GIT_SSH_COMMAND / PATH / …) is left intact, so the command matches no approve
# shape and we DEFER to the human — a missed approval costs one prompt, never a silent RCE. The
# approved target is the kit's own trusted worktree.sh (it parses .worktreeconfig, never sources it).
#
# Opt-in: install only if you use the worktree skill (`./install.sh --worktree --guards`). A
# non-default CLAUDE_DIR install just defers (one prompt) instead of matching.
# Requires: bash 3.2+, jq (missing jq -> fail open / defer).
#
# Exit codes: 0 always (allow JSON on stdout, or nothing = defer).

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq -> defer

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$COMMAND" ] || exit 0

# --- strip ONLY allowlisted leading env-var assignments via the shared lib ---
# A dangerous prefix (BASH_ENV/DYLD_*/GIT_SSH_COMMAND/PATH/…) is NOT stripped, so it stays the first
# word, matches no approve shape below, and we defer. Lib missing / fn undefined -> exit 0 (defer =
# fail safe), never strip-and-approve a dangerous prefix. (A leading `#` comment line is not handled:
# it simply won't match the `^bash …` shape and defers — harmless, and the bash style bans comments.)
EFFECTIVE_CMD="$COMMAND"
SAFE_ENV_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/strip-safe-env.sh"
[ -r "$SAFE_ENV_LIB" ] && source "$SAFE_ENV_LIB"
declare -f strip_safe_env_prefix >/dev/null || exit 0
EFFECTIVE_CMD="$(strip_safe_env_prefix "$EFFECTIVE_CMD")"

# --- never auto-approve compound / redirecting commands ---
case "$EFFECTIVE_CMD" in
  *"|"* | *"&"* | *";"* | *">"* | *"<"* | *'`'* | *'$('* ) exit 0 ;;
esac

# --- allow-listed worktree.sh subcommands only (~ or $HOME-absolute home path) ---
# create|sync|push|pr|cleanup all have side effects but target the kit's own trusted worktree.sh; a
# KNOWN subcommand token is REQUIRED (no optional/empty match) so `worktree.sh nuke` or a bare
# `worktree.sh` still falls through to the normal permission flow. $HOME expands at hook runtime.
if [[ "$EFFECTIVE_CMD" =~ ^bash[[:space:]]+(~|$HOME)/\.claude/skills/worktree/scripts/worktree\.sh[[:space:]]+(create|sync|push|pr|cleanup)([[:space:]]|$) ]]; then
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"allow-listed worktree.sh skill-script (env-prefix stripped)"}}\n'
  exit 0
fi

# everything else -> defer to normal permission flow
exit 0
