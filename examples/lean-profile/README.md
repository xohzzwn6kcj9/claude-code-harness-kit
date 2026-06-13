# Lean profile — for token-capped / Sonnet-only / download-only machines

A minimal way to run this kit where tokens are scarce (e.g. a fixed monthly credit cap, Sonnet-only)
or where you can only pull the public kit (no access to your private dotfiles). You get the full
safety + prompt-reduction value of the hooks without the expensive parts.

## What to install

```
./install.sh --all                                # core hooks + bash-guards + repo-radar
cp examples/lean-profile/CLAUDE.md          ~/.claude/CLAUDE.md           # generic, no personal/prod context
cp examples/lean-profile/settings.local.json ~/.claude/settings.local.json   # model: sonnet
# then merge settings.example.json's hooks block into ~/.claude/settings.json
```

## Token discipline (the point of "lean")

- **Hooks cost nothing** — they're deterministic scripts run by the CLI, not the model. Full value
  on any model/plan.
- **repo-radar SAVES tokens** — one structured call replaces many `git`/`grep`/`gh` shell
  round-trips. Especially worth it on a cap.
- **Avoid multi-agent workflows / large fan-outs** (deep multi-agent review, research swarms,
  "ultra" modes). They multiply token use fast. Prefer single-pass inline review.
- Guard self-correction (a blocked command → the model rewrites it from the hint) works fine on
  Sonnet; the guards fail safe regardless of model.

## What you do NOT get here

No personal/prod-coupled skills, no secrets, no project access — by design. This profile is safe to
run on a machine you don't fully control (e.g. a work laptop): it can only read/inspect, and the
secret guards block credential leaks into the transcript.
