#!/usr/bin/env bash
# PreToolUse:Bash guard — keep compound `cd …` chains off the approval-prompt path
# that silently STALLS an unattended /loop. Two cases:
#
#   Gate 2 — a RELATIVE-path `cd` in an `&&`/`||`/`;` chain cannot be statically
#     resolved by the permission matcher, so `Bash(cd:*)` does NOT auto-approve it
#     (a real incident blocked a pr-review tick ~4h overnight), and a half-run
#     `cd <rel> && git merge` can corrupt the main worktree.
#   Gate 3 — an ABSOLUTE/`~`/`$VAR` `cd` chained BEFORE a `git` command. Even though
#     the path resolves, Claude Code's built-in "changes directory before running
#     git → can execute untrusted hooks" check forces a manual approval prompt that
#     the `Bash(git:*)` allowlist cannot override — same /loop stall. Subagents hit
#     this because they lack the driver's `git -C` habit; this guard forces the
#     rewrite for everyone. `git -C <abs>` is an exact, auto-approving substitute.
#
# Allowed (pass through): a single `cd` (no chain), or an absolute/`~`/`$VAR` `cd`
# NOT followed by git. Preferred alternative the model is nudged toward: `git -C
# <abs>` / `./gradlew -p <abs>` (no cd at all).
#
# exit 2 + stderr => the message is fed back to the model, which rewrites the
# command itself (no human prompt) — same mechanism as the xargs / process-sub
# guards.

COMMAND=$(jq -r '.tool_input.command')

# Gate 1: command is compound (has a chain operator).
printf '%s\n' "$COMMAND" | grep -qE '&&|\|\||;' || exit 0

# Gate 2: a `cd` segment whose first arg char is relative (not / ~ $, and not an
# operator/space — which would be a bare `cd` to $HOME).
if printf '%s\n' "$COMMAND" | grep -qE '(^|[|&;])[[:space:]]*cd[[:space:]]+[^-/~$&|;[:space:]]'; then
  echo 'BLOCKED: relative cd inside a compound command is not auto-approved — in an unattended /loop it silently stalls on an approval prompt, and a half-run `cd <rel> && git merge` can corrupt the main worktree. Use an absolute path (cd /abs/path && ...) or, better, avoid cd entirely: git -C <abs> ... / ./gradlew -p <abs> ...' >&2
  exit 2
fi

# Gate 3: an absolute/`~`/`$` `cd` chained BEFORE a `git` command. Strip quoted
# strings first so a `git` (or `&& git`) inside a quoted arg / grep-pattern cannot
# false-trigger; then require cd → chain-operator → git, all in command position.
STRIPPED=$(printf '%s\n' "$COMMAND" | sed -E 's/"[^"]*"//g' | sed -E "s/'[^']*'//g")
if printf '%s\n' "$STRIPPED" | grep -qE '(^|[|&;])[[:space:]]*cd[[:space:]]+[/~$].*[|&;][[:space:]]*git([[:space:]]|$)'; then
  echo 'BLOCKED: `cd <path> && git ...` is not auto-approved — Claude Code built-in "changes directory before running git -> can execute untrusted hooks" check forces an approval prompt that the Bash(git:*) allowlist cannot override, silently stalling an unattended /loop. Use `git -C <abs-path> ...` instead — exact substitute, auto-approves.' >&2
  exit 2
fi

exit 0
