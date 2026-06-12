#!/bin/bash
# deny-secret-file-reads.sh — Claude Code PreToolUse hook (companion guard)
#
# Hard-blocks whole-file reads of secret-bearing files (.env, credentials,
# private keys, ...) via the Bash and Read tools, with a corrective hint to
# read only the specific key instead (grep KEY file).
#
# Why pair this with auto-approve-readonly.sh: once `cat`/`head`/`tail` are
# auto-approved, `cat .env` would sail through without a human in the loop —
# and a secret printed into the conversation transcript stays there forever.
#
# Wiring (settings.json): PreToolUse, matcher "Bash|Read".
# Exit codes: 0 = pass through, 2 = block (stderr is shown to the model).

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0   # fail open without jq

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0

# Filename material that suggests secrets. Tuned to basenames/paths; the
# *.env.example family is explicitly NOT secret (it is documentation).
SECRET_RE='(\.env([^a-zA-Z0-9-]|$)|credential|secret|\.pem([^a-zA-Z0-9]|$)|\.key([^a-zA-Z0-9]|$)|id_rsa|id_ed25519|id_ecdsa|\.netrc|\.npmrc|\.pgpass|\.p12([^a-zA-Z0-9]|$)|\.pfx([^a-zA-Z0-9]|$)|\.keystore|\.jks([^a-zA-Z0-9]|$))'
EXAMPLE_RE='\.env\.(example|sample|template|dist)'

block() {
  echo "BLOCKED: whole-file read of a secret-bearing file ($1) would leak secrets into the conversation transcript permanently. Read only the field you need instead, e.g.: grep '<KEY_NAME>' <file>" >&2
  exit 2
}

if [ "$TOOL_NAME" = "Read" ]; then
  FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
  [ -n "$FILE_PATH" ] || exit 0
  STRIPPED=$(printf '%s' "$FILE_PATH" | sed -E "s/$EXAMPLE_RE//g")
  if printf '%s\n' "$STRIPPED" | grep -qiE "$SECRET_RE"; then
    block "$FILE_PATH"
  fi
  exit 0
fi

if [ "$TOOL_NAME" = "Bash" ]; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -n "$COMMAND" ] || exit 0
  # Only the whole-file dumpers; grep/awk of a single key stays allowed.
  STRIPPED=$(printf '%s' "$COMMAND" | sed -E "s/$EXAMPLE_RE//g")
  if printf '%s\n' "$STRIPPED" | grep -qiE "(^|[^a-zA-Z])(cat|head|tail|less|more|bat|nl|tac|strings|od|hexdump|xxd|base64)[[:space:]][^|&;]*$SECRET_RE"; then
    block "shell read"
  fi
  exit 0
fi

exit 0
