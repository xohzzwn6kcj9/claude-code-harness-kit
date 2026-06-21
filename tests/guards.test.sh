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
tep()   { jq -cn --arg t "$1" --arg p "$2" '{tool_name:$t,tool_input:{file_path:$p}}'; }
shotp() { jq -cn --arg f "$1" '{tool_name:"mcp__plugin_playwright_playwright__browser_take_screenshot",tool_input:{filename:$f}}'; }

# expect exit 2 (hard block)
blk() { printf '%s' "$2" | bash "$1" >/dev/null 2>&1; [ $? -eq 2 ] && note || err "expected BLOCK: $3"; }
# expect exit 0 with NO stdout (clean pass)
pas() { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); [ $? -eq 0 ] && [ -z "$o" ] && note || err "expected PASS(no output): $3"; }
# expect exit 0 WITH a deny JSON on stdout
den() { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); case "$o" in *'"permissionDecision":"deny"'*) note;; *) err "expected DENY-json: $3";; esac; }
# expect exit 0 and NOT a deny (a non-blocking nudge / additionalContext is fine)
nd()  { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); [ $? -eq 0 ] || { err "expected exit 0: $3"; return; }; case "$o" in *'"permissionDecision":"deny"'*) err "expected NOT-deny: $3";; *) note;; esac; }
# expect exit 0 WITH an allow JSON on stdout (an approver hook, e.g. approve-tmp-rm)
alw() { local o; o=$(printf '%s' "$2" | bash "$1" 2>/dev/null); case "$o" in *'"permissionDecision":"allow"'*) note;; *) err "expected ALLOW-json: $3";; esac; }

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

A="$G/approve-tmp-rm.sh"
alw "$A" "$(bashp '/bin/rm -f ~/tmp/written-body.txt ~/tmp/source-body.txt')" 'rm files under ~/tmp'
alw "$A" "$(bashp 'rm ~/tmp/a.txt')"                  'bare rm of a ~/tmp file'
alw "$A" "$(bashp 'rm -f ~/tmp/scratch/build.log')"   'rm nested ~/tmp file'
pas "$A" "$(bashp 'rm -rf ~/tmp/dir')"                'recursive removal defers'
pas "$A" "$(bashp 'rm -f ~/tmp/a.txt /etc/passwd')"   'mixed target defers'
pas "$A" "$(bashp 'rm -f ~/tmp/../secret')"           'traversal defers'
pas "$A" "$(bashp 'rm -f ~/tmp/a && echo done')"      'compound defers'
pas "$A" "$(bashp 'rm -f /etc/passwd')"               'outside ~/tmp defers'
pas "$A" "$(bashp 'rm ~/tmp/')"                       'bare ~/tmp/ (trailing slash, empty subpath) defers'
pas "$A" "$(bashp 'rm ~/tmp')"                        'bare ~/tmp (no subpath) defers'
pas "$A" "$(bashp 'HOME=/etc rm ~/tmp/x')"            'leading env-prefix (HOME=) defers'
pas "$A" "$(bashp 'cat ~/tmp/a.txt')"                 'non-rm command defers'

blk "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout feature-x' '/home/u/repo')"          'switch existing in main wt'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout main' '/home/u/repo')"               'switch to main'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout -b new-thing' '/home/u/repo')"       'create branch'
pas "$G/git-branch-switch-guard.sh" "$(bashpc 'git checkout feature-x' '/home/u/repo/.worktree/feature-x')" 'switch inside worktree'

den "$H/playwright-screenshot-guard.sh" "$(shotp 'shot.png')"             'relative screenshot'
pas "$H/playwright-screenshot-guard.sh" "$(shotp '.playwright-mcp/a.png')" 'screenshot in ignored dir'
pas "$H/playwright-screenshot-guard.sh" "$(shotp '/tmp/abs.png')"          'absolute screenshot'

# bare-interpreter-guard: block an absolute interpreter path identical to `command -v <name>`.
# Every block-case is built from $(command -v python3) so it equals PATH resolution by
# construction; pass-cases use paths that provably differ. Skips if python3 is absent.
BI="$G/bare-interpreter-guard.sh"
P="$(command -v python3 2>/dev/null)"
if [ -n "$P" ]; then
  blk "$BI" "$(bashp "$P -m venv $HOME/tmp/x")"                        'abs python3 at start'
  blk "$BI" "$(bashp "echo hi ; $P -m pytest -q")"                     'abs python3 after ;'
  blk "$BI" "$(bashp "true && $P -V")"                                 'abs python3 after &&'
  blk "$BI" "$(bashp "$P -m venv $HOME/tmp/x 2>&1 | tail -2")"         'abs python3 then pipe-tail'
  blk "$BI" "$(bashp "python3 -m venv x && $P -m pip install pytest")" 'compound 2nd seg abs'
  pas "$BI" "$(bashp 'python3 -m pytest -q')"                          'bare python3 (no abs token)'
  pas "$BI" "$(bashp "${P}.13 -c 'import sys'")"                       'version-pinned python3.13'
  pas "$BI" "$(bashp "$HOME/tmp/venv/bin/python -m pytest")"           'venv path != command -v'
  pas "$BI" "$(bashp "ls -l $P")"                                      'abs path as argument'
  pas "$BI" "$(bashp "git commit -m \"ran $P\"")"                      'abs path inside quotes'
  pas "$BI" "$(bashp '/usr/bin/env python3 -V')"                       'env wrapper (basename not in set)'
  if [ "$P" != "/usr/bin/python3" ] && [ -e /usr/bin/python3 ]; then
    pas "$BI" "$(bashp "/usr/bin/python3 -c 'import sys'")"            'system python3 distinct interpreter'
  fi
  o=$(printf '' | bash "$BI" 2>/dev/null); [ $? -eq 0 ] && note || err 'bare-interpreter empty input fail-open'
