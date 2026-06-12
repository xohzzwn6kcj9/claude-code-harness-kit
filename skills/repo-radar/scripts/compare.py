"""compare group: ref/file/blob diff + cosmetic-vs-logic classification (read-only)."""
from __future__ import annotations

import difflib
import os

from common import RadarError, git, git_out, require_ref
from classify import classify_file_diff


def cmd_compare_refs(args) -> dict:
    cwd = args.repo_dir
    require_ref(args.ref, cwd)
    if args.ref2:
        require_ref(args.ref2, cwd)
    diff_args = ["diff"]
    if args.stat:
        diff_args.append("--stat")
    if args.name_only:
        diff_args.append("--name-only")
    diff_args.append(args.ref)
    if args.ref2:
        diff_args.append(args.ref2)
    if args.path:
        diff_args += ["--", *args.path]
    rc, out, err = git(diff_args, cwd=cwd)
    if rc not in (0, 1):
        raise RadarError(f"git diff failed: {err.strip()}")
    files = [ln for ln in git_out(
        ["diff", "--name-only", args.ref] + ([args.ref2] if args.ref2 else []), cwd=cwd
    ).split("\n") if ln]
    return {"ref": args.ref, "ref2": args.ref2, "changed_files": files,
            "changed_count": len(files), "diff": out}


def cmd_compare_file(args) -> dict:
    a, b = args.fileA, args.fileB
    for f in (a, b):
        if not os.path.exists(f):
            raise RadarError(f"file not found: {f}")
    ta = _read(a)
    tb = _read(b)
    equal = ta == tb
    res = {"fileA": a, "fileB": b, "equal": equal}
    if not equal and not args.quiet:
        res["diff"] = "".join(difflib.unified_diff(
            ta.splitlines(keepends=True), tb.splitlines(keepends=True),
            fromfile=a, tofile=b))
        res["classify"] = classify_file_diff(ta, tb, a)["verdict"]
    return res


def cmd_compare_blob(args) -> dict:
    cwd = args.repo_dir
    path, rx, ry = args.path, args.refX, args.refY
    rc1, ax, e1 = git(["show", f"{rx}:{path}"], cwd=cwd)
    rc2, ay, e2 = git(["show", f"{ry}:{path}"], cwd=cwd)
    if rc1 != 0:
        raise RadarError(f"{rx}:{path} not found: {e1.strip()}")
    if rc2 != 0:
        raise RadarError(f"{ry}:{path} not found: {e2.strip()}")
    cls = classify_file_diff(ax, ay, path)
    res = {"path": path, "refX": rx, "refY": ry, "equal": ax == ay, "verdict": cls["verdict"]}
    if ax != ay:
        res["diff"] = "".join(difflib.unified_diff(
            ax.splitlines(keepends=True), ay.splitlines(keepends=True),
            fromfile=f"{rx}:{path}", tofile=f"{ry}:{path}"))
    return res


def cmd_compare_classify(args) -> dict:
    cwd = args.repo_dir
    old_ref, new_ref = _resolve_range(args.target, args.ref2, cwd)
    files = [ln for ln in git_out(
        ["diff", "--name-only", old_ref, new_ref], cwd=cwd).split("\n") if ln]
    if args.path:
        files = [f for f in files if f in set(args.path)]
    rows = []
    for path in files:
        rc1, a, _ = git(["show", f"{old_ref}:{path}"], cwd=cwd)
        rc2, b, _ = git(["show", f"{new_ref}:{path}"], cwd=cwd)
        if rc1 != 0 or rc2 != 0:
            rows.append({"path": path, "lang": None, "verdict": "logical",
                         "note": "added/removed file"})
        else:
            rows.append(classify_file_diff(a, b, path))
    n_fmt = sum(1 for r in rows if r["verdict"] == "formatting_only")
    n_log = sum(1 for r in rows if r["verdict"] == "logical")
    return {
        "old": old_ref, "new": new_ref, "file_count": len(rows),
        "formatting_only": n_fmt, "logical": n_log,
        "overall": "formatting_only" if n_log == 0 and rows else ("logical" if rows else "identical"),
        "files": rows,
    }


def _resolve_range(target: str, ref2, cwd: str):
    require_ref(target, cwd)
    if ref2:
        require_ref(ref2, cwd)
        return target, ref2
    # Single ref → compare it against its first parent.
    return f"{target}^", target


def _read(path: str) -> str:
    with open(path, "r", errors="replace") as fh:
        return fh.read()


# ---- human renderers ----

def human_compare_refs(o: dict) -> str:
    head = f"{o['ref']}{'..' + o['ref2'] if o['ref2'] else ''}: {o['changed_count']} file(s) changed"
    return head + ("\n" + o["diff"] if o.get("diff") else "")


def human_compare_file(o: dict) -> str:
    if o["equal"]:
        return f"EQUAL: {o['fileA']} == {o['fileB']}"
    head = f"DIFFER ({o.get('classify','?')}): {o['fileA']} vs {o['fileB']}"
    return head + ("\n" + o["diff"] if o.get("diff") else "")


def human_compare_blob(o: dict) -> str:
    if o["equal"]:
        return f"EQUAL: {o['path']} @ {o['refX']} == {o['refY']}"
    return f"DIFFER ({o['verdict']}): {o['path']} @ {o['refX']} vs {o['refY']}\n" + o.get("diff", "")


def human_compare_classify(o: dict) -> str:
    head = (f"{o['old']}..{o['new']}: overall={o['overall']} "
            f"({o['formatting_only']} formatting-only, {o['logical']} logical, {o['file_count']} files)")
    rows = "\n".join(f"  {r['verdict']:<16} {r['path']}" for r in o["files"])
    return head + ("\n" + rows if rows else "")
