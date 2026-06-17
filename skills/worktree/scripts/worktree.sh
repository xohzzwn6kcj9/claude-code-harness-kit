#!/usr/bin/env bash
set -euo pipefail

# Git Worktree Workflow Helper
# Usage: worktree.sh <create|sync|push|pr|cleanup> <feature-name> [--tail N|--head N|--lines N]
#
# Lifecycle:  create → work (+ sync) → push or pr → cleanup
#
# Branch model
#   base   = the branch worktrees fork from and sync against. Resolved (first match wins):
#              1) `base=` in the repo-root .worktreeconfig
#              2) the repo default branch (origin/HEAD, else local main/master)
#              3) main
#   target = the PR/merge destination, used ONLY by `pr`. Default = base; override with
#            `target=` in .worktreeconfig (e.g. a repo that develops on main but PRs to release).
#   create/sync/push/cleanup need only `base`; the merge target is the project's choice and
#   matters only when this skill opens the PR for you.
#
# .worktreeconfig (repo root, all keys optional — no file ⇒ sensible defaults):
#   base=main          # fork/sync source
#   target=main        # PR destination for `pr` (default = base)
#   test_cmd=...        # full-test command (overrides auto-detect; env WORKTREE_TEST_CMD wins over this)
# It is PARSED as key=value, never `source`d (a repo file must not run as shell).
#
# Degrades by environment:
#   - no remote        → `sync` merges the LOCAL base; `push`/`pr` skip the push and print
#                        local-merge guidance (the worktree + test gate still run).
#   - non-GitHub / no gh → `pr` pushes, then tells you to open the PR/MR yourself.
#
# Output-limiting flags (--tail/--head/--lines N) are INTERNALIZED so callers never need a
# `... | head/tail` pipe (a pipe in the tool call can break skill-script auto-approval). Use the flag.

WORKTREE_DIR=".worktree"
CONFIG_FILE=".worktreeconfig"

# ----------------------------------------------------------------- config / branches

# Read one key from .worktreeconfig in the repo root. Parsed (key=value), NOT sourced.
wt_config() {
    local key="$1" root
    root="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
    [ -f "${root}/${CONFIG_FILE}" ] || return 0
    sed -nE "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*(.*)$/\1/p" "${root}/${CONFIG_FILE}" \
        | sed -E 's/[[:space:]]+#.*$//; s/^"(.*)"$/\1/; s/^'\''(.*)'\''$/\1/; s/[[:space:]]*$//' \
        | head -n1
}

has_origin() { git remote get-url origin >/dev/null 2>&1; }
remote_is_github() { git remote get-url origin 2>/dev/null | grep -qiE 'github\.com'; }

# The repo's default branch: origin/HEAD if known, else local main/master, else main.
default_branch() {
    local d
    d="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's#^origin/##')"
    [ -n "$d" ] && { echo "$d"; return 0; }
    git show-ref --verify --quiet refs/heads/main && { echo "main"; return 0; }
    git show-ref --verify --quiet refs/heads/master && { echo "master"; return 0; }
    echo "main"
}

resolve_base()   { local b; b="$(wt_config base)";   [ -n "$b" ] && echo "$b" || default_branch; }
resolve_target() { local t; t="$(wt_config target)"; [ -n "$t" ] && echo "$t" || resolve_base; }

# ----------------------------------------------------------------- helpers

ensure_gitignore() {
    if [ -f .gitignore ]; then
        grep -qx "${WORKTREE_DIR}/" .gitignore 2>/dev/null || {
            echo "${WORKTREE_DIR}/" >> .gitignore
            echo "[info] Added '${WORKTREE_DIR}/' to .gitignore"
        }
    else
        echo "${WORKTREE_DIR}/" > .gitignore
        echo "[info] Created .gitignore with '${WORKTREE_DIR}/' entry"
    fi
}

