#!/usr/bin/env python3
"""repo-radar — read-only repo/branch/search/diff analysis toolkit.

One non-shell call per query:
    python3 radar.py <group> <subcmd> [args] [--json]

Groups: git | search | compare | pr. See SKILL.md. Underlying git/gh/grep/diff run via
subprocess argv lists (no shell), so the query never trips zsh, globs, or PreToolUse hooks.
"""
from __future__ import annotations

import argparse
import os
import sys

import gitq
import ghq
import search
import compare
from common import RadarError


def _global_parent() -> argparse.ArgumentParser:
    g = argparse.ArgumentParser(add_help=False)
    g.add_argument("--repo-dir", default=None, dest="repo_dir",
                   help="repository directory (default: current dir)")
    g.add_argument("--json", action="store_true", help="emit JSON")
    return g


# (group, sub) -> (run_fn, human_renderer)
DISPATCH = {
    ("git", "overview"): (gitq.cmd_overview, gitq.human_overview),
    ("git", "diverge"): (gitq.cmd_diverge, gitq.human_diverge),
    ("git", "worktrees"): (gitq.cmd_worktrees, gitq.human_worktrees),
    ("git", "mergecheck"): (gitq.cmd_mergecheck, gitq.human_mergecheck),
    ("git", "conflicts"): (gitq.cmd_conflicts, gitq.human_conflicts),
    ("git", "prmap"): (ghq.cmd_prmap, ghq.human_prmap),
    ("pr", "status"): (ghq.cmd_pr_status, ghq.human_pr_status),
    ("pr", "list-open"): (ghq.cmd_pr_list_open, ghq.human_pr_list_open),
    ("pr", "comments"): (ghq.cmd_pr_comments, ghq.human_pr_comments),
    ("search", "code"): (search.cmd_search_code, search.human_search_code),
    ("search", "log"): (search.cmd_search_log, search.human_search_log),
    ("compare", "refs"): (compare.cmd_compare_refs, compare.human_compare_refs),
    ("compare", "file"): (compare.cmd_compare_file, compare.human_compare_file),
    ("compare", "blob"): (compare.cmd_compare_blob, compare.human_compare_blob),
    ("compare", "classify"): (compare.cmd_compare_classify, compare.human_compare_classify),
}


def build_parser() -> argparse.ArgumentParser:
    g = _global_parent()
    p = argparse.ArgumentParser(prog="radar.py", description=__doc__.split("\n")[0])
    groups = p.add_subparsers(dest="group")

    # git
    gp = groups.add_parser("git").add_subparsers(dest="sub")
    o = gp.add_parser("overview", parents=[g]); o.add_argument("--targets", default="main,release")
    d = gp.add_parser("diverge", parents=[g]); d.add_argument("refA"); d.add_argument("refB")
    w = gp.add_parser("worktrees", parents=[g]); w.add_argument("--targets", default="main,release")
    m = gp.add_parser("mergecheck", parents=[g]); m.add_argument("src"); m.add_argument("into")
    gp.add_parser("conflicts", parents=[g])
    pm = gp.add_parser("prmap", parents=[g]); pm.add_argument("--repo", default=None)

    # pr
    pp = groups.add_parser("pr").add_subparsers(dest="sub")
    ps = pp.add_parser("status", parents=[g])
    ps.add_argument("numbers", nargs="*", type=int); ps.add_argument("--repo", default=None)
    pl = pp.add_parser("list-open", parents=[g]); pl.add_argument("--repo", default=None)
    pc = pp.add_parser("comments", parents=[g])
    pc.add_argument("number", type=int); pc.add_argument("--since", default=None)
    pc.add_argument("--repo", default=None)

    # search
    sp = groups.add_parser("search").add_subparsers(dest="sub")
    sc = sp.add_parser("code", parents=[g])
    sc.add_argument("pattern"); sc.add_argument("--ext", default="")
    sc.add_argument("--path", nargs="*"); sc.add_argument("--exclude", nargs="*")
    sc.add_argument("--files-only", action="store_true", dest="files_only")
    sc.add_argument("--count", action="store_true")
    sc.add_argument("-i", "--ignore-case", action="store_true", dest="ignore_case")
    sl = sp.add_parser("log", parents=[g])
    sl.add_argument("pattern"); sl.add_argument("--file", nargs="+", required=True)
    sl.add_argument("--context", type=int, default=0)
    sl.add_argument("--strip-ansi", action="store_true", dest="strip_ansi")
    sl.add_argument("--mask", nargs="*", default=[])
    sl.add_argument("--jsonl-field", default=None, dest="jsonl_field")
    sl.add_argument("-i", "--ignore-case", action="store_true", dest="ignore_case")

    # compare
    cp = groups.add_parser("compare").add_subparsers(dest="sub")
    cr = cp.add_parser("refs", parents=[g])
    cr.add_argument("ref"); cr.add_argument("ref2", nargs="?", default=None)
    cr.add_argument("--stat", action="store_true"); cr.add_argument("--name-only", action="store_true", dest="name_only")
    cr.add_argument("--path", nargs="*")
    cf = cp.add_parser("file", parents=[g])
    cf.add_argument("fileA"); cf.add_argument("fileB"); cf.add_argument("--quiet", action="store_true")
    cb = cp.add_parser("blob", parents=[g])
    cb.add_argument("path"); cb.add_argument("refX"); cb.add_argument("refY")
    cc = cp.add_parser("classify", parents=[g])
    cc.add_argument("target"); cc.add_argument("ref2", nargs="?", default=None)
    cc.add_argument("--path", nargs="*")
    return p


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    group = getattr(args, "group", None)
    sub = getattr(args, "sub", None)
    if not group or not sub:
        parser.print_help()
        return 1
    key = (group, sub)
    if key not in DISPATCH:
        parser.print_help()
        return 1
    # Normalize repo dir (subprocess cwd). Default = current working directory.
    args.repo_dir = args.repo_dir or os.getcwd()
    run_fn, human = DISPATCH[key]
    try:
        result = run_fn(args)
    except RadarError as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    if args.json:
        import json
        print(json.dumps(result, indent=2, ensure_ascii=False))
    else:
        print(human(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