else
  echo "skip: bare-interpreter-guard (python3 not on PATH)"
fi

# approve-test-run: APPROVE a safely-shaped `bash <script>.test.sh` (+ read-only pipe);
# DEFER every smuggle vector (bash -c / env-prefix / write segment / redirect / non-.test.sh).
T="$G/approve-test-run.sh"
alw "$T" "$(bashp 'bash tests/x.test.sh')"                                'approve: bare relative .test.sh'
alw "$T" "$(bashp 'bash /u/.claude/hooks/tests/x.test.sh')"              'approve: absolute path'
alw "$T" "$(bashp 'bash -- x.test.sh')"                                  'approve: -- then script'
alw "$T" "$(bashp 'bash x.test.sh --tail 5')"                            'approve: positional args after script'
alw "$T" "$(bashp 'bash x.test.sh | tail -3')"                          'approve: pipe to readonly tail'
alw "$T" "$(bashp 'bash tests/x.test.sh | tail -3 ; jq . s.json')"       'approve: pipe + ; jq'
pas "$T" "$(bashp "bash -c 'rm -rf ~' x.test.sh")"                       'defer: bash -c payload (exploit)'
pas "$T" "$(bashp 'BASH_ENV=~/tmp/evil.sh bash x.test.sh')"             'defer: BASH_ENV env-prefix (exploit)'
pas "$T" "$(bashp 'FOO=1 bash x.test.sh')"                              'defer: any leading env assignment'
pas "$T" "$(bashp 'bash -s x.test.sh')"                                 'defer: bash -s option'
pas "$T" "$(bashp 'bash x.test.sh ; rm -rf /tmp/x')"                    'defer: ; rm write segment'
pas "$T" "$(bashp 'bash x.test.sh && echo done')"                       'defer: && chain'
pas "$T" "$(bashp 'bash x.test.sh > out.txt')"                          'defer: redirect out'
pas "$T" "$(bashp 'bash x.test.sh | sh')"                              'defer: pipe to non-readonly'
pas "$T" "$(bashp 'bash $(echo x).test.sh')"                           'defer: command substitution'
pas "$T" "$(bashp 'bash deploy.sh')"                                   'defer: not a .test.sh'
pas "$T" "$(bashp 'bash')"                                             'defer: bash with no script'
pas "$T" "$(bashp 'tail -3 settings.json')"                            'defer: readonly-only (no test run)'
pas "$T" "$(writep '/x/y.test.sh')"                                    'defer: non-Bash tool'
o=$(printf '' | bash "$T" 2>/dev/null); [ $? -eq 0 ] && [ -z "$o" ] && note || err 'approve-test-run empty input fail-open'

# enforce-test-location: BLOCK a *.test.sh written outside a tests/ dir INSIDE ~/.claude;
# PASS inside tests/, ~/tmp, other projects, and non-(*.test.sh) files. Edit is gated too.
E="$G/enforce-test-location.sh"
blk "$E" "$(tep Write "$HOME/.claude/hooks/x.test.sh")"                  'block: harness root, no tests/'
blk "$E" "$(tep Write "$HOME/.claude/skills/foo/scripts/x.test.sh")"     'block: skill scripts dir'
blk "$E" "$(tep Edit  "$HOME/.claude/hooks/x.test.sh")"                  'block: Edit also gated'
pas "$E" "$(tep Write "$HOME/.claude/hooks/tests/x.test.sh")"            'pass: hooks/tests/'
pas "$E" "$(tep Write "$HOME/.claude/skills/foo/tests/x.test.sh")"       'pass: skill foo/tests/'
pas "$E" "$(tep Write "$HOME/.claude/.worktree/feat/hooks/tests/x.test.sh")" 'pass: worktree tests/'
pas "$E" "$(tep Edit  "$HOME/.claude/hooks/tests/x.test.sh")"            'pass: Edit valid test in tests/'
pas "$E" "$(tep Write "$HOME/tmp/x.test.sh")"                           'pass: ~/tmp abs exempt'
pas "$E" "$(tep Write '~/tmp/x.test.sh')"                              'pass: ~/tmp literal tilde exempt'
pas "$E" "$(tep Write "$HOME/workspace/proj/x.test.sh")"               'pass: other project not gated'
pas "$E" "$(tep Write "$HOME/workspace/proj/src/tests/x.test.sh")"     'pass: other project has tests/'
pas "$E" "$(tep Write "$HOME/.claude/hooks/foo.sh")"                   'pass: plain .sh ignored'
pas "$E" "$(tep Write "$HOME/.claude/skills/foo/scripts/test_foo.py")" 'pass: python test ignored'
pas "$E" "$(tep Bash  "$HOME/.claude/hooks/x.test.sh")"               'pass: non Write|Edit tool defers'
o=$(printf '' | bash "$E" 2>/dev/null); [ $? -eq 0 ] && note || err 'enforce-test-location empty input fail-open'

