#!/usr/bin/env zsh
# Latency canary: a burst of ordinary typing must be fully processed —
# shim RPC, daemon render, reply parse, card paint — at interactive speed.
# Local measurement is ~3ms/key; the 25ms/key gate is CI headroom, and the
# quadratic-parse regression it guards against sat at ~600ms/key.
source "${0:a:h}/../harness.zsh"

pty_start plain

local text='git checkout '
local -F t0=$EPOCHREALTIME
local -F last=$t0
local -i i
local chunk
for (( i = 1; i <= ${#text}; i++ )); do
  zpty -w -n clicue_pty "${text[i]}"
  while zpty -rt clicue_pty chunk 2>/dev/null; do PTY_OUT+=$chunk; last=$EPOCHREALTIME; done
done
local -F quiet=$(( EPOCHREALTIME + 0.3 ))
while (( EPOCHREALTIME < quiet )); do
  if zpty -rt clicue_pty chunk 2>/dev/null; then
    PTY_OUT+=$chunk
    last=$EPOCHREALTIME
    quiet=$(( EPOCHREALTIME + 0.3 ))
  fi
done

local -F per_key=$(( (last - t0) * 1000 / ${#text} ))
printf 'typed %d keys: %.1f ms/key\n' ${#text} $per_key
(( per_key < 25 )) || t_fail "typing lag: ${per_key}ms/key (gate 25ms)"
[[ $PTY_OUT == *'╭'* ]] || t_fail "no card ever painted during typing"

t_done
