#!/usr/bin/env bash
# PreToolUse(Write|Edit) hook: enforce that a shell test script (*.test.sh) created/edited
# INSIDE your ~/.claude harness lives under a tests/ directory.
#
# Why: approve-test-run.sh auto-RUNS any `bash <script>.test.sh` without a prompt — it trusts
# the FILENAME pattern. To keep that trust safe, the harness must guarantee *.test.sh files only
# exist where tests belong (a tests/ subtree, e.g. hooks/tests/). This guard is the creation-side
# pair of that auto-run hook: it blocks writing a *.test.sh outside a tests/ subtree within the
# harness and steers it to the canonical location. (pytest / python3 auto-approval is
# INTERPRETER-based, independent of a test file's name/location, so Python tests need no such
# guard — only the shell filename-trust does.)
#
# Scope is deliberately NARROW (fail-open, project-agnostic-safe):
#   - Fires ONLY when the written file's basename matches *.test.sh.
#   - Enforced ONLY inside the ~/.claude harness tree (path contains /.claude/). Other projects
#     keep their own test conventions — this harness rule is never imposed there.
#   - ~/tmp/** is exempt (scratch sandbox).
#   - Requirement: the path must contain a /tests/ segment. Otherwise exit 2 + a steer message
#     (fed back to the model, which moves the file and retries — no human prompt).
#
# Safety: only ever exits 0 (allow/defer) or 2 (block+steer); it NEVER emits an allow decision,
# so it cannot widen permissions — Write/Edit still go through their normal permission flow.
# Fails OPEN on any parse error (missing jq, malformed input, empty path).
#
# Exit codes: 0 = allow/defer, 2 = block (steer on stderr).

INPUT=$(cat)

TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
case "$TOOL_NAME" in
  Write|Edit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null) || exit 0
[ -n "$FILE_PATH" ] || exit 0

# Only shell test scripts are gated.
BASE="${FILE_PATH##*/}"
case "$BASE" in
  *.test.sh) ;;
  *) exit 0 ;;
esac

# Scratch sandbox is exempt (throwaway test scripts allowed there).
case "$FILE_PATH" in
  "$HOME"/tmp/* | "~/tmp/"*) exit 0 ;;
esac

# Enforce only inside the harness tree; never impose this convention on other projects.
case "$FILE_PATH" in
  */.claude/*) ;;
  *) exit 0 ;;
esac

# Inside the harness, a *.test.sh must live under a tests/ subtree.
case "$FILE_PATH" in
  */tests/*) exit 0 ;;
esac

echo "BLOCKED: '$FILE_PATH' is a *.test.sh shell test but is not under a tests/ directory. approve-test-run.sh auto-runs any *.test.sh WITHOUT a prompt, so the harness keeps these files under a tests/ subtree (e.g. hooks/tests/). Move it into a tests/ directory and retry. (Python tests are not affected; ~/tmp/ is exempt.)" >&2
exit 2
