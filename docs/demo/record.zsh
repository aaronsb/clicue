#!/usr/bin/env zsh
# The demo driver: a sandboxed clicue shell, choreographed keystrokes,
# output relayed live so asciinema records it with real timing. Invoked
# by `make demo` inside `asciinema rec -c …`; runs nowhere near the
# operator's daemon, corpus, or config (the e2e harness sandbox).
source "${0:a:h}/../../tests/harness.zsh"

T_SEED_HISTORY=(
  'git status'
  'git log --oneline -15'
  'git checkout main'
  'git commit -m "the usual"'
  'git rebase -i HEAD~3'
  'git push -u origin main'
  'docker ps -a'
  'docker compose up -d'
  'tar -xzf release.tgz'
  'tar -czf backup.tgz notes/'
  'ffmpeg -i in.mp4 out.mkv'
  'rg --hidden TODO'
)

# Human-ish typing: per-key delay with a little jitter.
say() {
  local -i i
  for (( i = 1; i <= ${#1}; i++ )); do
    pty_key "${1[i]}"
    pty_drain $(( 0.06 + RANDOM % 70 / 1000.0 ))
  done
}
beat() { pty_drain $1 }

pty_start demo
# Echo ON only after boot: pty_start's integrity probe and the compinit
# chatter are harness plumbing, not demo material (review #14 caught the
# probe — local paths included — opening the published cast).
T_ECHO=1
# The boot drain above ate the shell's first prompt paint, so without a
# repaint the recording opens on a bare line and the first keystrokes
# echo un-prompted ('gi' stranded at column 1, visible in the published
# gif). ^L repaints the prompt at the top before any typing.
pty_key $'\x0c'; beat 0.5

# ── act 1: command cards from your own history ─────────────────────────
say 'git '
beat 1.6
say 'c'
beat 1.4
pty_key $'\x15'; beat 0.6            # ^U — clear the line

# ── act 2: Tab harvests a command's documented flags ───────────────────
say 'tar -'
beat 0.8
pty_key $'\t'                        # harvest + card
beat 2.0
pty_key $'\t'; beat 0.7              # cycle
pty_key $'\t'; beat 0.9
pty_key $'\e'                        # Esc — dismiss
beat 0.6
pty_key $'\x15'; beat 0.5

# ── act 3: arrows walk tier 1 into the grid ────────────────────────────
say 'ffmpeg -'
beat 0.8
pty_key $'\t'
beat 2.2
local -i i
for (( i = 1; i <= 14; i++ )); do
  pty_key $'\e[B'
  beat 0.22
done
beat 1.2
pty_key $'\e'; beat 0.5
pty_key $'\x15'; beat 0.5

# ── act 4: clicue explains itself, then changes its own clothes ────────
say 'clicue '
beat 0.6
pty_key $'\t'
beat 2.0
pty_key $'\x03'; beat 0.5
say 'clicue theme list'
pty_key $'\r'
beat 3.0                             # twenty swatches, tier labels included
# Costume parade: the same card re-dressed live — synthwave's sunset
# gradient running into shade ramps, halloween's pumpkin/bat corners
# (ADR-400 ramps), petscii's C64 boot screen with its ▀/▄ split rule.
for costume in synthwave halloween petscii; do
  say "clicue config set theme $costume"
  pty_key $'\r'
  beat 1.4                           # daemon hot-reloads within a second
  say 'git '
  beat 2.4                           # the same card, recolored live
  pty_key $'\x03'; beat 0.4
done
say ' exit'
pty_key $'\r'
beat 0.4

t_done
