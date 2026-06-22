#!/bin/bash
# auto-approve-readonly.sh — Claude Code PreToolUse hook
#
# Auto-approves tool calls that are provably read-only, so they never stop you
# with a permission prompt. Everything else is left untouched and falls through
# to the normal permission flow (settings allow/deny rules, then the prompt).
#
# This hook NEVER blocks anything. Its only two outcomes are:
#   approve : print {"hookSpecificOutput":{"permissionDecision":"allow",...}}, exit 0
#   defer   : exit 0 with no output  -> normal permission flow decides
#
# Design rule: when in doubt, defer. A false negative costs you one prompt;
# a false positive silently runs something with side effects.
#
# Requirements: bash 3.2+, jq, perl (all present on stock macOS; standard on Linux).
# If jq or perl is missing the hook fails open (defers everything, approves nothing).

set -uo pipefail

# ---------------------------------------------------------------------------
# Configuration — extend via environment or edit the defaults below.
# Every list is a single space-separated string.
# ---------------------------------------------------------------------------

# Commands that may appear as ANY segment of a shell command line (simple
# command, pipe segment, &&/||/; member, loop body, $(...) assignment body).
# Only include commands that cannot write files or mutate state through their
# arguments alone. Commands with dangerous flag-forms (git, gh, sort, find,
# docker, command, hash, ...) are listed here AND additionally flag-vetted below in the perl
# checker — adding a name here is not enough to skip that vetting.
#
# Deliberately NOT included by default (add at your own risk):
#   sed/awk/perl/python3/node/ruby : quoted program text can write files or
#                                    run system() — invisible to this checker
#   curl/wget                      : can POST and write files (-o, -O)
#   tee/xargs/eval/exec/sudo/env -i cmd : obvious escapes
#   xxd/base64                     : write files via -o / second positional arg
AAR_SAFE_CMDS=${AAR_SAFE_CMDS:-"cat ls fd find grep rg head tail wc tree pwd \
echo which file stat du df uname sw_vers whoami id groups date env printenv ps \
sort uniq nl tac rev strings cmp diff comm tr cut column fold jq yq realpath \
readlink dirname basename hostname uptime printf type test true false less more \
od hexdump cksum shasum sha256sum md5 md5sum locale getconf cd git gh gradlew \
docker kubectl command hash"}

# Commands allowed as the target of `find ... -exec/-execdir <cmd> ... ;`
AAR_FIND_EXEC_SAFE=${AAR_FIND_EXEC_SAFE:-"cat grep egrep fgrep rg head tail wc \
file stat basename dirname realpath readlink md5 md5sum shasum sha256sum od \
hexdump strings test echo printf ls"}

# git subcommands that are read-only with any flags/args.
# branch/tag/remote/stash/worktree/config/reflog are handled specially in the
# checker (their argument forms can create or delete things).
AAR_GIT_SUBCMDS=${AAR_GIT_SUBCMDS:-"status log diff show shortlog blame grep \
rev-parse describe name-rev ls-files ls-tree ls-remote reflog cat-file \
merge-base cherry count-objects whatchanged range-diff rev-list show-ref \
show-branch diff-tree var help version"}

# Filename patterns (lowercased basename) treated as secret-bearing: the Read
# tool is NOT auto-approved for them (it defers to the normal prompt).
# Pair this with hooks/deny-secret-file-reads.sh for a hard block.
is_secretish_path() {
  local base
  base=$(basename "$1" 2>/dev/null | tr '[:upper:]' '[:lower:]') || return 1
  case "$base" in
    *.env.example|*.env.sample|*.env.template|*.env.dist|env.example) return 1 ;;
    .env|.env.*|*.env|*credential*|*secret*|*.pem|*.key|*.p12|*.pfx|\
    id_rsa*|id_ed25519*|id_ecdsa*|.netrc|.npmrc|.pgpass|*.keystore|*.jks)
      return 0 ;;
  esac
  return 1
}

# ---------------------------------------------------------------------------

