#!/usr/bin/env bash
# PreToolUse:Bash guard — keep foreground sleep-poll loops off the approval-prompt
# path. A `while`/`until` loop with an inline `sleep` is a busy-wait that (a) as a
# compound (`$()`+arith) can't be statically analyzed → forces a "cannot be
# statically analyzed" prompt that STALLS an unattended /loop, and (b) is the wrong
# tool: harness-tracked background Workflows/Tasks auto-reinvoke on completion, so
# hand-polling their journal is wasted work (foreground sleep discouraged).
#
# exit 2 + stderr => the message is fed back to the model, which rewrites the
# command itself (no human prompt) — same mechanism as the compound-cd /
# brace-expansion guards. NUDGE guard, not a security boundary: a bypass just
# reverts to the status-quo prompt, so precision (no false blocks) is prioritized.
# Fails OPEN (var-presence checks, no set -e).

COMMAND=$(jq -r '.tool_input.command')
[ -n "$COMMAND" ] || exit 0    # fail-open on empty / parse-miss

# Heredoc? A `while`/`until`/`sleep` in a heredoc is document DATA, not an inline
# loop (the real poll would run later via `bash <file>`, not caught here). Pass.
printf '%s\n' "$COMMAND" | grep -q '<<' && exit 0

# Strip quoted strings, then strip word-boundary `#` comments to EOL, so a loop
# keyword or `sleep` inside a quoted arg / URL / trailing comment can't false-fire.
STRIPPED=$(printf '%s\n' "$COMMAND" | sed -E \
  -e 's/"[^"]*"//g' \
  -e "s/'[^']*'//g" \
  -e 's/(^|[[:space:];&|])#.*$/\1/')

# Gate 1: an UNBOUNDED busy-wait keyword — while/until only. A `for` iterates a
# bounded list (`for … sleep` = pacing, not a poll) and "for" also lives inside
# `git for-each-ref` etc., so it is deliberately excluded.
printf '%s\n' "$STRIPPED" | grep -qE '\b(while|until)\b' || exit 0
# Gate 2: a foreground `sleep <arg>` in command position — ANY arg (numeric,
# $VAR, $((..)), $(..)); a sleep inside a while/until loop is a poll regardless.
printf '%s\n' "$STRIPPED" | grep -qE '(^|[|&;[:space:]])sleep[[:space:]]+[^[:space:]]' || exit 0

echo 'BLOCKED: a foreground sleep-poll busy-wait loop is not auto-approved ("cannot be statically analyzed") and silently STALLS an unattended /loop. Harness-tracked background Workflows/Tasks auto-reinvoke you on completion, so hand-polling their journal is wasted work. Do one of: (1) just wait for the completion notification, (2) if you only need results, Read journal.jsonl once with the Read tool, (3) if you genuinely must wait on a condition, use the Monitor tool.' >&2
exit 2
