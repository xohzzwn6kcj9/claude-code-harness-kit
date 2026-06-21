#!/usr/bin/env bash
# strip-safe-env.sh — shared helper: SAFELY strip a leading shell env-var prefix (`VAR=val ...`)
# from a command before an auto-approve hook matches it. Sourced by approve-worktree-skill.sh.
#
# Why this exists: Claude Code executes the ORIGINAL command, so if an approve hook stripped a
# dangerous leading assignment (BASH_ENV / ENV / BASH_FUNC_* / SHELLOPTS / PS4 / PATH / DYLD_* /
# LD_PRELOAD / NODE_OPTIONS / PYTHONPATH / GIT_SSH_COMMAND / …) just to make the command match an
# allow shape, the executed command would STILL carry that var — bash sources BASH_ENV at startup,
# dyld injects DYLD_* into non-SIP binaries, git execs GIT_SSH_COMMAND — i.e. arbitrary code
# execution with NO human prompt.
#
# Design = ALLOWLIST, not denylist. A denylist must enumerate every loader/interpreter/linker var
# that grants code exec (large, OS/tool-version-dependent, grows over time); ONE missed entry =
# silent RCE. An allowlist inverts the failure mode: a name not on it is simply NOT stripped, so it
# stays the command's first word, matches no approve shape, and the caller DEFERS to the human
# prompt — fail-safe. The ONLY env var allowlisted here is the worktree skill's WORKTREE_SKIP_TESTS
# (a pure `=1` comparison in worktree.sh — never executed). WORKTREE_TEST_CMD is deliberately NOT
# allowlisted: worktree.sh `eval`s it, so it is an execution sink that must stay behind a human
# prompt — auto-stripping even a single-token value (`reboot`, a pre-planted script path) would hand
# that string straight to eval with no prompt.
#
# strip_safe_env_prefix <command> -> prints the command with leading ALLOWLISTED env assignments
# removed, STOPPING at the first non-allowlisted (or command-substitution-bearing) assignment so a
# dangerous prefix is left intact (the caller then fails to match -> defers). Pure: no globals
# mutated. Uses [[ =~ ]] + BASH_REMATCH for the NAME=val capture (valid in bash 3.0+/3.2).

strip_safe_env_prefix() {
  local cmd="$1"
  # trim leading whitespace
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  while [[ "$cmd" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([^[:space:]]*)[[:space:]]+ ]]; do
    local name="${BASH_REMATCH[1]}"
    local val="${BASH_REMATCH[2]}"
    local consumed="${BASH_REMATCH[0]}"
    # never strip a value carrying a shell metacharacter — the space-delimited capture above would
    # otherwise absorb `WORKTREE_TEST_CMD=x>~/.bashrc` / `=x|sh` / `=x;rm` into the value, hiding an
    # operator the REAL shell (running the ORIGINAL command) still parses. Leave it -> caller defers.
    case "$val" in *'$('*|*'`'*|*'|'*|*';'*|*'&'*|*'<'*|*'>'*|*'('*|*')'*) break ;; esac
    # only strip the allowlisted NAME (exact match) — otherwise STOP (leave the prefix in place).
    # WORKTREE_TEST_CMD is intentionally absent: worktree.sh eval()s it (see header).
    case "$name" in WORKTREE_SKIP_TESTS) ;; *) break ;; esac
    cmd="${cmd:${#consumed}}"
    cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  done
  printf '%s' "$cmd"
}
