"""search group: robust code/log search with no shell.

`search code` builds a ripgrep (or grep) argv list — globs like *.kt are passed as argv
elements, never expanded by zsh, so the `--include=*.kt` "no matches found" trap is impossible.
`search log` reads files directly in Python (ANSI strip, secret masking, JSONL field walk).
"""
from __future__ import annotations

import glob as globmod
import json
import re
import shutil

from common import RadarError, run

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

# Dirs skipped by default (VCS, nested worktrees, build/dependency artifacts). ripgrep also
# honors .gitignore on top of these; grep relies solely on these.
_DEFAULT_EXCLUDE_DIRS = [
    ".git", ".worktree", "node_modules", "build", ".gradle", "target", "dist", ".idea", ".venv",
]


def _ext_globs(exts: str) -> list[str]:
    out = []
    for e in (exts or "").split(","):
        e = e.strip().lstrip(".")
        if e:
            out.append(f"*.{e}")
    return out


def cmd_search_code(args) -> dict:
    cwd = args.repo_dir
    pattern = args.pattern
    roots = args.path or ["."]
    use_rg = shutil.which("rg") is not None

    if use_rg:
        argv = ["rg", "--no-heading", "--line-number", "--column", "--color", "never"]
        if args.ignore_case:
            argv.append("-i")
        if args.files_only:
            argv = ["rg", "--files-with-matches", "--color", "never"] + (["-i"] if args.ignore_case else [])
        elif args.count:
            argv = ["rg", "--count", "--color", "never"] + (["-i"] if args.ignore_case else [])
        for g in _ext_globs(args.ext):
            argv += ["-g", g]
        for d in _DEFAULT_EXCLUDE_DIRS:
            argv += ["-g", f"!**/{d}/**"]
        for g in (args.exclude or []):
            argv += ["-g", f"!{g}"]
        argv += ["--", pattern, *roots]
    else:
        argv = ["grep", "-rn"]
        if args.ignore_case:
            argv.append("-i")
        if args.files_only:
            argv = ["grep", "-rln"] + (["-i"] if args.ignore_case else [])
        for g in _ext_globs(args.ext):
            argv += [f"--include={g}"]
        for d in _DEFAULT_EXCLUDE_DIRS:
            argv += [f"--exclude-dir={d}"]
        for g in (args.exclude or []):
            argv += [f"--exclude={g}"]
        argv += ["-e", pattern, *roots]

    rc, out, err = run(argv, cwd=cwd)
    # rc==1 means "no matches" for both rg and grep — not an error.
    if rc not in (0, 1):
        raise RadarError(f"search failed (exit {rc}): {err.strip()}")

    lines = [ln for ln in out.split("\n") if ln]
    if args.files_only:
        return {"engine": argv[0], "pattern": pattern, "files": lines, "count": len(lines)}
    if args.count:
        counts = {}
        for ln in lines:
            if ":" in ln:
                f, _, c = ln.rpartition(":")
                counts[f] = int(c) if c.isdigit() else 0
        return {"engine": argv[0], "pattern": pattern, "counts": counts,
                "total": sum(counts.values())}
    matches = []
    for ln in lines:
        # rg: file:line:col:text ; grep: file:line:text
        parts = ln.split(":", 3) if use_rg else ln.split(":", 2)
        if use_rg and len(parts) == 4:
            matches.append({"file": parts[0], "line": int_or(parts[1]),
                            "col": int_or(parts[2]), "text": parts[3]})
        elif not use_rg and len(parts) == 3:
            matches.append({"file": parts[0], "line": int_or(parts[1]), "text": parts[2]})
        else:
            matches.append({"raw": ln})
    return {"engine": argv[0], "pattern": pattern, "match_count": len(matches), "matches": matches}


def int_or(s: str, default=None):
    return int(s) if s.isdigit() else default


def _mask(text: str, patterns: list[str]) -> str:
    for p in patterns or []:
        text = re.sub(p, "<masked>", text)
    return text


def _dig(obj, dotted: str):
    cur = obj
    for key in dotted.split("."):
        if isinstance(cur, dict) and key in cur:
            cur = cur[key]
        else:
            return None
    return cur


def cmd_search_log(args) -> dict:
    pattern = re.compile(args.pattern, re.IGNORECASE if args.ignore_case else 0)
    files = []
    for spec in args.file:
        files.extend(sorted(globmod.glob(spec, recursive=True)))
    if not files:
        raise RadarError(f"no files matched: {', '.join(args.file)}")
    ctx = args.context or 0
    results = []
    for path in files:
        try:
            with open(path, "r", errors="replace") as fh:
                raw_lines = fh.read().split("\n")
        except OSError as e:
            results.append({"file": path, "error": str(e)})
            continue
        hits = []
        for i, line in enumerate(raw_lines):
            hay = line
            if args.jsonl_field:
                try:
                    val = _dig(json.loads(line), args.jsonl_field)
                    hay = "" if val is None else (val if isinstance(val, str) else json.dumps(val))
                except (json.JSONDecodeError, ValueError):
                    continue
            if args.strip_ansi:
                hay = _ANSI_RE.sub("", hay)
            if pattern.search(hay):
                lo, hi = max(0, i - ctx), min(len(raw_lines), i + ctx + 1)
                block = "\n".join(raw_lines[lo:hi]) if ctx else hay
                if args.strip_ansi:
                    block = _ANSI_RE.sub("", block)
                hits.append({"line": i + 1, "text": _mask(block, args.mask)})
        if hits:
            results.append({"file": path, "hit_count": len(hits), "hits": hits})
    return {"pattern": args.pattern, "files_scanned": len(files), "results": results}


# ---- human renderers ----

def human_search_code(o: dict) -> str:
    if "files" in o:
        return f"{o['count']} file(s):\n" + "\n".join("  " + f for f in o["files"])
    if "counts" in o:
        rows = "\n".join(f"  {c:>4}  {f}" for f, c in o["counts"].items())
        return f"total {o['total']}\n{rows}"
    if not o["matches"]:
        return f"no matches for {o['pattern']!r}"
    rows = "\n".join(
        f"  {m.get('file','?')}:{m.get('line','?')}: {m.get('text', m.get('raw','')).strip()}"
        for m in o["matches"])
    return f"{o['match_count']} match(es):\n{rows}"


def human_search_log(o: dict) -> str:
    if not o["results"]:
        return f"no matches for {o['pattern']!r} in {o['files_scanned']} file(s)"
    lines = []
    for r in o["results"]:
        if "error" in r:
            lines.append(f"{r['file']}: ERROR {r['error']}")
            continue
        lines.append(f"{r['file']} ({r['hit_count']}):")
        for h in r["hits"]:
            lines.append(f"  {h['line']}: {h['text']}")
    return "\n".join(lines)
