---
name: temp-file
description: Use when creating any temporary, scratch, intermediate, or throwaway file — build logs, debug dumps, generated test scripts, data snapshots, diff outputs, anything not meant to live in the repo. Routes the file to the pre-authorized ~/tmp directory instead of /tmp (which triggers permission prompts and is blocked by temp-dir-guard.sh).
---

# Temp file placement

All temporary / scratch / intermediate / throwaway files go under **`~/tmp/`**.

Never use `/tmp`, `/var/tmp`, `/private/tmp`, or `$TMPDIR` — those are outside the
authorized directories, so they trigger permission prompts, and `temp-dir-guard.sh`
blocks writes to them. Pre-authorize `~/tmp` in `settings.json` for
read / write / edit / **execute** so it never prompts.

## Rules

1. **Location**: put the file at `~/tmp/<name>`. The directory should already exist; if a
   subcommand ever needs it, `mkdir -p ~/tmp` is allowed and idempotent.
2. **Naming**: use a meaningful, collision-resistant name — `<context>-<purpose>`,
   e.g. `~/tmp/build-check.log`, `~/tmp/resp-snapshot.json`, `~/tmp/repro-bug.py`.
   Avoid bare names like `out.txt` that collide across tasks. Do not rely on
   random/timestamp suffixes for uniqueness — prefer descriptive names.
3. **Execution**: scripts in `~/tmp` can be run directly (`~/tmp/x.sh`,
   `bash ~/tmp/x.sh`, `python3 ~/tmp/x.py`) without a prompt.
4. **Cleanup**: optional — `~/tmp` is outside any repo, so there is no commit risk.
   Don't accumulate long-lived state there; it's scratch space, not storage.

## If a write to /tmp gets blocked

`temp-dir-guard.sh` returned exit 2. Don't retry the same path — rewrite the
destination from `/tmp/...` to `~/tmp/...` and run again. Reading from `/tmp`
(e.g. inspecting an artifact another tool left there) is allowed and not blocked.
