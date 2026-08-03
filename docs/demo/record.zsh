#!/usr/bin/env zsh
# The demo driver: a sandboxed clicue shell, choreographed keystrokes,
# output relayed live so asciinema records it with real timing. Invoked
# by `make demo` inside `asciinema rec -c …`; runs nowhere near the
# operator's daemon, corpus, or config (the e2e harness sandbox).
source "${0:a:h}/../../tests/harness.zsh"

T_ECHO=1
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
beat 2.6
say 'clicue config set theme dracula'
pty_key $'\r'
beat 1.8                             # daemon hot-reloads within a second
say 'git '
beat 2.2                             # the same card, recolored live
pty_key $'\x03'; beat 0.4
say ' exit'
pty_key $'\r'
beat 0.4

t_done
