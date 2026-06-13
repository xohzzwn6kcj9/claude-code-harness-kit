# Global instructions (lean profile)

Minimal, generic global guidance — safe for any machine, no personal or production context.
Replace or extend to taste.

## Scratch files

- Put temporary / throwaway files under `~/tmp` (pre-authorize it in settings so it never prompts),
  not `/tmp`. The `temp-dir-guard` hook (if installed) enforces this.

## Bash command style

- Prefer the dedicated tools (`Read`/`Glob`/`Grep`) over `cat`/`find`/`grep` where possible.
- Avoid `xargs` and process substitution `<(...)` in one-liners — use a `for` loop / temp file.
- Don't use brace expansion `{a,b}` in tool commands — list paths explicitly.
- Use absolute paths for `cd` inside compound commands.
  (These mirror the `bash-guards/` hooks, which block the above with a corrective hint.)

## Secrets

- Never whole-file-read a `.env` / credential / key file — read only the field you need
  (`grep KEY file`). The `deny-secret-file-reads` hook enforces this.

## Token discipline (capped / Sonnet plans)

- Prefer `repo-radar` for git/branch/search questions — one call, no token-heavy shell loops.
- Avoid spawning multi-agent workflows / large fan-outs; prefer single-pass inline work.
