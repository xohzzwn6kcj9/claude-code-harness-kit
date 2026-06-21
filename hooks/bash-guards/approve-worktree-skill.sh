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
# This hook closes both gaps: it defers on ANY shell metacharacter, strips ONLY an allowlisted env
# prefix (via lib/strip-safe-env.sh), then auto-approves ONLY an exact-shape worktree.sh subcommand.
# Limitation (fail-safe): a QUOTED multi-word value, e.g. WORKTREE_TEST_CMD='a b', is not fully
# stripped by the shared helper, so that form simply DEFERS to a prompt — never wrongly approved.
#
# Safety: this hook ONLY ever emits an "allow" decision or exits 0 (defer to the normal permission
# flow). It NEVER denies, and an allow does not override deny rules (deny-first precedence is kept by
# Claude Code). Two layered defenses against a dual-parser bypass — the env-prefix strip is
# space-delimited, so a metacharacter embedded in an env VALUE (e.g. WORKTREE_TEST_CMD=x>~/.bashrc)
# would be consumed by the strip yet parsed as a redirect/operator by the real shell that runs the
# ORIGINAL command: (1) we defer on any metacharacter in the ORIGINAL $COMMAND, BEFORE stripping;
# (2) strip-safe-env.sh itself refuses to strip a value carrying a metacharacter. A missed approval
# costs one prompt; a wrong approval would be a silent RCE — so when in doubt we defer.
#
# Opt-in: install only if you use the worktree skill (`./install.sh --worktree --guards`). A
# non-default CLAUDE_DIR install just defers (one prompt) instead of matching.
# Requires: bash 3.2+, jq (missing jq -> fail open / defer).
#
# Exit codes: 0 always (allow JSON on stdout, or nothing = defer).

set -u

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq -> defer

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ "$TOOL_NAME" = "Bash" ] || exit 0

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$COMMAND" ] || exit 0

# --- defer on ANY shell metacharacter / newline in the ORIGINAL command (defense layer 1) ---
# We only ever approve a single simple command `[ENV=val ]bash …/worktree.sh <subcmd> <feature>`,
# which contains none of these. Checking the ORIGINAL (not the post-strip string) is load-bearing:
# the env-prefix strip is space-delimited, so a metachar inside an env value, or a trailing
# `; rm -rf ~`, must be caught here against the string the shell actually parses.
case "$COMMAND" in
  *'|'* | *'&'* | *';'* | *'>'* | *'<'* | *'`'* | *'$('* | *'('* | *')'* ) exit 0 ;;
esac
# a literal newline would also split into extra tokens below (hiding a 2nd line like `rm -rf ~`);
# build it via printf (command substitution strips a trailing newline, so pad with x then trim it).
NL=$(printf '\nx'); NL=${NL%x}
case "$COMMAND" in *"$NL"* ) exit 0 ;; esac

# --- strip ONLY an allowlisted leading env prefix via the shared lib (defense layer 2) ---
# A dangerous prefix (BASH_ENV/DYLD_*/GIT_SSH_COMMAND/…) or a metachar-bearing value is NOT stripped,
# so it stays the first word, fails the exact match below, and we defer. Lib missing / fn undefined
# -> exit 0 (defer = fail safe), never strip-and-approve a dangerous prefix.
SAFE_ENV_LIB="$(dirname "${BASH_SOURCE[0]}")/lib/strip-safe-env.sh"
[ -r "$SAFE_ENV_LIB" ] && . "$SAFE_ENV_LIB"
declare -f strip_safe_env_prefix >/dev/null || exit 0
EFFECTIVE_CMD="$(strip_safe_env_prefix "$COMMAND")"

# --- exact-token match: `bash <worktree.sh path> <subcommand> [feature…]` ---
# Word-split (set -f so no glob expansion); $HOME expands in the pattern, ~ stays literal. A bare or
# unknown subcommand -> empty/no match -> defer. create|sync|push|pr|cleanup all have side effects
# but target the kit's own trusted worktree.sh (it parses .worktreeconfig, never sources it).
set -f
set -- $EFFECTIVE_CMD
set +f
[ "${1:-}" = "bash" ] || exit 0
case "${2:-}" in
  "$HOME/.claude/skills/worktree/scripts/worktree.sh" | "~/.claude/skills/worktree/scripts/worktree.sh") ;;
  *) exit 0 ;;
esac
case "${3:-}" in
  create|sync|push|pr|cleanup) ;;
  *) exit 0 ;;
esac

printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"allow-listed worktree.sh skill-script (env-prefix stripped)"}}\n'
exit 0
