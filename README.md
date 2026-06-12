# claude-code-readonly-autoapprove

Auto-approve **provably read-only** tool calls in [Claude Code](https://code.claude.com) so they
never stop you with a permission prompt — without widening what can actually *write* or *execute*.

Two PreToolUse hooks:

| Hook | What it does |
|------|--------------|
| [`hooks/auto-approve-readonly.sh`](hooks/auto-approve-readonly.sh) | Approves read-only tools (`Read`/`Glob`/`Grep`/…), read-only MCP tools, and Bash commands whose **every** segment is read-only. Everything else falls through to the normal permission flow. **Never blocks anything.** |
| [`hooks/deny-secret-file-reads.sh`](hooks/deny-secret-file-reads.sh) | Companion guard: hard-blocks whole-file reads of `.env` / credential / private-key files, steering the model to `grep KEY file` instead. Once `cat` is auto-approved you want this. |

The design rule throughout: **when in doubt, defer.** A false negative costs you one permission
prompt; a false positive silently runs something with side effects. Deferred calls are *not*
blocked — they just go through the normal allow/deny/prompt flow.

## Quick start

```
git clone https://github.com/xohzzwn6kcj9/claude-code-readonly-autoapprove.git
cd claude-code-readonly-autoapprove
bash tests/run.sh     # optional: 150+ case self-test, should print "fail: 0"
./install.sh          # copies the hooks into ~/.claude/hooks/
```

Then merge the hook wiring into your `~/.claude/settings.json` (the installer prints it, and
[`settings.example.json`](settings.example.json) has a full example including a recommended
`permissions.deny` baseline):

```json
"hooks": {
  "PreToolUse": [
    { "matcher": "Bash|Read", "hooks": [{ "type": "command", "command": "~/.claude/hooks/deny-secret-file-reads.sh" }] },
    { "matcher": ".*",        "hooks": [{ "type": "command", "command": "~/.claude/hooks/auto-approve-readonly.sh" }] }
  ]
}
```

Restart the session (or check `/hooks`), then try `git status` — no prompt.

**Requirements**: `jq` and `perl` on PATH (stock macOS has both; most Linux distros too), bash 3.2+.
If either is missing the hooks **fail open**: nothing is approved, nothing is blocked, you just get
the normal prompts. Use a recent Claude Code version (the hook emits the current
`hookSpecificOutput.permissionDecision` output format).

## What gets auto-approved

### Tools

- `Read` (except secret-looking files — those defer to the normal prompt), `Glob`, `Grep`, `NotebookRead`
- `WebFetch`, `WebSearch` — read-only from your machine's point of view; note the URL itself is sent
  to an external server. Delete those two lines in the hook if that matters for your threat model.
- MCP, matched on the trailing tool name so both `mcp__<server>__*` and plugin-style
  `mcp__plugin_<plugin>_<server>__*` names work:
  - Playwright **observation** tools (`browser_snapshot`, `browser_console_messages`,
    `browser_network_requests`, `browser_tabs`, `browser_take_screenshot`, `browser_navigate`,
    `browser_navigate_back`, `browser_wait_for`, `browser_resize`, `browser_close`).
    Interaction tools (click/type/evaluate/…) deliberately still prompt — a click can submit a form.
  - Serena code-navigation tools (`find_symbol`, `search_for_pattern`, `list_dir`, …)

### Bash commands

A command line is approved only if **every** command in it — pipe segments, `&&`/`||`/`;`/`&`
members, loop bodies, `v=$(...)` substitution bodies — is on the read-only list **and** passes
per-command flag vetting:

```
cat ls fd find grep rg head tail wc tree pwd echo which file stat du df uname sw_vers
whoami id groups date env printenv ps sort uniq nl tac rev strings cmp diff comm tr cut
column fold jq yq realpath readlink dirname basename hostname uptime printf type test
true false less more od hexdump cksum shasum sha256sum md5 md5sum locale getconf cd
git gh gradlew docker kubectl
```

Per-command vetting on top of the name check (a safe *name* is not a safe *command*):

| Command | Approved forms | Refused (deferred) forms |
|---------|----------------|--------------------------|
| `git` | `status log diff show blame rev-parse describe ls-files ls-tree ls-remote cat-file merge-base rev-list shortlog grep reflog[ show] …`; `branch`/`tag`/`remote` with flags only; `stash list`, `worktree list`, `config --get/--list` | `push commit checkout rebase merge fetch reset`, `branch <name>`, `tag <name>`, `remote add`, `reflog expire`, `stash pop`, `config <set>` |
| `gh` | `pr/issue/run/repo/release/workflow/gist/label/cache/ruleset` × `list/view/status/diff/checks`; `auth status`, `status`, `search …` | `pr merge`, `repo delete`, `pr create`, **`api`** (can POST), everything else |
| `find` | tests/prints; `-exec`/`-execdir` only onto a read-only allowlist (`grep cat head wc stat …`) | `-delete`, `-fprintf`/`-fprint`/`-fls`, `-ok`, `-exec rm/sh/…` |
| `sort` | normal sorting | `-o`/`--output` (writes a file) |
| `uniq` | flag-only (stdin) | any file operand (2nd operand is an output file) |
| `env` | bare / flags / `VAR=val` only | `env <command>` (runs the command — classic bypass) |
| `date` | formatting | `-s`/`--set` |
| `tree` | listing | `-o` (writes a file) |
| `docker` | `ps images inspect logs version info stats top port diff context ls/inspect` | `run rm exec build push …` |
| `kubectl` | `get describe logs explain version top api-resources diff` | `apply delete edit scale …` |
| `gradlew` | `tasks projects properties dependencies help --version` | `build test publish …` |

Structural rules enforced before any name is even considered:

- **Redirects**: `2>&1`, `>&2`, `>/dev/null`, `2>/dev/null` are fine; any other `>`/`>>` can write
  a file → defer. (`< file` input is fine.)
- **Command substitution**: only the assignment form `v=$(...)` is approvable, and its *body* is
  vetted like any other segment. `$(…)` anywhere else can become a command name
  (`$(echo rm) -rf x`) or smuggle flags into a safe command (`sort $(echo -o evil)`) → defer.
  Inside double quotes (`"$(…)"`) → defer.
- **Backticks** anywhere → defer. **Heredocs** (`<<`) and **process substitution** (`<(`/`>(`) → defer.
- Single `&` (background) and newlines count as separators, so nothing hides behind them.
- Shell keywords are peeled (`if`/`then`/`do`/…), so `do rm $f` inside a loop is seen as `rm`.
- Quoted strings are treated as inert data (single-quoted always; double-quoted after the checks above).

### Deliberately NOT in the default list

| Excluded | Why |
|----------|-----|
| `sed`, `awk`, `perl`, `python3`, `node`, … | Program text rides in quotes, which the checker treats as data — but `sed 's/x/y/w f'`, `awk '{print > "f"}'`, `awk 'BEGIN{system("…")}'` write files / run commands. If you add `sed` back, the hook still refuses `-i`. |
| `curl`, `wget` | Can POST and write files (`-o`, `-O`). |
| `tee`, `xargs`, `eval`, `exec`, `sudo` | Obvious escapes. |
| `xxd`, `base64` | Write files via `-o` / a second positional argument. |

Extend via environment or by editing the variables at the top of the hook:

```bash
# e.g. in the settings.json hook entry:
"command": "AAR_SAFE_CMDS=\"$AAR_SAFE_CMDS pytest\" ~/.claude/hooks/auto-approve-readonly.sh"
```

(`AAR_SAFE_CMDS`, `AAR_FIND_EXEC_SAFE`, `AAR_GIT_SUBCMDS` — space-separated, replace the default
when set. Simplest is editing the defaults in the file.)

## The secret-read guard

`deny-secret-file-reads.sh` (matcher `Bash|Read`) blocks — exit 2, with a corrective hint — any
whole-file dump (`cat`/`head`/`tail`/`less`/`bat`/`strings`/`od`/`xxd`/`base64`/… or the `Read`
tool) of paths matching `.env`, `*credential*`, `*secret*`, `*.pem`, `*.key`, `id_rsa*`, `.netrc`,
`.npmrc`, `.pgpass`, keystores, etc. `.env.example`/`.env.sample`/`.env.template` are exempt.
Targeted reads stay allowed: `grep API_KEY .env` passes, so the model can self-correct in one step.

Rationale: a secret printed into the conversation transcript stays there permanently (and may leave
your machine). The two hooks are designed as a pair — broad read approval is only safe with this
backstop. The main hook also independently *defers* (not blocks) `Read` on secret-looking files,
so it stays safe even if you install it alone.

## Threat model & honest limitations

This is a **convenience layer with a security-conscious default**, not a sandbox:

- The Bash vetting is textual analysis of shell syntax. It is deliberately conservative (unknown
  constructs defer), and the test suite includes the bypass classes we found and fixed while
  hardening it (`$()` in command/argument position, single-`&` backgrounding, keyword-shadowed loop
  bodies, redirect writes, flag smuggling, `env <cmd>`). But shell is a hostile grammar; treat the
  hook as one layer and keep `permissions.deny` rules (see `settings.example.json`) as the backstop.
  An auto-approve hook **cannot** override your deny rules — deny always wins in Claude Code.
- Approved read commands can still read any file your user can (that is what you are opting into).
  The secret guard narrows the worst case; it is pattern-based and will not catch a secret in
  `notes.txt`.
- `WebFetch`/`browser_navigate` perform GET requests: read-only locally, but requests reach external
  servers. Remove them from the hook if your threat model includes data exfiltration via URLs.
- Anything here can be bypassed by *you* approving a prompt — the hooks only change *defaults*,
  which is the point.

## Testing

```
bash tests/run.sh
```

150+ cases: approve set, defer set (including the attack strings above), tool-level matrix,
secret-guard block/pass, and output-format validation. Please add a failing case first if you
report a bypass.

## License

MIT
