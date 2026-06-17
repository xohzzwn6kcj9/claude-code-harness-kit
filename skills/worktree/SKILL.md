---
name: worktree
description: Git worktree workflow automation for feature-branch isolation. Use when starting feature work, syncing a feature with its base branch, pushing / opening a PR, or cleaning up worktrees. Triggers on feature development, branch creation, or worktree management.
---

# Git Worktree Workflow

Automates the git worktree lifecycle: **create → work (+ sync) → push / pr → cleanup**. Each
feature lives in its own worktree under `.worktree/<feature>/`, so the main checkout stays on the
base branch and feature work never collides.

## Script

```
~/.claude/skills/worktree/scripts/worktree.sh <create|sync|push|pr|cleanup> <feature> [--tail N|--head N]
```

### Limiting output — use the flags, NEVER a pipe

To shorten output, append `--tail N` (alias `--lines N`) or `--head N` to any subcommand — do
**not** pipe through `| head`/`| tail`. The flags are handled inside the script; a pipe in the
tool call can break skill-script auto-approval (an allow-rule's `*` cannot span a `|`).

```bash
bash ~/.claude/skills/worktree/scripts/worktree.sh pr myfeature --tail 30
```

## Branch model

- **base** — the branch worktrees fork from and sync against. Resolved (first match wins):
  1. `base=` in the repo-root **`.worktreeconfig`**
  2. the repo's default branch (`origin/HEAD`, else local `main`/`master`)
  3. `main`
- **target** — the PR/merge destination, used **only by `pr`**. Defaults to `base`; override with
  `target=` in `.worktreeconfig` (e.g. a repo that develops on `main` but PRs to `release`).

`create` / `sync` / `push` / `cleanup` need only the base. The merge target is the project's
choice and matters only when this skill opens the PR for you.

### `.worktreeconfig` (repo root, optional)

```
base=main          # fork/sync source        (default: repo default branch → main)
target=main        # PR destination for `pr`  (default: base)
test_cmd=...        # full-test command        (default: auto-detected; env WORKTREE_TEST_CMD wins)
```

All keys are optional — with no file, everything falls back to the defaults. The file is **parsed**
as `key=value`, never `source`d (a repo file must not run as shell).

## Workflow

1. **Create** (from the main worktree, on the base branch):
   ```bash
   bash ~/.claude/skills/worktree/scripts/worktree.sh create <feature>
   ```
   Creates branch `<feature>` from the base, the worktree at `.worktree/<feature>`, and ensures
   `.worktree/` is git-ignored.

2. **Work** inside `.worktree/<feature>/` — commit in logical units, tests alongside code.

3. **Sync** — merge the latest base into the feature mid-work so conflicts resolve incrementally:
   ```bash
   bash ~/.claude/skills/worktree/scripts/worktree.sh sync <feature>
   ```
   Uses `origin/<base>` when a remote exists, else the local `<base>`. No-op if already current.
   On conflict it leaves the merge **in progress** (prints the files + `git merge --abort`) so you
   resolve in place; runnable from the main worktree or from inside the feature worktree.

4. **Push or PR** (from the main worktree):
   - `push <feature>` — merge base in → run the test gate → push the branch. No PR. Use this when
     PR creation is handled elsewhere (a reviewer bot, or you open it manually).
   - `pr <feature>` — same, then open a GitHub PR `<feature> → <target>` (only when `gh` is
     installed and the remote is GitHub; otherwise it pushes and tells you to open the PR/MR).

   **Pre-push test gate:** before pushing, the full test suite runs and **aborts the push on
   failure**. Command resolution: `WORKTREE_TEST_CMD` env → `.worktreeconfig test_cmd` →
   auto-detected from build markers:

   | Marker | Command |
   |--------|---------|
   | `gradlew` | `./gradlew check` |
   | `pom.xml` (+ `mvnw`) | `./mvnw test` / `mvn test` |
   | `Cargo.toml` | `cargo test` |
   | `go.mod` | `go test ./...` |
   | `package.json` w/ `test` script | `pnpm`/`yarn`/`npm test` (by lockfile) |
   | `pyproject.toml`/`pytest.ini`/`setup.cfg`/`tox.ini` | `pytest` |
   | `Makefile` w/ `test:` | `make test` |

   No build system detected → push is **aborted** (set `test_cmd`/`WORKTREE_TEST_CMD`, or bypass
   consciously with `WORKTREE_SKIP_TESTS=1`).

   **No remote?** `push`/`pr` skip the push and print local-merge guidance
   (`git switch <target> && git merge <feature>`) — the worktree + test gate still ran.

5. **Cleanup** (from the main worktree, on the base branch):
   ```bash
   bash ~/.claude/skills/worktree/scripts/worktree.sh cleanup <feature>
   ```
   Idempotent / skip-if-gone (no error if already removed); always prunes stale metadata. The
   branch is **preserved**. Always use this rather than a raw `git worktree remove` (which exits
   128 on an already-removed path).

## Rules

- Never `git checkout`/`switch` a feature branch in the main worktree — it must stay on the base.
- Never delete branches — they are preserved.
- Run `cleanup` from the main worktree, never from inside `.worktree/`.