# Must be in the main worktree (not inside .worktree/) and on the base branch.
require_main_worktree() {
    case "$(pwd)" in
        *"/${WORKTREE_DIR}/"*) echo "[error] cwd is inside a worktree — cd to the main worktree first." >&2; exit 1 ;;
    esac
    local base cur
    base="$(resolve_base)"
    cur="$(git rev-parse --abbrev-ref HEAD)"
    if [ "$cur" != "$base" ]; then
        echo "[error] Run from the main worktree on the base branch '${base}' (current: '${cur}')." >&2
        exit 1
    fi
}

# Auto-detect the project's full-test command from build-system marker files. Prints the
# command, or nothing if unrecognized. Checked dir = "$1" (default cwd). Most explicit first.
detect_test_cmd() {
    local d="${1:-.}"
    if [ -x "${d}/gradlew" ]; then echo "./gradlew check"; return 0; fi
    if [ -f "${d}/pom.xml" ]; then [ -x "${d}/mvnw" ] && echo "./mvnw test" || echo "mvn test"; return 0; fi
    if [ -f "${d}/Cargo.toml" ]; then echo "cargo test"; return 0; fi
    if [ -f "${d}/go.mod" ]; then echo "go test ./..."; return 0; fi
    if [ -f "${d}/package.json" ] && grep -q '"test"[[:space:]]*:' "${d}/package.json" 2>/dev/null; then
        if   [ -f "${d}/pnpm-lock.yaml" ]; then echo "pnpm test"
        elif [ -f "${d}/yarn.lock" ];      then echo "yarn test"
        else echo "npm test"; fi
        return 0
    fi
    if [ -f "${d}/pyproject.toml" ] || [ -f "${d}/pytest.ini" ] || [ -f "${d}/setup.cfg" ] || [ -f "${d}/tox.ini" ]; then
        echo "pytest"; return 0
    fi
    if [ -f "${d}/Makefile" ] && grep -qE '^test:' "${d}/Makefile" 2>/dev/null; then echo "make test"; return 0; fi
    return 0
}

# Full-suite test gate before push. Aborts (exit 1) on failure or when no command is resolvable.
# Resolution: WORKTREE_TEST_CMD env > .worktreeconfig test_cmd > auto-detect. $1 = dir to test.
run_full_tests() {
    local worktree_path="$1"
    if [ "${WORKTREE_SKIP_TESTS:-}" = "1" ]; then
        echo "[test] WORKTREE_SKIP_TESTS=1 — skipping the pre-push test gate (explicit bypass)" >&2
        return 0
    fi
    local test_cmd="${WORKTREE_TEST_CMD:-}" source="WORKTREE_TEST_CMD"
    if [ -z "$test_cmd" ]; then test_cmd="$(wt_config test_cmd)"; [ -n "$test_cmd" ] && source=".worktreeconfig"; fi
    if [ -z "$test_cmd" ]; then test_cmd="$(detect_test_cmd "${worktree_path}")"; source="auto-detected"; fi
    if [ -z "$test_cmd" ]; then
        echo "" >&2
        echo "[test] No build system detected in ${worktree_path}; cannot run the pre-push test gate." >&2
        echo "  - set test_cmd= in .worktreeconfig (or export WORKTREE_TEST_CMD) and re-run, or" >&2
        echo "  - run tests another way, then export WORKTREE_SKIP_TESTS=1 to bypass consciously." >&2
        exit 1
    fi
    echo "[test] Running test gate before push (${source}): ${test_cmd}"
    if ( cd "${worktree_path}" && eval "${test_cmd}" ); then
        echo "[test] ✓ tests passed"
    else
        echo "" >&2
        echo "[test] ✗ tests FAILED (${test_cmd}) — push aborted. Fix and re-run." >&2
        exit 1
    fi
}

