#!/usr/bin/env bash
# PreToolUse:Bash guard — block a RELATIVE-path `cd` inside a compound command.
#
# Why: a relative `cd` in an `&&`/`||`/`;` chain cannot be statically resolved by
# the permission matcher, so `Bash(cd:*)` does NOT auto-approve it. In an
# unattended /loop the tick then silently STALLS on an approval prompt (a real
# incident blocked a pr-review tick ~4h overnight), and a half-run
# `cd <rel> && git merge` can corrupt the main worktree.
#
# Allowed (pass through): a single `cd` command (no chain), or a compound `cd`
# with an ABSOLUTE/`~`/`$VAR` path (statically resolvable → auto-approved).
# Preferred alternative the model is nudged toward: `git -C <abs>` /
# `./gradlew -p <abs>` (no cd at all).
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

exit 0
