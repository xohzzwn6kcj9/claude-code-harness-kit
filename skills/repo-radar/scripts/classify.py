"""Cosmetic-vs-logical change classifier (advisory, language-aware).

Used by `compare classify` and `git mergecheck` to answer: "is this delta pure reformatting
(ktlint / black / import-sort / whitespace) or did a semantic token change?"

Heuristic, NOT a parser. It normalizes away formatting that linters routinely churn, then
compares the resulting token streams. A non-empty token-level diff ⇒ "logical". Bias is toward
SAFETY: when unsure (e.g. an unknown language, or normalization can't prove equivalence) it
reports "logical" so a human still looks. See references/classify-heuristics.md.
"""
from __future__ import annotations

import re

# Comment styles per language family.
_LINE_COMMENT = {
    "kotlin": "//", "java": "//", "javascript": "//", "typescript": "//",
    "go": "//", "rust": "//", "c": "//", "scala": "//", "swift": "//",
    "python": "#", "ruby": "#", "yaml": "#", "shell": "#", "toml": "#",
}
_BLOCK_COMMENT = {"/*": "*/"}

_C_LIKE = {"kotlin", "java", "javascript", "typescript", "go", "rust", "c", "scala", "swift"}

_EXT_LANG = {
    ".kt": "kotlin", ".kts": "kotlin", ".java": "java", ".js": "javascript",
    ".ts": "typescript", ".go": "go", ".rs": "rust", ".c": "c", ".h": "c",
    ".scala": "scala", ".swift": "swift", ".py": "python", ".rb": "ruby",
    ".yml": "yaml", ".yaml": "yaml", ".sh": "shell", ".bash": "shell",
    ".toml": "toml",
}


def lang_for_path(path: str) -> str:
    path = path.lower()
    for ext, lang in _EXT_LANG.items():
        if path.endswith(ext):
            return lang
    return "unknown"


def _strip_comments(text: str, lang: str) -> str:
    # Remove /* ... */ blocks for C-like languages (string-literal-naive; acceptable for a
    # formatting heuristic — a comment edit is cosmetic anyway).
    if lang in _C_LIKE:
        text = re.sub(r"/\*.*?\*/", " ", text, flags=re.DOTALL)
    lc = _LINE_COMMENT.get(lang)
    if lc:
        out = []
        for line in text.split("\n"):
            idx = line.find(lc)
            out.append(line[:idx] if idx != -1 else line)
        text = "\n".join(out)
    return text


# A token is an identifier/number, a string literal, or a single non-space symbol.
_TOKEN_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|[A-Za-z_]\w*|\d+\.?\d*|\S')


def _tokens(text: str, lang: str) -> list[str]:
    """Token stream with formatting churn removed.

    Drops: comments, all whitespace, blank lines, and trailing commas (a comma immediately
    before a closing bracket) — the things ktlint/black/prettier reorder or add/remove without
    semantic effect. Keeps everything else, so any real token change survives.
    """
    text = _strip_comments(text, lang)
    toks = _TOKEN_RE.findall(text)
    # Drop trailing commas: a ',' directly followed by a closing bracket.
    cleaned: list[str] = []
    for i, t in enumerate(toks):
        if t == "," and i + 1 < len(toks) and toks[i + 1] in (")", "]", "}"):
            continue
        cleaned.append(t)
    return cleaned


def classify_text(old: str, new: str, lang: str) -> str:
    """Return 'identical', 'formatting_only', or 'logical'."""
    if old == new:
        return "identical"
    if lang == "unknown":
        # Can't safely normalize → only call it formatting if whitespace-only differs.
        if re.sub(r"\s+", "", old) == re.sub(r"\s+", "", new):
            return "formatting_only"
        return "logical"
    if _tokens(old, lang) == _tokens(new, lang):
        return "formatting_only"
    return "logical"


def classify_file_diff(old: str, new: str, path: str) -> dict:
    lang = lang_for_path(path)
    verdict = classify_text(old, new, lang)
    return {"path": path, "lang": lang, "verdict": verdict}
