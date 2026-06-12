"""git group: branch/merge/worktree analysis (read-only, no shell)."""
from __future__ import annotations

from common import RadarError, git, git_out, require_ref
from classify import classify_file_diff


def _sha(ref: str, cwd: str) -> str:
    rc, out, _ = git(["rev-parse", "--short", ref], cwd=cwd)
    return out.strip() if rc == 0 else ""


def _ahead_behind(ref: str, target: str, cwd: str) -> dict:
    """ahead = commits in ref not in target; behind = commits in target not in ref."""
    rc, out, _ = git(["rev-list", "--left-right", "--count", f"{target}...{ref}"], cwd=cwd)
    if rc != 0:
        return {"ahead": None, "behind": None}
    left, right = (out.split() + ["0", "0"])[:2]
    return {"ahead": int(right), "behind": int(left)}


def _is_ancestor(a: str, b: str, cwd: str) -> bool:
    """True if a is an ancestor of b (so b can fast-forward to include a)."""
    rc, _, _ = git(["merge-base", "--is-ancestor", a, b], cwd=cwd)
    return rc == 0


def _merged_into(branch: str, target: str, cwd: str) -> bool:
    return _is_ancestor(branch, target, cwd)


def _local_branches(cwd: str) -> list[str]:
    out = git_out(["for-each-ref", "--format=%(refname:short)", "refs/heads"], cwd=cwd)
    return [b for b in out.split("\n") if b]


def _remote_branches(cwd: str) -> list[str]:
    out = git_out(["for-each-ref", "--format=%(refname:short)", "refs/remotes"], cwd=cwd)
    return [b for b in out.split("\n") if b and not b.endswith("/HEAD")]


def _worktrees(cwd: str) -> list[dict]:
    rc, out, _ = git(["worktree", "list", "--porcelain"], cwd=cwd)
    if rc != 0:
        return []
    trees, cur = [], {}
    for line in out.split("\n"):
        if not line.strip():
            if cur:
                trees.append(cur)
                cur = {}
            continue
        if line.startswith("worktree "):
            cur["path"] = line[len("worktree "):]
        elif line.startswith("HEAD "):
            cur["head"] = line[len("HEAD "):][:9]
        elif line.startswith("branch "):
            cur["branch"] = line[len("branch "):].replace("refs/heads/", "")
        elif line.strip() in ("detached", "bare", "locked", "prunable"):
            cur[line.strip()] = True
    if cur:
        trees.append(cur)
    return trees


# ---- subcommands ----

def cmd_overview(args) -> dict:
    cwd = args.repo_dir
    targets = [t for t in (args.targets or "main,release").split(",") if t]
    targets = [t for t in targets if require_ref_silent(t, cwd)]
    branches = []
    for b in _local_branches(cwd):
        row = {"branch": b, "sha": _sha(b, cwd), "vs": {}}
        for t in targets:
            row["vs"][t] = {**_ahead_behind(b, t, cwd), "merged": _merged_into(b, t, cwd)}
        branches.append(row)
    return {
        "repo": cwd,
        "targets": {t: _sha(t, cwd) for t in targets},
        "local_branches": branches,
        "remote_branches": {b: _sha(b, cwd) for b in _remote_branches(cwd)},
        "worktrees": _worktrees(cwd),
    }


