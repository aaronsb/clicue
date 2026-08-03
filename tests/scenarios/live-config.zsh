#!/usr/bin/env zsh
# Config changes apply LIVE: `clicue config set theme base` must reshape
# the card within the daemon's reload interval (1s) — no restart, no new
# shell, sessions kept. base is the ASCII contract theme, so the signal
# is unmistakable: borders flip from ╭─ to +-. The invalid-value check
# also proves the shell's stderr SURVIVES a reload: the disconnect path
# once nulled it permanently (spec §8a).
source "${0:a:h}/../harness.zsh"

pty_start plain

pty_type 'gi'
pty_drain 0.5
t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]] || t_fail "no unicode card before the change"
pty_key $'\x03'; pty_drain 0.3
PTY_OUT=''

pty_exec 'clicue config set theme base'
t_plain "$PTY_OUT"
[[ $REPLY == *'applied live'* ]] || t_fail "config set did not confirm"
pty_drain 1.4   # cross the daemon's 1s reload interval
PTY_OUT=''

pty_type 'gi'
pty_drain 0.5
pty_drain 0.3
t_plain "$PTY_OUT"
[[ $REPLY == *'+ 1/'* || $REPLY == *'+--'* ]] || t_fail "card did not reshape to base after live reload"

# an invalid value is refused before it can reach the file — and the
# refusal is VISIBLE, which requires stderr to have survived the reload
PTY_OUT=''
pty_key $'\x03'; pty_drain 0.2
pty_exec 'clicue config set tier1-rows banana; print RC=$?'
local -F deadline=$(( EPOCHREALTIME + 15 ))
while [[ $PTY_OUT != *RC=[0-9]* ]] && (( EPOCHREALTIME < deadline )); do
  pty_drain 0.3
done
t_plain "$PTY_OUT"
[[ $REPLY == *'refusing to write'* ]] || t_fail "refusal invisible — stderr died in the reload path"
[[ $REPLY == *'RC=1'* ]] || t_fail "refusal must exit non-zero"

t_done
