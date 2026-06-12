---
name: repo-radar
description: >-
  Read-only repo/branch/search/diff analysis toolkit. Answers git branch & merge questions
  (divergence, fast-forward feasibility, which PR merged where, worktree cleanup candidates,
  predict+classify merge conflicts), robust code/log search, and file/ref comparison —
  WITHOUT hand-rolled shell. Use this instead of ad-hoc grep/git/gh/diff pipelines whenever
  you need to INSPECT (not change) repo state: "are X and Y diverged / can it fast-forward",
  "which branches/PRs are merged into main vs release", "which worktrees can I clean up",
  "will merging X into Y conflict and are the conflicts formatting-only or logical", "find all
  call sites of Z", "is this diff pure reformatting", "compare a file across two refs". Runs
  git/gh/grep/diff inside Python (no shell), so it never trips zsh word-splitting, the
  --include=*.kt glob trap, parse errors, the xargs/process-substitution hooks, or
  chained-command permission prompts. Read-only: it never commits, merges, pushes, or posts.
---

# repo-radar

A read-only Python query toolkit. Every question is **one non-shell call** that returns a
structured report — replacing fragile ad-hoc shell pipelines.

## Invocation contract (important)

Run exactly one command, no chaining:

```
python3 ~/.claude/skills/repo-radar/scripts/radar.py <group> <subcmd> [args] [--json]
```

- **Do NOT** wrap it in `&&` / `|` / `;` or add `echo` labels — that re-triggers permission
  prompts and defeats the purpose. One query = one call.
- Add `--json` for machine-readable output you can reason over; omit it for a human summary.
- To run it prompt-free, add an allow rule scoped to the script path, e.g.
  `Bash(python3 ~/.claude/skills/repo-radar/scripts/radar.py:*)`, in your settings.
- Underlying `git`/`gh`/`grep`/`diff` run via Python `subprocess` argv lists (never a shell),
  so a pattern containing `xargs`, `<(`, `*.kt`, backticks, or newlines is just a string — it
  cannot trip a hook or zsh.
- Run from inside the target repo (or pass `--repo-dir DIR`). Read-only — to actually merge /
  clean up / push, use git directly after reading the report.

## Commands

| Group | Subcommand | Answers |
|-------|-----------|---------|
| `git` | `overview [--targets main,release]` | full snapshot: branches+SHAs, worktrees, ahead/behind vs targets, merged-status |
| `git` | `diverge <refA> <refB>` | merge-base, ahead/behind, `ff_possible`, commits unique to each side |
| `git` | `prmap [--repo R]` | PR→base map: which PRs merged to main vs release; open PRs + mergeable |
| `git` | `worktrees` | worktrees + tracked-branch merged-status → cleanup candidates / stale |
| `git` | `mergecheck <src> <into>` | predict merge (no tree touch): ff?, conflicted files, per-file formatting-vs-logic |
| `git` | `conflicts` | post-merge working-tree check: leftover conflict markers (`git diff --check`, incl. staged) + unmerged paths. `clean` bool — no `=======` grep false positives |
| `search` | `code <pattern> [--ext kt,py] [--path G] [--exclude G] [--files-only] [--count] [-i]` | grep/ripgrep via argv — no glob trap |
| `search` | `log <pattern> --file <path\|glob> [--context N] [--strip-ansi] [--mask RE] [--jsonl-field P]` | local log/JSONL triage with secret-masking |
| `compare` | `refs <ref> [<ref2>] [--stat] [--name-only] [--path P]` | diff/divergence between refs |
| `compare` | `file <fileA> <fileB> [--quiet]` | cross-file/host equality |
| `compare` | `blob <path> <refX> <refY>` | same file across two refs |
| `compare` | `classify <ref\|patchfile> [--path P]` | per-file verdict `formatting_only` vs `logical` (advisory) |
| `pr` | `status [N ...] [--repo R]` | state, mergeable, mergeStateStatus, headRefOid, base |
| `pr` | `list-open [--repo R]` | open PRs as a real list (iterate in Python, never `for x in $(…)`) |
| `pr` | `comments <N> [--since SHA\|TIME]` | new-comment detection without word-split |

Global flags: `--repo-dir DIR` (default: cwd), `--json`.

## When to reach for it

- Start of any branch/merge reconciliation → `git overview`.
- Before claiming a fast-forward or planning a merge → `git diverge` / `git mergecheck`.
- After resolving/finalizing a merge, before committing → `git conflicts` (catches markers left
  in already-staged files — the case a worktree-only grep misses).
- "which PR went where" / worktree cleanup → `git prmap` / `git worktrees`.
- Any code search you'd otherwise `grep -rn … --include=…` → `search code`.
- Proving a lint/format-only diff before merging → `compare classify`.
- PR-watch polling → `pr list-open` / `pr status` / `pr comments` (no zsh word-split).

## Boundaries

- **Read-only.** No mutation. Acting on the report is the caller's job (use git directly).
- Transcript/session search is out of scope. `search log` is a generic local log/JSONL triage
  helper (with optional secret-masking), not a service-specific log reader.
- `classify` is heuristic/advisory (Kotlin/Python aware first) — see
  [references/classify-heuristics.md](references/classify-heuristics.md).
