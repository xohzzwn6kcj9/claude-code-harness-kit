# classify heuristics (formatting-only vs logical)

Used by `compare classify` and `git mergecheck`. **Heuristic, not a parser — advisory.** Bias
is toward safety: when it cannot prove a change is cosmetic, it returns `logical` so a human
still reviews.

## How it decides

1. Strip comments (line + `/* */` block for C-like langs).
2. Tokenize into identifiers / numbers / string literals / single symbols.
3. Drop **trailing commas** (a `,` immediately before `)`, `]`, `}`).
4. Discard all whitespace and blank lines (tokens carry no spacing).
5. Compare the two token streams. Equal ⇒ `formatting_only`; otherwise ⇒ `logical`.

So these are treated as **formatting-only** (what ktlint / black / prettier / gofmt churn):
re-indentation, line wrapping/joining, blank-line changes, trailing-comma add/remove,
comment edits, and `import` reordering (token set unchanged in order only if the linter keeps
them contiguous — note caveat below).

These are **logical** (any survives normalization): renamed identifier, changed literal/number,
added/removed argument or call, changed operator, added/removed statement, changed string
content.

## Known limitations (why it's advisory)

- **Import reordering** that changes token *order* (not just whitespace) will read as `logical`
  even though it's cosmetic. Verify import-only diffs by eye.
- Comment stripping is string-literal-naive (a `//` inside a string is treated as a comment).
  Acceptable because a change confined to a comment is cosmetic anyway.
- `unknown` language (unmapped extension) falls back to **whitespace-only** comparison — any
  non-whitespace change is `logical`.
- Moving code between files, or large block reorders, are not understood — treated as `logical`.

## Languages with comment/token awareness

Kotlin, Java, JS/TS, Go, Rust, C, Scala, Swift (`//` + `/* */`); Python, Ruby, YAML, shell,
TOML (`#`). Others → whitespace-only fallback. Add extensions in `classify.py` `_EXT_LANG`.