# approve-worktree-skill: APPROVE a clean worktree.sh subcommand (bare or with an allowlisted,
# no-space env prefix); DEFER every smuggle/bypass vector. Uses both the literal ~ form
# (machine-independent) and a $HOME-absolute form (the hook expands $HOME at runtime, so CI matches).
W="$G/approve-worktree-skill.sh"
WT='~/.claude/skills/worktree/scripts/worktree.sh'
WTA="$HOME/.claude/skills/worktree/scripts/worktree.sh"
alw "$W" "$(bashp "bash $WT pr foo")"                                    'approve: bare worktree.sh pr'
alw "$W" "$(bashp "bash $WTA pr foo")"                                   'approve: $HOME-absolute path'
alw "$W" "$(bashp "bash $WT create foo")"                                'approve: create'
alw "$W" "$(bashp "bash $WT sync foo")"                                  'approve: sync'
alw "$W" "$(bashp "bash $WT push foo")"                                  'approve: push (kit-added subcmd)'
alw "$W" "$(bashp "bash $WT cleanup foo")"                               'approve: cleanup'
alw "$W" "$(bashp "WORKTREE_SKIP_TESTS=1 bash $WT pr foo")"              'approve: WORKTREE_SKIP_TESTS prefix stripped'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=mytests bash $WT push foo")"        'defer: WORKTREE_TEST_CMD is an eval sink (not allowlisted)'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=reboot bash $WT push foo")"         'defer: single-token eval-sink value'
pas "$W" "$(bashp "WORKTREE_TEST_CMD='bash tests/run.sh' bash $WT push foo")" 'defer: quoted multi-word value (helper limitation, fail-safe)'
pas "$W" "$(bashp "BASH_ENV=~/tmp/evil.sh bash $WT pr foo")"            'defer: dangerous BASH_ENV prefix NOT stripped'
pas "$W" "$(bashp "WORKTREE_SKIP_TESTS_EVIL=1 bash $WT pr foo")"        'defer: unanchored env name'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=\$(curl x|sh) bash $WT pr foo")"   'defer: command-substitution value'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=x|sh bash $WT push foo")"          'defer: pipe metachar in env value (dual-parser)'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=x;rm bash $WT push foo")"          'defer: semicolon metachar in env value'
pas "$W" "$(bashp "WORKTREE_SKIP_TESTS=1;rm bash $WT pr foo")"          'defer: semicolon after allowlisted value'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=x&&rm bash $WT push foo")"         'defer: && metachar in env value'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=x>~/.bashrc bash $WT push foo")"   'defer: redirect metachar in env value'
pas "$W" "$(bashp "WORKTREE_TEST_CMD=x<f bash $WT push foo")"           'defer: input-redirect metachar in env value'
pas "$W" "$(bashp "bash $WT pr *")"                                     'defer: glob in args (shell expands the ORIGINAL)'
pas "$W" "$(bashp "bash $WT pr foo{x}")"                                'defer: brace char in args (single-elem avoids test-time expansion)'
pas "$W" "$(bashp "bash $WT nuke foo")"                                 'defer: unknown subcommand'
pas "$W" "$(bashp "bash $WT")"                                          'defer: bare worktree.sh, no subcommand'
pas "$W" "$(bashp "bash $WT prune foo")"                                'defer: pr-prefix but not the pr subcommand'
pas "$W" "$(bashp "bash $WT pr foo | tail -3")"                         'defer: compound pipe'
pas "$W" "$(bashp "bash $WT pr foo ; rm -rf ~")"                        'defer: ; write segment'
pas "$W" "$(bashp "bash /tmp/worktree.sh pr foo")"                      'defer: non-skill path'
pas "$W" "$(writep '/x/y')"                                            'defer: non-Bash tool'
o=$(printf '' | bash "$W" 2>/dev/null); [ $? -eq 0 ] && [ -z "$o" ] && note || err 'approve-worktree-skill empty input fail-open'

echo "guards — pass: $PASS  fail: $FAIL"
if [ "$FAIL" -gt 0 ]; then echo "failures:$MSGS"; exit 1; fi
exit 0