approve() {
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' \
    "${1:-auto-approved as read-only}"
  exit 0
}

command -v jq >/dev/null 2>&1 || exit 0   # fail open: no jq -> defer everything

INPUT=$(cat)
TOOL_NAME=$(printf '%s' "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null) || exit 0
[ -n "$TOOL_NAME" ] || exit 0

# ---------------------------------------------------------------------------
# 1. Built-in read-only tools
# ---------------------------------------------------------------------------
case "$TOOL_NAME" in
  Read)
    FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
    if [ -n "$FILE_PATH" ] && is_secretish_path "$FILE_PATH"; then
      exit 0   # secret-bearing file -> let the normal permission flow decide
    fi
    approve "Read is read-only"
    ;;
  Glob|Grep|NotebookRead)
    approve "read-only tool"
    ;;
  WebFetch|WebSearch)
    # Read-only from the local machine's point of view. Note: fetching a URL
    # does send the URL (and query params) to an external server — remove
    # these two lines if that matters for your threat model.
    approve "read-only web access"
    ;;
esac

# ---------------------------------------------------------------------------
# 2. MCP read-only tools (extend with your own servers' read-only tools)
#    Tool names look like mcp__<server>__<tool>; plugin-provided servers use
#    mcp__plugin_<plugin>_<server>__<tool>. We match on the trailing tool name.
# ---------------------------------------------------------------------------
MCP_ACTION="${TOOL_NAME##*__}"

case "$TOOL_NAME" in
  mcp__*playwright*__*)
    # Browser observation only. Interaction tools (click/type/evaluate/...)
    # deliberately still prompt: a click can submit a form with side effects.
    # browser_navigate issues GET requests — drop it below if that is already
    # too much for your threat model.
    case "$MCP_ACTION" in
      browser_snapshot|browser_console_messages|browser_network_requests|\
      browser_tabs|browser_take_screenshot|browser_navigate|\
      browser_navigate_back|browser_wait_for|browser_resize|browser_close)
        approve "read-only browser observation"
        ;;
    esac
    exit 0
    ;;
  mcp__serena__*)
    case "$MCP_ACTION" in
      find_symbol|get_symbols_overview|find_referencing_symbols|\
      search_for_pattern|list_dir|find_file|read_memory|list_memories|\
      check_onboarding_performed)
        approve "read-only code navigation"
        ;;
    esac
    exit 0
    ;;
esac

# ---------------------------------------------------------------------------
# 3. Bash — deep-vet the command line; approve only if EVERY command in it
#    (pipe segments, &&/||/; members, loop bodies, $() assignment bodies)
#    is in the read-only set and passes per-command flag vetting.
# ---------------------------------------------------------------------------
if [ "$TOOL_NAME" != "Bash" ]; then
  exit 0
fi
command -v perl >/dev/null 2>&1 || exit 0  # fail open

COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
[ -n "$COMMAND" ] || exit 0

# The checker is written without single-quote characters so it can live in a
# single-quoted shell string; \x27 stands for a single quote inside regexes.
PERL_VET='
my $cmd = do { local $/; <STDIN> };
exit 1 unless defined $cmd && length $cmd;

$cmd =~ s/\\\n/ /g;                       # join line continuations
$cmd =~ s/^\s*#[^\n]*$//mg;               # drop full-line comments

# Single-quoted strings are literal in shell -> blank them out.
$cmd =~ s/\x27[^\x27]*\x27/ /gs;

