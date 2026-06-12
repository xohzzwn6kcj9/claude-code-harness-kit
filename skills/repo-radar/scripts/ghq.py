"""pr group: read-only GitHub PR state via `gh --json` parsed in Python.

Iteration happens here in Python, so callers never `for x in $(gh ...)` in zsh — which is the
canonical word-splitting data-corruption bug. Read-only: no commenting/merging.
"""
from __future__ import annotations

from common import gh_json


def _repo_args(args) -> list[str]:
    return ["-R", args.repo] if getattr(args, "repo", None) else []


def cmd_prmap(args) -> dict:
    cwd = args.repo_dir
    fields = "number,title,state,baseRefName,headRefName,mergedAt,mergeCommit,mergeable,mergeStateStatus"
    prs = gh_json(["pr", "list", "--state", "all", "--limit", "200",
                   *_repo_args(args), "--json", fields], cwd=cwd) or []
    by_base: dict[str, list[int]] = {}
    rows = []
    for pr in prs:
        base = pr.get("baseRefName")
        merged = pr.get("state") == "MERGED"
        mc = (pr.get("mergeCommit") or {}).get("oid", "")
        rows.append({
            "number": pr["number"], "title": pr["title"], "state": pr["state"],
            "base": base, "head": pr.get("headRefName"),
            "mergedAt": pr.get("mergedAt"), "mergeCommit": mc[:9] if mc else None,
            "mergeable": pr.get("mergeable"), "mergeStateStatus": pr.get("mergeStateStatus"),
        })
        if merged:
            by_base.setdefault(base, []).append(pr["number"])
    return {
        "open": [r for r in rows if r["state"] == "OPEN"],
        "merged_by_base": by_base,
        "all": rows,
    }


def cmd_pr_status(args) -> dict:
    cwd = args.repo_dir
    fields = "number,title,state,baseRefName,headRefName,headRefOid,mergeable,mergeStateStatus,isDraft"
    nums = args.numbers
    if not nums:
        prs = gh_json(["pr", "list", "--state", "open", "--limit", "100",
                       *_repo_args(args), "--json", fields], cwd=cwd) or []
    else:
        prs = []
        for n in nums:
            prs.append(gh_json(["pr", "view", str(n), *_repo_args(args), "--json", fields], cwd=cwd))
    out = []
    for pr in prs:
        if not pr:
            continue
        oid = pr.get("headRefOid") or ""
        out.append({
            "number": pr["number"], "title": pr.get("title"), "state": pr["state"],
            "base": pr.get("baseRefName"), "head": pr.get("headRefName"),
            "headRefOid": oid[:9], "mergeable": pr.get("mergeable"),
            "mergeStateStatus": pr.get("mergeStateStatus"), "draft": pr.get("isDraft"),
        })
    return {"prs": out}


def cmd_pr_list_open(args) -> dict:
    cwd = args.repo_dir
    fields = "number,title,baseRefName,headRefName,mergeable,mergeStateStatus,isDraft"
    prs = gh_json(["pr", "list", "--state", "open", "--limit", "100",
                   *_repo_args(args), "--json", fields], cwd=cwd) or []
    return {"open": prs, "count": len(prs)}


def cmd_pr_comments(args) -> dict:
    cwd = args.repo_dir
    pr = gh_json(["pr", "view", str(args.number), *_repo_args(args), "--json", "comments"], cwd=cwd)
    comments = (pr or {}).get("comments", [])
    since = getattr(args, "since", None)
    rows = []
    for c in comments:
        created = c.get("createdAt", "")
        if since and created <= since:
            continue
        body = (c.get("body") or "").strip().replace("\n", " ")
        rows.append({
            "author": (c.get("author") or {}).get("login"),
            "createdAt": created,
            "body": body[:200] + ("…" if len(body) > 200 else ""),
        })
    return {"number": args.number, "since": since, "new_count": len(rows), "comments": rows}


# ---- human renderers ----

def human_prmap(o: dict) -> str:
    lines = ["merged by base:"]
    for base, nums in o["merged_by_base"].items():
        lines.append(f"  {base}: " + ", ".join(f"#{n}" for n in nums))
    lines.append("open:")
    for r in o["open"]:
        lines.append(f"  #{r['number']} {r['head']}→{r['base']} "
                     f"[{r['mergeable']}/{r['mergeStateStatus']}] {r['title']}")
    return "\n".join(lines)


def human_pr_status(o: dict) -> str:
    if not o["prs"]:
        return "no PRs"
    return "\n".join(
        f"#{p['number']} [{p['state']}] {p['head']}→{p['base']} "
        f"{p['headRefOid']} mergeable={p['mergeable']}/{p['mergeStateStatus']} {p.get('title') or ''}"
        for p in o["prs"])


def human_pr_list_open(o: dict) -> str:
    if not o["open"]:
        return "no open PRs"
    return "\n".join(
        f"#{p['number']} {p['headRefName']}→{p['baseRefName']} "
        f"[{p['mergeable']}/{p['mergeStateStatus']}] {p['title']}" for p in o["open"])


def human_pr_comments(o: dict) -> str:
    head = f"PR #{o['number']}: {o['new_count']} comment(s)" + (f" since {o['since']}" if o['since'] else "")
    rows = "\n".join(f"  [{c['createdAt']}] {c['author']}: {c['body']}" for c in o["comments"])
    return head + ("\n" + rows if rows else "")