# Merge the base branch (origin/<base> if a remote exists, else local <base>) into the feature
# worktree. On conflict: leave the merge IN PROGRESS, print files + escape hatch, exit 1.
integrate_base() {
    local feature="$1" worktree_path="$2" base ref
    base="$(resolve_base)"
    if has_origin && git fetch origin "$base" --quiet 2>/dev/null; then ref="origin/${base}"; else ref="${base}"; fi
    if git -C "${worktree_path}" merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
        echo "[sync] ${feature} already current with ${ref}"
        return 0
    fi
    echo "[sync] Merging ${ref} into ${feature}..."
    if git -C "${worktree_path}" merge --no-verify --no-edit "$ref"; then
        echo "[sync] ${feature} updated with ${ref}"
    else
        echo "" >&2
        echo "[conflict] Merge conflict with ${ref}. Conflicted files:" >&2
        git -C "${worktree_path}" diff --name-only --diff-filter=U | sed 's/^/  - /' >&2
        echo "[info] Resolve in ${worktree_path} (fix → git add → git commit), then re-run." >&2
        echo "[info] Or abort:  git -C ${worktree_path} merge --abort" >&2
        exit 1
    fi
}

# integrate base → test gate → push. Returns 0 if pushed, 1 if there is no remote (guidance printed).
finish_common() {
    local feature="$1" worktree_path="$2"
    integrate_base "$feature" "$worktree_path"
    run_full_tests "$worktree_path"
    if has_origin; then
        git -C "${worktree_path}" push -u origin "${feature}" 2>/dev/null || git -C "${worktree_path}" push origin "${feature}"
        return 0
    fi
    local target; target="$(resolve_target)"
    echo "[info] No remote — '${feature}' is merged-with-base + tested + ready."
    echo "[info] Merge locally:  git switch ${target} && git merge ${feature}   (or add a remote and re-run)."
    return 1
}

# ----------------------------------------------------------------- commands

cmd_create() {
    local feature="$1" worktree_path="${WORKTREE_DIR}/$1" base
    require_main_worktree
    ensure_gitignore
    base="$(resolve_base)"
    if has_origin && git fetch origin "$base" --quiet 2>/dev/null; then
        git merge --ff-only "origin/${base}" >/dev/null 2>&1 || true   # best-effort refresh of local base
    fi
    if git show-ref --verify --quiet "refs/heads/${feature}"; then
        echo "[info] Branch '${feature}' already exists, reusing it"
    else
        git branch "${feature}" "${base}"
        echo "[info] Created branch '${feature}' from '${base}'"
    fi
    if [ -d "${worktree_path}" ]; then
        echo "[error] Worktree '${worktree_path}' already exists" >&2; exit 1
    fi
    git worktree add "${worktree_path}" "${feature}"
    echo ""
    echo "[success] Worktree created at: $(pwd)/${worktree_path}  (base: ${base})"
}

cmd_sync() {
    local feature="$1" worktree_path="${WORKTREE_DIR}/$1" target_dir base branch ref ahead
    if [ -d "${worktree_path}" ]; then
        target_dir="${worktree_path}"
    elif [ "$(git symbolic-ref --short HEAD 2>/dev/null || echo)" = "${feature}" ]; then
        target_dir="."
    else
        echo "[error] Worktree '${worktree_path}' not found and cwd is not on branch '${feature}'" >&2; exit 1
    fi
    base="$(resolve_base)"
    branch="$(git -C "${target_dir}" symbolic-ref --short HEAD 2>/dev/null || echo "")"
    if [ -z "$branch" ] || [ "$branch" = "$base" ] || [ "$branch" = "main" ] || [ "$branch" = "master" ]; then
        echo "[error] 'sync' is for feature worktrees only (current: ${branch:-detached}, base: ${base})" >&2; exit 1
    fi
    if has_origin && git fetch origin "$base" --quiet 2>/dev/null; then ref="origin/${base}"; else ref="${base}"; fi
    if git -C "${target_dir}" merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
        echo "[sync] ✓ ${branch} already current with ${ref}"; exit 0
    fi
    ahead="$(git -C "${target_dir}" rev-list --count "HEAD..${ref}" 2>/dev/null || echo "?")"
    echo "[sync] ${ref} is ${ahead} commit(s) ahead; merging into ${branch}..."
    if git -C "${target_dir}" merge --no-verify --no-edit "$ref"; then
        echo "[success] ${branch} synced with ${ref} (${ahead} commit(s))"
    else
        echo "" >&2
        echo "[conflict] Merge conflict with ${ref}. Conflicted files:" >&2
        git -C "${target_dir}" diff --name-only --diff-filter=U | sed 's/^/  - /' >&2
        echo "[info] Merge left IN PROGRESS (${target_dir}). Resolve (fix → git add → git commit --no-edit) or abort (git merge --abort)." >&2
        exit 1
    fi
}

