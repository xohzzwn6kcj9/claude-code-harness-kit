"""Shared helpers for repo-radar: no-shell subprocess runners + repo resolution.

Every external command runs via an argv list (never shell=True), so patterns containing
globs, backticks, newlines, `xargs`, or `<(` are inert strings — they cannot trip zsh or a
PreToolUse hook. Read-only by construction (callers only invoke read commands).
"""
from __future__ import annotations

import json
import subprocess
import sys
from typing import Optional


class RadarError(Exception):
    """A user-facing failure (bad ref, not a repo, gh missing, ...)."""


def run(args: list[str], cwd: Optional[str] = None, check: bool = False) -> tuple[int, str, str]:
    """Run an argv list with no shell. Returns (returncode, stdout, stderr)."""
    try:
        p = subprocess.run(
            args, cwd=cwd, capture_output=True, text=True,
        )
    except FileNotFoundError as e:
        raise RadarError(f"command not found: {args[0]} ({e})")
    if check and p.returncode != 0:
        raise RadarError(f"{' '.join(args)} failed (exit {p.returncode}): {p.stderr.strip()}")
    return p.returncode, p.stdout, p.stderr


def git(args: list[str], cwd: Optional[str] = None, check: bool = False) -> tuple[int, str, str]:
    return run(["git", *args], cwd=cwd, check=check)


def git_out(args: list[str], cwd: Optional[str] = None) -> str:
    """git that must succeed; returns stripped stdout."""
    _, out, _ = git(args, cwd=cwd, check=True)
    return out.strip()


def gh(args: list[str], cwd: Optional[str] = None, check: bool = True) -> tuple[int, str, str]:
    return run(["gh", *args], cwd=cwd, check=check)


def gh_json(args: list[str], cwd: Optional[str] = None):
    """Run a gh command that emits JSON and parse it."""
    _, out, _ = gh(args, cwd=cwd, check=True)
    out = out.strip()
    return json.loads(out) if out else None


def repo_root(cwd: Optional[str] = None) -> str:
    rc, out, err = git(["rev-parse", "--show-toplevel"], cwd=cwd)
    if rc != 0:
        raise RadarError(f"not a git repository (cwd={cwd or '.'}): {err.strip()}")
    return out.strip()


def ref_exists(ref: str, cwd: Optional[str] = None) -> bool:
    rc, _, _ = git(["rev-parse", "--verify", "--quiet", f"{ref}^{{commit}}"], cwd=cwd)
    return rc == 0


def require_ref(ref: str, cwd: Optional[str] = None) -> None:
    if not ref_exists(ref, cwd=cwd):
        raise RadarError(f"ref not found: {ref}")


def emit(obj, as_json: bool, human) -> int:
    """Print JSON (machine) or a human summary. `human` is a callable(obj) -> str."""
    if as_json:
        print(json.dumps(obj, indent=2, ensure_ascii=False))
    else:
        print(human(obj))
    return 0
