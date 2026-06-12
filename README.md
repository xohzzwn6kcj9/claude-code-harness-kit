# claude-code-harness-kit

A small kit of [Claude Code](https://code.claude.com) hooks plus one read-only repo-analysis
skill. The theme is **less prompt friction, no less safety**: auto-approve the things that are
provably read-only, hard-block the things that leak secrets or corrupt state, and stay out of the
way otherwise.

Everything is opt-in and à-la-carte — install the pieces you want, skip the rest.

## What's in it

| Component | Type | What it does |
|-----------|------|--------------|
| [`hooks/auto-approve-readonly.sh`](hooks/auto-approve-readonly.sh) | PreToolUse | Approves read-only tools + read-only MCP tools + Bash command lines whose **every** segment is read-only. Everything else defers to the normal flow. **Never blocks.** |
| [`hooks/deny-secret-file-reads.sh`](hooks/deny-secret-file-reads.sh) | PreToolUse | Hard-blocks whole-file reads of `.env`/credential/key files (Bash + Read), steering to `grep KEY file`. |
| [`hooks/secret-scan.sh`](hooks/secret-scan.sh) | git pre-push | Deterministic secret scan of the pushed commit range (gitleaks if present, else curated regexes). Fires even on a manual `git push`. |
| [`hooks/playwright-screenshot-guard.sh`](hooks/playwright-screenshot-guard.sh) | PreToolUse | Keeps Playwright MCP screenshots out of the repo root (relative filenames leak untracked PNGs). |
| [`hooks/bash-guards/`](hooks/bash-guards) | PreToolUse | **Opinionated** quality-of-life guards (see below). Each is independent; install only what you like. |
| [`skills/repo-radar/`](skills/repo-radar) | skill | Read-only git/branch/merge/PR/search analysis run through Python (no shell), so it dodges zsh word-splitting, glob traps, and chained-command prompts. |

Two design rules run through all of it:

1. **When in doubt, defer.** A false negative costs one permission prompt; a false positive
   silently runs something with side effects. The Bash analysis is deliberately conservative.
2. **A hook `allow` never overrides a settings `deny` rule.** In Claude Code, deny rules are
   evaluated regardless of what a PreToolUse hook returns, and any hook that exits 2 blocks the
   call. Keep a `permissions.deny` baseline (see `settings.example.json`) as the real backstop.

## Quick start

```
git clone https://github.com/xohzzwn6kcj9/claude-code-harness-kit.git
cd claude-code-harness-kit
bash tests/run.sh && bash tests/guards.test.sh   # optional self-test, expect "fail: 0"

./install.sh            # core hooks only
./install.sh --all      # core hooks + bash-guards + repo-radar skill
./install.sh --guards   # core + opinionated bash-guards
./install.sh --radar    # core + repo-radar skill
```

Then merge the hook wiring into `~/.claude/settings.json` — see
[`settings.example.json`](settings.example.json) for a full example. Restart the session (or run
`/hooks`), then try `git status`: no prompt.

**Requirements**: `jq` and `perl` for the read-only hook; `python3` for the screenshot/grep/brace
guards; `git` (and optionally `gitleaks`) for the secret scanner. Stock macOS has all of these;
most Linux distros do too. The hooks **fail open** — if a dependency is missing they approve
nothing and block nothing, so you just get normal prompts. Use a recent Claude Code version (the
hooks emit the current `hookSpecificOutput.permissionDecision` format).

---

## Core hooks

### auto-approve-readonly.sh

Approves a tool call only when it is provably read-only; otherwise emits nothing and lets the
normal permission flow (your allow/deny rules, then a prompt) decide.

**Tools approved directly:** `Read` (except secret-looking files, which defer), `Glob`, `Grep`,
`NotebookRead`, `WebFetch`, `WebSearch`. MCP tools are matched on the trailing tool name so both
`mcp__<server>__*` and plugin-style `mcp__plugin_<plugin>_<server>__*` work — Playwright
**observation** tools (`browser_snapshot`, `browser_console_messages`, `browser_navigate`, …; the
interaction tools click/type/evaluate deliberately still prompt) and Serena code-navigation tools.

> `WebFetch`/`WebSearch`/`browser_navigate` are read-only *locally* but do send a request (and its
> URL) to an external server. Remove those lines in the hook if that matters to your threat model.

**Bash:** a command line is approved only if **every** command in it — pipe segments, `&&`/`||`/
`;`/`&` members, loop bodies, `v=$(...)` substitution bodies — is on the read-only list **and**
passes per-command flag vetting:

```
cat ls fd find grep rg head tail wc tree pwd echo which file stat du df uname sw_vers whoami id
groups date env printenv ps sort uniq nl tac rev strings cmp diff comm tr cut column fold jq yq
realpath readlink dirname basename hostname uptime printf type test true false less more od
hexdump cksum shasum sha256sum md5 md5sum locale getconf cd git gh gradlew docker kubectl
```

A safe *name* is not a safe *command*, so these are additionally flag-vetted:

| Command | Approved | Refused (deferred) |
|---------|----------|--------------------|
| `git` | `status log diff show blame rev-parse ls-files ls-tree ls-remote cat-file merge-base rev-list shortlog grep reflog[ show] …`; `branch`/`tag`/`remote` with flags only; `stash list`, `worktree list`, `config --get/--list` | `push commit checkout rebase merge fetch reset`, `branch <name>`, `tag <name>`, `remote add`, `reflog expire`, `stash pop`, `config <set>` |
| `gh` | `pr/issue/run/repo/release/workflow/gist/label/cache/ruleset` × `list/view/status/diff/checks`; `auth status`, `status`, `search …` | `pr merge`, `repo delete`, `pr create`, **`api`** (can POST), everything else |
| `find` | tests/prints; `-exec`/`-execdir` only onto a read-only allowlist | `-delete`, `-fprintf`/`-fprint`/`-fls`, `-ok`, `-exec rm/sh/…` |
| `sort` | normal sorting | `-o`/`--output` |
| `uniq` | flag-only (stdin) | any file operand (2nd operand = output file) |
| `env` | bare / flags / `VAR=val` only | `env <command>` (runs it — classic bypass) |
| `date` | formatting | `-s`/`--set` |
| `tree` | listing | `-o` |
| `docker` | `ps images inspect logs version info stats top port diff context ls/inspect` | `run rm exec build push …` |
| `kubectl` | `get describe logs explain version top api-resources diff` | `apply delete edit scale …` |
| `gradlew` | `tasks projects properties dependencies help --version` | `build test publish …` |

Structural rules enforced before any name is considered:

- **Redirects**: `2>&1`, `>&2`, `>/dev/null`, `2>/dev/null` are fine; any other `>`/`>>` defers.
  `< file` input is fine (and stops at separators, so `< f;rm x` can't smuggle a command).
- **Command substitution**: only `v=$(...)` is approvable, and its body is vetted as a segment.
  `$(…)` anywhere else (as a command name, or smuggling flags like `sort $(echo -o evil)`) defers.
  `"$(…)"` inside double quotes defers. **Backticks** anywhere defer.
- **Heredocs** (`<<`) and **process substitution** (`<(`/`>(`) defer.
- `&` (background) and newlines are separators; shell keywords are peeled so `do rm $f` in a loop
  body is still seen as `rm`. Quoted strings are treated as inert data.

**Deliberately *not* in the default list:** `sed`/`awk`/`perl`/`python3`/`node` (program text in
quotes can write files or `system()`), `curl`/`wget` (POST, `-o`), `tee`/`xargs`/`eval`/`exec`/
`sudo`, `xxd`/`base64` (write via `-o`/2nd arg). Extend the lists via environment without editing
the file:

```jsonc
// in the settings.json hook entry:
"command": "AAR_SAFE_CMDS=\"$AAR_SAFE_CMDS pytest\" ~/.claude/hooks/auto-approve-readonly.sh"
```

(`AAR_SAFE_CMDS`, `AAR_FIND_EXEC_SAFE`, `AAR_GIT_SUBCMDS` — space-separated; simplest is editing
the defaults at the top of the script.)

### deny-secret-file-reads.sh

Pairs with broad read-approval: once `cat` is auto-approved, `cat .env` would sail through, and a
secret printed into the transcript stays there permanently. This hook hard-blocks (exit 2, with a
corrective hint) any whole-file dump (`cat`/`head`/`tail`/`less`/`bat`/`strings`/`od`/`xxd`/
`base64`/… or the `Read` tool) of paths matching `.env`, `*credential*`, `*secret*`, `*.pem`,
`*.key`, `id_rsa*`, `.netrc`, `.npmrc`, `.pgpass`, keystores, etc. `.env.example`/`.sample`/
`.template` are exempt. Targeted reads (`grep API_KEY .env`) stay allowed, so the model
self-corrects in one step.

### secret-scan.sh (git pre-push)

A deterministic backstop that scans the **added lines** of the pushed range and blocks the push on
a hit. Uses `gitleaks` when installed (authoritative), otherwise a self-contained set of curated
regexes + sensitive-filename checks, with an allowlist for obvious placeholders (`EXAMPLE`,
`dummy`, `<...>`, …). It fires on every push, including a manual `git push` outside any Claude
session. Wire it per-repo:

```
cp hooks/githooks/pre-push <repo>/.git/hooks/pre-push && chmod +x <repo>/.git/hooks/pre-push
# or, for a tracked hooks dir:
git config core.hooksPath hooks/githooks
```

Add your own provider/broker key patterns to the `rules` array near the top of the script. Bypass
once (when you're sure) with `git push --no-verify`.

### playwright-screenshot-guard.sh

The Playwright MCP saves auto-named screenshots into the git-ignored `.playwright-mcp/` dir — but a
**relative** `filename` resolves against the repo root and leaves an untracked PNG there. This
guard denies that one case (with a fix hint) and passes everything else: no filename, a
`.playwright-mcp/...` path, or any absolute path. Wire it on the
`mcp__.*playwright.*__browser_take_screenshot` matcher.

---

## Opinionated bash guards (`hooks/bash-guards/`)

These encode a specific style of working (a git-worktree workflow, prompt-free unattended `/loop`
runs, steering toward the `Grep`/`Read` tools). They're genuinely useful if you share those
habits and just noise if you don't — so they live apart from the core hooks and you install only
the ones you want. Each exits 2 to block with a self-correcting message (or emits a deny/nudge
JSON), and each **fails open** on any parse error.

| Guard | Blocks | Why |
|-------|--------|-----|
| `git-branch-switch-guard.sh` | `git checkout/switch <existing-branch>` in the **main** worktree | If you pin the main worktree to main and do feature work in `git worktree add` checkouts, a stray switch disrupts other sessions. Allows `-b`/`--create`, `main`/`master`, and anything inside a `.worktree/` cwd. |
| `xargs-procsub-guard.sh` | `xargs`, process substitution `<(...)` | Easy to misuse in generated one-liners; nudges to a `for` loop / `git diff` / temp file. Ignores quoted occurrences. |
| `brace-expansion-guard.sh` | unquoted brace expansion `{a,b}` / `{1..n}` | The permission matcher can't statically resolve it, so no allow rule auto-approves and an unattended loop stalls on a prompt. Quoted braces / heredoc bodies are fine. |
| `grep-tool-guard.sh` | unquoted `grep --include=*glob` (deny); ad-hoc `grep -r`/`find -name` (nudge) | `grep --include=*.py` aborts under zsh (glob nomatch). Steers to the `Grep` tool / repo-radar. |
| `compound-cd-guard.sh` | relative `cd` inside a compound command (`cd src && …`) | A relative `cd` in a chain isn't statically resolvable (won't auto-approve), and a half-run `cd <rel> && git merge` can corrupt the main worktree. Allows absolute/`~`/`$VAR`, and a bare single `cd`. |
| `temp-dir-guard.sh` | writes into `/tmp` / `/var/tmp` / `$TMPDIR` | Enforces a `~/tmp` scratch convention. Reads from `/tmp` still pass. Pure opt-in — skip it if you don't use that convention. |

---

## repo-radar (skill)

A read-only Python toolkit for the repo questions you'd otherwise answer with fragile shell:
branch divergence / fast-forward feasibility, which PR merged where, worktree cleanup candidates,
predicted merge conflicts (formatting-only vs logical), code/log search, and ref/file comparison.
Every question is **one non-shell call** — `git`/`gh`/`grep`/`diff` run via Python `subprocess`
argv lists, so a pattern containing `*.py`, `xargs`, `<(`, backticks, or newlines is just a string
and never trips zsh or a hook.

```
python3 ~/.claude/skills/repo-radar/scripts/radar.py git overview
python3 ~/.claude/skills/repo-radar/scripts/radar.py git diverge main feature-x --json
python3 ~/.claude/skills/repo-radar/scripts/radar.py search code "TODO" --ext py
```

See [`skills/repo-radar/SKILL.md`](skills/repo-radar/SKILL.md) for the full command list. It's a
standard Claude Code skill — install it under `~/.claude/skills/` (via `./install.sh --radar`) and
Claude will discover it.

---

## How hook auto-approval works (the facts)

- **Output format**: a PreToolUse hook approves by printing
  `{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow",...}}` and
  exiting 0. `"deny"` blocks; omitting the JSON (exit 0) is "no opinion". Exit 2 hard-blocks with
  stderr fed back to the model. (The legacy `{"decision":"approve"}` shape is deprecated.)
- **Precedence**: across multiple hooks, an exit-2 block wins. A hook `"allow"` only *skips the
  prompt* — it does **not** bypass a settings `deny` (or `ask`) rule. So your deny list is always
  the hard floor.
- **Matchers**: `.*` (or omitted) matches every tool incl. MCP; pipe-lists like `Bash|Read`;
  regex for the rest (`mcp__.*playwright.*__...`).

## Threat model & limitations

This is a **convenience layer with a security-conscious default**, not a sandbox.

- The Bash vetting is textual analysis of a hostile grammar. It's deliberately conservative
  (unknown constructs defer), and the test suite encodes the bypass classes found while hardening
  it — `$()` in command/argument position, single-`&` backgrounding, keyword-shadowed loop bodies,
  redirect writes, flag smuggling, `env <cmd>`, and a real separator-swallow bug in the
  input-redirect handling (`< f;rm x`) that was caught by red-teaming and fixed. Treat the hook as
  one layer; keep `permissions.deny` as the backstop.
- Approved read commands can still read any file your user can — that's what you're opting into.
  The secret guards narrow the worst case but are pattern-based (they won't catch a secret in
  `notes.txt`).
- `WebFetch`/`browser_navigate` issue real network requests. Remove them if exfiltration-via-URL
  is in scope.
- The bash-guards are workflow opinions, not security boundaries.

If you find a bypass, please open an issue with a failing test case (`tests/run.sh` /
`tests/guards.test.sh` show the format).

## Testing

```
bash tests/run.sh          # read-only hook + secret-read guard (150+ cases)
bash tests/guards.test.sh  # the standalone guards (block/pass per guard)
```

Both run on stock macOS `/bin/bash` 3.2 and modern Linux bash. Require `jq` (+ `python3` for the
guard suite).

## License

MIT
