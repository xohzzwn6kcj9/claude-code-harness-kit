#!/usr/bin/env bash
#
# Reusable secret scanner (global, shared across repos).
#
# Scans the ADDED lines of a git range for likely secrets and exits non-zero on a hit,
# so a caller (typically a repo's .githooks/pre-push wrapper) can BLOCK the push. This is
# a deterministic backstop that fires even outside a Claude session (manual `git push`);
# it is complementary to — not a replacement for — the judgement-based `/security-review`.
#
# Usage:
#   secret-scan.sh <git-range>          e.g.  secret-scan.sh origin/main..HEAD
#   secret-scan.sh                      defaults to <upstream>..HEAD, else HEAD~1..HEAD
#
# Detection: uses `gitleaks` when present (authoritative); otherwise falls back to a
# self-contained set of curated regexes over added lines + sensitive-filename checks.
# Lines/files containing an allowlist marker (see ALLOW_RE) are skipped to cut false
# positives on docs, tests, and example placeholders.
#
# Bypass (at the hook level, not here): `git push --no-verify`.

set -euo pipefail

range="${1:-}"
if [ -z "$range" ]; then
    if up="$(git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)"; then
        range="$up..HEAD"
    elif git rev-parse --verify -q HEAD~1 >/dev/null 2>&1; then
        range="HEAD~1..HEAD"
    else
        range="HEAD"
    fi
fi

# Nothing to scan (e.g. range is empty / identical endpoints) → pass.
if ! git rev-parse -q --verify "${range%%..*}" >/dev/null 2>&1 && [ "$range" != "HEAD" ]; then
    exit 0
fi

# Prefer gitleaks when available — it is the authoritative scanner.
if command -v gitleaks >/dev/null 2>&1; then
    if [ "$range" = "HEAD" ]; then
        log_opts="-1"
    else
        log_opts="$range"
    fi
    if gitleaks detect --no-banner --redact --log-opts="$log_opts" 2>/dev/null; then
        exit 0
    else
        echo "secret-scan: gitleaks flagged a potential secret in $range — push blocked." >&2
        echo "            Review the finding above. Bypass once with: git push --no-verify" >&2
        exit 1
    fi
fi

# ---- Fallback: self-contained regex scanner over ADDED lines ------------------------------

# Allowlist markers: skip obvious placeholders / opt-out comments to reduce false positives.
ALLOW_RE='allowlist[ _-]?secret|EXAMPLE|example|dummy|placeholder|your[_-]|changeme|<[A-Za-z_]+>|xxxx+|redacted|REDACTED'

# Curated content rules: "name|regex" (extended regex). Tuned to be specific.
# Add your own provider/broker keys here, e.g.:
#   'MyAPI-secret|my_?secret["[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=]{40,}'
rules=(
    'PrivateKeyBlock|-----BEGIN[ A-Z]*PRIVATE KEY-----'
    'AWS-access-key|AKIA[0-9A-Z]{16}'
    'GitHub-token|gh[pousr]_[A-Za-z0-9]{36,}'
    'Bearer-token|[Bb]earer[[:space:]]+[A-Za-z0-9._-]{24,}'
    'Slack-token|xox[baprs]-[A-Za-z0-9-]{10,}'
    'Google-API-key|AIza[0-9A-Za-z_-]{30,}'
    'App-key-assign|app_?(key|secret)["[:space:]]*[:=][[:space:]]*["'"'"']?[A-Za-z0-9+/=]{30,}'
    'Generic-secret-assign|(api[_-]?key|secret|token|password|passwd|access[_-]?key)["[:space:]]*[:=][[:space:]]*["'"'"'][A-Za-z0-9+/_=.-]{16,}["'"'"']'
)

# Sensitive filenames that should rarely be committed.
FILE_RE='(^|/)\.env($|\.)|(^|/)id_(rsa|dsa|ecdsa|ed25519)$|\.(pem|p12|pfx|keystore|jks)$|(^|/)(credentials|service[_-]?account)[^/]*\.json$'

hits=0

added="$(git diff --no-color "$range" 2>/dev/null | grep -E '^\+' | grep -Ev '^\+\+\+' || true)"
if [ -n "$added" ]; then
    scan="$(printf '%s\n' "$added" | grep -Ev "$ALLOW_RE" || true)"
    for entry in "${rules[@]}"; do
        name="${entry%%|*}"
        re="${entry#*|}"
        match="$(printf '%s\n' "$scan" | grep -En -e "$re" | head -3 || true)"
        if [ -n "$match" ]; then
            hits=1
            echo "secret-scan: [$name] potential secret in added lines:" >&2
            # Redact the bulk of each matched line; keep a short prefix for locating it.
            printf '%s\n' "$match" | sed -E 's/(.{0,24}).*/  \1… [redacted]/' >&2
        fi
    done
fi

changed="$(git diff --name-only "$range" 2>/dev/null || true)"
if [ -n "$changed" ]; then
    badfiles="$(printf '%s\n' "$changed" | grep -E "$FILE_RE" || true)"
    if [ -n "$badfiles" ]; then
        hits=1
        echo "secret-scan: sensitive file(s) staged for push:" >&2
        printf '  - %s\n' $badfiles >&2
    fi
fi

if [ "$hits" -ne 0 ]; then
    echo "secret-scan: push blocked (range: $range)." >&2
    echo "            If this is a false positive, add an allowlist marker or: git push --no-verify" >&2
    exit 1
fi

exit 0