# Backticks execute even inside double quotes -> defer.
exit 1 if $cmd =~ /`/;

# Arithmetic expansion $(( ... )) is inert -> blank it.
$cmd =~ s/\$\(\([^()]*\)\)/0/g;

# Command substitution inside double quotes still executes -> defer.
while ($cmd =~ /"((?:[^"\\]|\\.)*)"/gs) {
  exit 1 if $1 =~ /\$\(/;
}
# Now double-quoted strings are inert -> blank them.
$cmd =~ s/"(?:[^"\\]|\\.)*"/ /gs;

# Heredocs and process substitution are too hairy to vet -> defer.
exit 1 if $cmd =~ /<</;
exit 1 if $cmd =~ /[<>]\(/;

# Command substitution is only auto-approvable in assignment position,
# v=$(...) — its body is then vetted as a segment below. Anywhere else the
# captured output can become a command name or smuggle flags into a safe
# command (sort $(echo -o evil)) -> defer.
while ($cmd =~ /(.?)\$\(/gs) {
  exit 1 unless defined $1 && $1 eq "=";
}

# Redirections: blank the harmless ones, refuse anything else that writes.
$cmd =~ s/\d*>>?&\d+//g;                  # 2>&1  >&2  1>&2
$cmd =~ s/[&\d]*>>?\s*\/dev\/null//g;     # >/dev/null 2>/dev/null &>/dev/null
exit 1 if $cmd =~ />/;                    # any remaining > can write a file
$cmd =~ s/<\s*[^\s<>;|&()]+/ /g;          # plain "< file" input is read-only
                                          # (stop at separators so "< f;rm x"
                                          #  cannot swallow the ; and merge the
                                          #  next command into this segment)

# Split into command segments. ; | & newline and $( each start a new command
# (& covers both && and background &; | covers both || and pipes).
my @segs = split /[;|&\n]+|\$\(/, $cmd;

my %safe     = map { $_ => 1 } split /\s+/, ($ENV{AAR_SAFE_CMDS}      // "");
my %execsafe = map { $_ => 1 } split /\s+/, ($ENV{AAR_FIND_EXEC_SAFE} // "");
my %gitsub   = map { $_ => 1 } split /\s+/, ($ENV{AAR_GIT_SUBCMDS}    // "");

my %kw      = map { $_ => 1 } qw(do done then else elif fi esac time if while until);
my %skipall = map { $_ => 1 } qw(for select case in function read break continue shift return local declare);

for my $seg (@segs) {
  $seg =~ s/[(){}]/ /g;                   # grouping chars left from splits
  $seg =~ s/^[\s!]+//;
  1 while $seg =~ s/^[A-Za-z_]\w*=\S*\s+//;   # leading VAR=val assignments
  $seg =~ s/^[A-Za-z_]\w*=\S*\s*$//;          # bare-assignment segment
  $seg =~ s/^\s+//;
  next unless length $seg;
  next if $seg =~ /^#/;                   # comment residue
  next if $seg =~ /^-/;                   # flag fragment of a wrapped line

  my @t = split /\s+/, $seg;

  # Peel leading shell keywords (do/then/if/...) to reach the real command;
  # for/case/read introduce data words, not commands -> skip the segment.
  while (@t) {
    if ($skipall{$t[0]}) { @t = (); last }
    last unless $kw{$t[0]};
    shift @t;
  }
  next unless @t;
  my $first = shift @t;
  next unless length $first;
  $first =~ s|.*/||;                      # ./gradlew -> gradlew
  if ($first eq "[" || $first eq "[[" || $first eq ":") { next }

  exit 1 unless $safe{$first};

  # ---- per-command flag vetting: safe names with unsafe argument forms ----
  if ($first eq "git") {
    while (@t && $t[0] =~ /^-/) {
      my $f = shift @t;
      shift @t if $f eq "-C" || $f eq "-c";   # flags that consume an argument
    }
    my $sub = shift(@t) // "";
    if ($sub =~ /^(branch|tag|remote)$/) {
      exit 1 if grep { !/^-/ } @t;            # a non-flag arg can create/delete
    } elsif ($sub eq "stash" || $sub eq "worktree") {
      exit 1 unless @t && $t[0] eq "list";
    } elsif ($sub eq "config") {
      exit 1 unless @t && ($t[0] eq "--get" || $t[0] eq "--list" || $t[0] eq "-l");
    } elsif ($sub eq "reflog") {
      exit 1 if @t && $t[0] !~ /^-/ && $t[0] ne "show";   # reflog expire/delete
    } else {
      exit 1 unless $gitsub{$sub};
    }
  }
  elsif ($first eq "gh") {
    my $noun = shift(@t) // "";
    my $verb = shift(@t) // "";
    if    ($noun eq "auth")                        { exit 1 unless $verb eq "status"; }
    elsif ($noun eq "status" || $noun eq "search") { }
    elsif ($noun =~ /^(pr|issue|run|repo|release|workflow|gist|label|cache|ruleset)$/) {
      exit 1 unless $verb =~ /^(list|view|status|diff|checks)$/;
    }
    else { exit 1; }                              # api/alias/everything else
  }
  elsif ($first eq "find") {
    exit 1 if $seg =~ /(^|\s)-(delete|fprint0?|fprintf|fls|ok|okdir)(\s|$)/;
    while ($seg =~ /(?:^|\s)-exec(?:dir)?\s+(\S+)/g) {
      my $c = $1; $c =~ s|.*/||;
      exit 1 unless $execsafe{$c};
    }
  }
  elsif ($first eq "sort")  { exit 1 if grep { /^-o/ || /^--output/ } @t; }
  elsif ($first eq "tree")  { exit 1 if grep { /^-o/ } @t; }
  elsif ($first eq "date")  { exit 1 if grep { /^-s/ || /^--set/ } @t; }
  elsif ($first eq "uniq")  { exit 1 if grep { !/^-/ } @t; }   # 2nd file arg = output
  elsif ($first eq "env")   { exit 1 if grep { !/^-/ && !/^[A-Za-z_]\w*=/ } @t; }
  elsif ($first eq "sed" || $first eq "gsed") {
    exit 1 if grep { /^-[a-zA-Z]*i/ || /^--in-place/ } @t;     # not in defaults; vetted if you add it
  }
  elsif ($first eq "gradlew") {
    my $task = shift(@t) // "";
    exit 1 unless $task =~ /^(tasks|projects|properties|dependencies|help|--version|-v)$/;
  }
  elsif ($first eq "docker") {
    my $sub = shift(@t) // "";
    exit 1 unless $sub =~ /^(ps|images|inspect|logs|version|info|stats|top|port|diff|context)$/;
    if ($sub eq "context") { exit 1 unless @t && ($t[0] eq "ls" || $t[0] eq "inspect" || $t[0] eq "show"); }
  }
  elsif ($first eq "kubectl") {
    my $sub = shift(@t) // "";
    exit 1 unless $sub =~ /^(get|describe|logs|explain|version|api-resources|api-versions|top|diff)$/;
  }
  elsif ($first eq "command") {
    # `command -v NAME...` / `command -V NAME...` only RESOLVE names on PATH,
    # they never execute NAME -> read-only like which/type. Every other form
    # (`command NAME args`, `command -p NAME args`) EXECUTES NAME -> defer.
    exit 1 unless @t && ($t[0] eq "-v" || $t[0] eq "-V");
  }
  elsif ($first eq "hash") {
    # `hash -t NAME...` queries the hash table; bare `hash` prints it. Both are
    # read-only. `hash -r/-p/-d/-l` mutate the table and `hash NAME` forces a
    # lookup -> defer.
    my $f = $t[0] // "";
    if    ($f eq "")   { exit 1 if @t; }   # bare hash ok; hash NAME defers
    elsif ($f eq "-t") { }                 # hash -t NAME... ok
    else               { exit 1; }         # -r/-p/-d/-l/anything else
  }
}
exit 0;
'

if printf '%s' "$COMMAND" | \
   AAR_SAFE_CMDS="$AAR_SAFE_CMDS" \
   AAR_FIND_EXEC_SAFE="$AAR_FIND_EXEC_SAFE" \
   AAR_GIT_SUBCMDS="$AAR_GIT_SUBCMDS" \
   perl -0777 -e "$PERL_VET" 2>/dev/null; then
  approve "every command in the chain is read-only"
fi

exit 0