cmd_push() {
    local feature="$1" worktree_path="${WORKTREE_DIR}/$1"
    require_main_worktree
    finish_common "$feature" "$worktree_path" || true
}

cmd_pr() {
    local feature="$1" worktree_path="${WORKTREE_DIR}/$1" target
    require_main_worktree
    target="$(resolve_target)"
    finish_common "$feature" "$worktree_path" || exit 0   # no remote → guidance already printed
    if command -v gh >/dev/null 2>&1 && remote_is_github; then
        if gh pr create --base "${target}" --head "${feature}" --fill; then
            echo "[success] PR created: ${feature} → ${target}"
        else
            echo "[info] PR may already exist — check: gh pr list --head ${feature}"
        fi
    else
        echo "[info] Pushed '${feature}'. Open a PR to '${target}' yourself (gh not found or non-GitHub remote)."
    fi
}

cmd_cleanup() {
    local feature="$1" worktree_path="${WORKTREE_DIR}/$1"
    require_main_worktree
    # Idempotent / skip-if-gone: a concurrent session or prior run may already have removed it.
    if git worktree list --porcelain | grep -qE "^worktree .*/${WORKTREE_DIR}/${feature}$"; then
        if [ -d "${worktree_path}" ]; then
            if ! git worktree remove "${worktree_path}"; then
                echo "[error] 'git worktree remove ${worktree_path}' failed — uncommitted/untracked changes or a lock." >&2
                echo "[error] Commit/push or remove manually, then re-run ('git worktree remove --force' only if work is safely pushed)." >&2
                exit 1
            fi
        fi
    else
        echo "[info] Worktree '${worktree_path}' not registered — already removed."
    fi
    git worktree prune
    echo "[success] Worktree '${worktree_path}' cleaned up (branch '${feature}' preserved)."
}

# ----------------------------------------------------------------- main

# Strip optional output-limiting flags from anywhere in the args; when present, re-run self
# WITHOUT the flag and slice via an INTERNAL pipe (no `|` in the caller's invocation).
limit_mode="" ; limit_n="" ; parsed_args=()
while [ $# -gt 0 ]; do
    case "$1" in
        --tail|--lines) limit_mode="tail"; limit_n="${2:-}"; shift 2 ;;
        --tail=*|--lines=*) limit_mode="tail"; limit_n="${1#*=}"; shift ;;
        --head) limit_mode="head"; limit_n="${2:-}"; shift 2 ;;
        --head=*) limit_mode="head"; limit_n="${1#*=}"; shift ;;
        *) parsed_args+=("$1"); shift ;;
    esac
done
set -- ${parsed_args[@]+"${parsed_args[@]}"}

if [ -n "$limit_mode" ]; then
    if ! [[ "$limit_n" =~ ^[0-9]+$ ]]; then
        echo "[error] --${limit_mode}/--lines requires a positive integer (got: '${limit_n}')" >&2; exit 1
    fi
    set +e
    bash "$0" "$@" 2>&1 | "$limit_mode" -n "$limit_n"
    rc=${PIPESTATUS[0]}
    set -e
    exit "$rc"
fi

if [ $# -lt 2 ]; then
    echo "Usage: worktree.sh <create|sync|push|pr|cleanup> <feature-name> [--tail N|--head N|--lines N]" >&2
    exit 1
fi

command="$1" ; feature="$2"
case "$command" in
    create)  cmd_create  "$feature" ;;
    sync)    cmd_sync    "$feature" ;;
    push)    cmd_push    "$feature" ;;
    pr)      cmd_pr      "$feature" ;;
    cleanup) cmd_cleanup "$feature" ;;
    *) echo "[error] Unknown command: $command" >&2
       echo "Usage: worktree.sh <create|sync|push|pr|cleanup> <feature-name> [--tail N|--head N|--lines N]" >&2
       exit 1 ;;
esac
