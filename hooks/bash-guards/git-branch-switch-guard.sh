#!/usr/bin/env bash
# PreToolUse(Bash) guard — block `git checkout/switch <existing-branch>` in the
# MAIN worktree (a git-worktree-workflow safety rule).
#
# Why: if you keep the main worktree pinned to main/master and do feature work
# in separate `git worktree add .worktree/<name>` checkouts, then a stray
# `git checkout feature-x` in the main worktree silently moves it off main and
# disrupts other sessions/tools sharing that worktree. This blocks that case.
#
# Passes through (allowed):
#   - checkout/switch to master or main
#   - creating a new branch (-b / -B / -c / -C / --create)
#   - any command already running inside a .worktree/ path (cwd contains /.worktree/)
#   - `git checkout -- <path>` (file restore, the `--` form)
#
# Opt-in: this encodes a specific worktree workflow. Skip it if you don't use
# one. Exit codes: 0 = pass, 2 = block.

INPUT=$(cat)
COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command' 2>/dev/null) || exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -z "$CWD" ] && CWD="$PWD"

if printf '%s' "$COMMAND" | grep -qE 'git\s+(checkout|switch)\s+' \
  && ! printf '%s' "$COMMAND" | grep -qE 'git\s+(checkout|switch)\s+(--|master|main)(\s|$)' \
  && ! printf '%s' "$COMMAND" | grep -qE 'git\s+(checkout|switch)\s+(-[bBcC]|--create)(\s|$)' \
  && ! printf '%s' "$CWD" | grep -q '/\.worktree/'; then
  echo 'BLOCKED: do not switch to an existing feature branch in the main worktree. Allowed: (a) inside .worktree/<name>/, (b) creating a new branch (-c/-b/--create), (c) master/main. Use `git worktree add` to start feature work.' >&2
  exit 2
fi

exit 0
