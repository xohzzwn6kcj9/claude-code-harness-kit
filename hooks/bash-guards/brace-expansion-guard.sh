#!/usr/bin/env bash
# PreToolUse(Bash) guard — deny brace expansion {a,b} / {1..n} in Bash tool commands.
#
# Why: the permission matcher cannot statically resolve brace expansion, so NO allow
# rule (e.g. Bash(grep:*)) auto-approves such a command — the harness raises its
# "Brace expansion" human prompt and an unattended /loop tick silently stalls
# (same failure class as the relative-cd guard). Deny + corrective message instead,
# so the model rewrites to explicit paths (which DO auto-approve).
#
# Detection (perl over the WHOLE command — adversarial-review hardened, 2026-06-07):
#   1. drop heredoc BODIES only (marker line kept, lines after the terminator kept) —
#      braces in heredoc data are not expansion; code after the terminator still is.
#      <<< here-strings / $((1<<8)) / "<<" in prose never truncate: removal requires
#      a real terminator line.
#   2. strip quoted strings ACROSS newlines (multi-line commit/PR/message bodies
#      containing literal {a,b} stay quiet — sq strip uses \x27 to avoid quote-dance).
#   3. peel comma-less dot-less {x} groups so nested {a{x}y,b} is still caught;
#      also neutralizes find -exec {} placeholders and ${VAR} expansions.
#   4. match an unquoted, un-escaped, non-${ brace group carrying `,` or `..`.
# Fails OPEN: any parse/dep error exits 0 (never blocks the user's command).

input=$(cat)

cmd=$(printf '%s' "$input" | python3 -c 'import sys, json; print(json.load(sys.stdin).get("tool_input", {}).get("command", ""))' 2>/dev/null) || exit 0
[ -z "$cmd" ] && exit 0

if printf '%s' "$cmd" | perl -0777 -e '
  my $c = <STDIN>;
  $c =~ s/(<<(?!<)-?[ \t]*(["\x27]?)(\w+)\2[^\n]*\n)(?:[^\n]*\n)*?[ \t]*\3[ \t]*(?=\n|$)/$1/g;
  $c =~ s/"(?:[^"\\]|\\.)*"//gs;
  $c =~ s/\x27[^\x27]*\x27//gs;
  1 while $c =~ s/\{[^{},.]*\}//;
  exit($c =~ /(^|[^\$\\])\{[^{}]*(?:,|\.\.)[^{}]*\}/ ? 0 : 1);
' 2>/dev/null; then
  echo 'BLOCKED: Do not use brace expansion {a,b} / {1..n} — the permission matcher cannot statically resolve it, so no allow rule auto-approves and the command stalls on a human approval prompt (kills unattended /loop ticks). List paths explicitly (grep ... /path/A.py /path/B.py) or use the Grep/Read tools; use seq for numeric ranges.' >&2
  exit 2
fi

exit 0