def require_ref_silent(ref: str, cwd: str) -> bool:
    rc, _, _ = git(["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], cwd=cwd)
    return rc == 0


def cmd_diverge(args) -> dict:
    cwd = args.repo_dir
    a, b = args.refA, args.refB
    require_ref(a, cwd)
    require_ref(b, cwd)
    rc, mb, _ = git(["merge-base", a, b], cwd=cwd)
    merge_base = mb.strip()[:9] if rc == 0 else None
    ab = _ahead_behind(a, b, cwd)  # ahead = in a not b; behind = in b not a
    a_anc_b = _is_ancestor(a, b, cwd)
    b_anc_a = _is_ancestor(b, a, cwd)
    state = "identical" if a_anc_b and b_anc_a else (
        f"{b} can fast-forward to {a}" if a_anc_b else
        f"{a} can fast-forward to {b}" if b_anc_a else "diverged")
    unique_a = [ln for ln in git_out(["log", "--oneline", f"{b}..{a}"], cwd=cwd).split("\n") if ln]
    unique_b = [ln for ln in git_out(["log", "--oneline", f"{a}..{b}"], cwd=cwd).split("\n") if ln]
    return {
        "refA": a, "refB": b, "merge_base": merge_base,
        "a_unique_count": len(unique_a), "b_unique_count": len(unique_b),
        "a_is_ancestor_of_b": a_anc_b, "b_is_ancestor_of_a": b_anc_a,
        "ff_possible": a_anc_b or b_anc_a, "state": state,
        "a_unique": unique_a, "b_unique": unique_b,
    }


def cmd_worktrees(args) -> dict:
    cwd = args.repo_dir
    targets = [t for t in (args.targets or "main,release").split(",") if require_ref_silent(t, cwd)]
    rows = []
    for wt in _worktrees(cwd):
        branch = wt.get("branch")
        rc, status, _ = git(["status", "--porcelain"], cwd=wt["path"])
        dirty = bool(status.strip()) if rc == 0 else None
        merged = {t: _merged_into(branch, t, cwd) for t in targets} if branch else {}
        is_main_wt = branch in ("main", "master")
        cleanup = bool(branch) and not is_main_wt and any(merged.values()) and dirty is False
        rows.append({
            "path": wt["path"], "branch": branch, "head": wt.get("head"),
            "dirty": dirty, "merged": merged,
            "cleanup_candidate": cleanup,
            "note": "merged + clean → safe to `git worktree remove` (keep branch)" if cleanup else "",
        })
    return {"repo": cwd, "targets": targets, "worktrees": rows}


def cmd_mergecheck(args) -> dict:
    cwd = args.repo_dir
    src, into = args.src, args.into
    require_ref(src, cwd)
    require_ref(into, cwd)
    if _is_ancestor(src, into, cwd):
        return {"src": src, "into": into, "ff_possible": True, "already_merged": True,
                "conflicts": [], "summary": f"{src} already contained in {into}"}
    ff = _is_ancestor(into, src, cwd)
    # Predict the merge without touching the working tree (git >= 2.38).
    rc, out, err = git(["merge-tree", "--write-tree", "--name-only", into, src], cwd=cwd)
    if rc == 0:
        return {"src": src, "into": into, "ff_possible": ff, "already_merged": False,
                "conflicts": [], "summary": "merges cleanly (no conflicts)"}
    if rc != 1 and err.strip() and "usage" in err.lower():
        # Old git without --write-tree support.
        return {"src": src, "into": into, "ff_possible": ff, "error": err.strip(),
                "summary": "merge-tree --write-tree unsupported on this git; cannot predict"}
    # rc==1 ⇒ conflicts. Format: <tree-oid>\n<conflicted paths>\n\n<localized info messages>.
    # Take only the conflicted-path block (line 1 until the first blank line); ignore the
    # trailing "Auto-merging / CONFLICT" messages (which are localized and not file names).
    raw = out.split("\n")
    conflicted = []
    for ln in raw[1:]:
        if ln.strip() == "":
            break
        conflicted.append(ln)
    classified = []
    for path in conflicted:
        verdict = _classify_two_sides(path, into, src, cwd)
        classified.append(verdict)
    n_fmt = sum(1 for c in classified if c["verdict"] == "formatting_only")
    return {
        "src": src, "into": into, "ff_possible": ff, "already_merged": False,
        "conflict_count": len(conflicted),
        "conflicts": classified,
        "summary": f"{len(conflicted)} conflicted file(s); {n_fmt} formatting-only, "
                   f"{len(conflicted) - n_fmt} logical",
    }


_CHECK_RE = __import__("re").compile(r"^(?P<path>.+):(?P<line>\d+): (?P<msg>.+?)\.?$")


def _check_issues(cached: bool, cwd: str) -> list[dict]:
    """Parse `git diff [--cached] --check` into structured issues (markers + whitespace)."""
    argv = ["diff", "--check"] + (["--cached"] if cached else [])
    rc, out, _ = git(argv, cwd=cwd)
    issues = []
    for ln in out.split("\n"):
        m = _CHECK_RE.match(ln)
        if not m:
            continue  # offending content lines don't match path:line: — skipped
        msg = m.group("msg")
        kind = "conflict_marker" if "conflict marker" in msg else "whitespace"
        issues.append({"path": m.group("path"), "line": int(m.group("line")),
                       "kind": kind, "msg": msg, "staged": cached})
    return issues


def cmd_conflicts(args) -> dict:
    """Detect leftover conflict markers + unmerged paths (read-only working-tree check).

    Canonical git tooling, not grep: `git diff --check` flags real conflict markers (no
    `=======` false positives), `git ls-files -u` lists mid-merge unresolved paths.
    """
    cwd = args.repo_dir
    rc, out, err = git(["rev-parse", "--is-inside-work-tree"], cwd=cwd)
    if rc != 0:
        raise RadarError(f"not a git repository (cwd={cwd}): {err.strip()}")
    # Unmerged (stage > 0) paths — present only during an in-progress merge.
    _, u_out, _ = git(["ls-files", "-u"], cwd=cwd)
    unmerged = sorted({ln.split("\t", 1)[1] for ln in u_out.split("\n")
                       if "\t" in ln})
    # Deduplicate issues across worktree + index by (path, line, kind).
    seen, issues = set(), []
    for it in _check_issues(False, cwd) + _check_issues(True, cwd):
        key = (it["path"], it["line"], it["kind"])
        if key not in seen:
            seen.add(key)
            issues.append(it)
    markers = [i for i in issues if i["kind"] == "conflict_marker"]
    whitespace = [i for i in issues if i["kind"] == "whitespace"]
    return {
        "repo": cwd,
        "clean": not unmerged and not markers,
        "unmerged": unmerged,
        "marker_count": len(markers),
        "markers": markers,
        "whitespace_count": len(whitespace),
        "whitespace": whitespace,
    }


def _classify_two_sides(path: str, into: str, src: str, cwd: str) -> dict:
    """Classify whether the two sides' versions of a conflicted file differ only cosmetically."""
    rc1, a, _ = git(["show", f"{into}:{path}"], cwd=cwd)
    rc2, b, _ = git(["show", f"{src}:{path}"], cwd=cwd)
    if rc1 != 0 or rc2 != 0:
        return {"path": path, "lang": None, "verdict": "logical",
                "note": "added/removed on one side"}
    return classify_file_diff(a, b, path)


# ---- human renderers ----

def human_overview(o: dict) -> str:
    lines = [f"repo: {o['repo']}",
             "targets: " + ", ".join(f"{t}={s}" for t, s in o["targets"].items()),
             "", "local branches:"]
    for b in o["local_branches"]:
        vs = "  ".join(
            f"{t}[+{v['ahead']}/-{v['behind']}{',merged' if v['merged'] else ''}]"
            for t, v in b["vs"].items())
        lines.append(f"  {b['branch']:<28} {b['sha']:<10} {vs}")
    lines.append("")
    lines.append("worktrees:")
    for w in o["worktrees"]:
        lines.append(f"  {w.get('branch') or '(detached)':<28} {w.get('head','')}  {w['path']}")
    return "\n".join(lines)


def human_diverge(d: dict) -> str:
    return (f"{d['refA']} ↔ {d['refB']}\n"
            f"  merge-base: {d['merge_base']}\n"
            f"  {d['refA']} unique: {d['a_unique_count']}   {d['refB']} unique: {d['b_unique_count']}\n"
            f"  ff_possible: {d['ff_possible']}   state: {d['state']}")


def human_worktrees(o: dict) -> str:
    lines = [f"repo: {o['repo']}", "worktrees:"]
    for w in o["worktrees"]:
        merged = ",".join(t for t, m in w["merged"].items() if m) or "-"
        flag = "  ← CLEANUP" if w["cleanup_candidate"] else ""
        lines.append(f"  {str(w['branch']):<28} dirty={w['dirty']} merged={merged}{flag}")
        lines.append(f"      {w['path']}")
    return "\n".join(lines)


def human_conflicts(o: dict) -> str:
    if o["clean"]:
        extra = f" ({o['whitespace_count']} whitespace note(s))" if o["whitespace_count"] else ""
        return f"clean ✓ — no conflict markers, no unmerged paths{extra}"
    lines = []
    if o["unmerged"]:
        lines.append(f"unmerged paths ({len(o['unmerged'])}):")
        lines += [f"  {p}" for p in o["unmerged"]]
    if o["markers"]:
        lines.append(f"conflict markers ({o['marker_count']}):")
        lines += [f"  {i['path']}:{i['line']}  {i['msg']}" for i in o["markers"]]
    if o["whitespace"]:
        lines.append(f"whitespace ({o['whitespace_count']}):")
        lines += [f"  {i['path']}:{i['line']}  {i['msg']}" for i in o["whitespace"]]
    return "\n".join(lines)


def human_mergecheck(m: dict) -> str:
    head = f"{m['src']} → {m['into']}: {m['summary']} (ff_possible={m.get('ff_possible')})"
    if not m.get("conflicts"):
        return head
    rows = "\n".join(f"  {c['verdict']:<16} {c['path']}" for c in m["conflicts"])
    return head + "\n" + rows
