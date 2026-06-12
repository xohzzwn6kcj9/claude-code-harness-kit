#!/bin/bash
# Smoke tests for the standalone guard hooks (bash-guards/* + playwright +
# secret-scan + deny-secret-file-reads). Each guard is exercised with one
# blocking case and one passing case. Runs on bash 3.2; requires jq + python3.
#
#   bash tests/guards.test.sh

set -u
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
H="$ROOT/hooks"
PASS=0; FAIL=0; MSGS=""

note() { PASS=$((PASS+1)); }
err()  { FAIL=$((FAIL+1)); MSGS="$MSGS
  $1"; }

bashp() { jq -cn --arg c "$1" '{tool_name:"Bash",tool_input:{command:$c}}'; }
bashpc(){ jq -cn --arg c "$1" --arg w "$2" '{tool_name:"Bash",cwd:$w,tool_input:{command:$c}}'; }
writep(){ jq -cn --arg p "$1" '{tool_name:"Write",tool_input:{file_path:$p}}'; }
shotp() { jq -cn --arg f "$1" '{tool_name:"mcp__plugin_playwright_playwright__browser_take_screenshot",tool_input:{filename:$f}}'; }

# expect exit 2 (hard block)
blk() { printf '%s' "$2" | bash "$1" >/dev/null 2>&1; [ $? -eq 2 ] && note || err "expected BLOCK: $3"; }
# expect exit 0 with NO stdout (clean pass)
pas() { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); [ $? -eq 0 ] && [ -z "$o" ] && note || err "expected PASS(no output): $3"; }
# expect exit 0 WITH a deny JSON on stdout
den() { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); case "$o" in *'"permissionDecision":"deny"'*) note;; *) err "expected DENY-json: $3";; esac; }
# expect exit 0 and NOT a deny (a non-blocking nudge / additionalContext is fine)
nd()  { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); [ $? -eq 0 ] || { err "expected exit 0: $3"; return; }; case "$o" in *'"permissionDecision":"deny"'*) err "expected NOT-deny: $3";; *) note;; esac; }

G="$H/bash-guards"

blk "$G/brace-expansion-guard.sh" "$(bashp 'grep x /a/{b,c}.py')"      'brace expansion'
pas "$G/brace-expansion-guard.sh" "$(bashp 'grep x /a/b.py /a/c.py')"  'explicit paths'
pas "$G/brace-expansion-guard.sh" "$(bashp 'git commit -m "{a,b}"')"   'braces in quotes'

blk "$G/xargs-procsub-guard.sh"   "$(bashp 'ls | xargs rm')"           'xargs'
blk "$G/xargs-procsub-guard.sh"   "$(bashp 'diff <(ls) <(ls -a)')"     'process sub'
pas "$G/xargs-procsub-guard.sh"   "$(bashp 'for f in a b; do rm $f; done')" 'for loop'
pas "$G/xargs-procsub-guard.sh"   "$(bashp 'echo "use xargs here"')"   'xargs in quotes'

blk "$G/compound-cd-guard.sh"     "$(bashp 'cd src && ls')"            'relative cd compound'
pas "$G/compound-cd-guard.sh"     "$(bashp 'cd /abs/path && ls')"      'absolute cd compound'
pas "$G/compound-cd-guard.sh"     "$(bashp 'cd src')"                  'bare relative cd'

den "$G/grep-tool-guard.sh"       "$(bashp 'grep -rn x --include=*.py .')" 'unquoted include glob'
nd  "$G/grep-tool-guard.sh"       "$(bashp "grep -rn x --include='*.py' .")" 'quoted include glob (nudge ok, not deny)'
pas "$G/grep-tool-guard.sh"       "$(bashp 'cat file.txt')"               'unrelated command'

blk "$G/temp-dir-guard.sh"        "$(writep '/tmp/x.txt')"             'Write into /tmp'
blk "$G/temp-dir-guard.sh"        "$(bashp 'echo hi > /var/tmp/y')"    'redirect into /var/tmp'
pas "$G/temp-dir-guard.sh"        "$(writep '/home/u/proj/x.txt')"     'Write into project'
pas "$G/temp-dir-guard.sh"        "$(bashp 'cat /tmp/someones-artifact')" 'read from /tmp'

blk "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout feature-x' '/home/u/repo')"          'switch existing in main wt'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout main' '/home/u/repo')"               'switch to main'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout -b new-thing' '/home/u/repo')"       'create branch'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout feature-x' '/home/u/repo/.worktree/feature-x')" 'switch inside worktree'

den "$H/playwright-screenshot-guard.sh" "$(shotp 'shot.png')"             'relative screenshot'
pas "$H/playwright-screenshot-guard.sh" "$(shotp '.playwright-mcp/a.png')" 'screenshot in ignored dir'
pas "$H/playwright-screenshot-guard.sh" "$(shotp '/tmp/abs.png')"          'absolute screenshot'

echo "guards — pass: $PASS  fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo "failures:$MSGS"; exit 1; fi
exit 0
