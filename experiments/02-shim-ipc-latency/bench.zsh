#!/usr/bin/env zsh
# Spike: measure zsh -> daemon -> zsh round-trip latency over a Unix socket,
# using exactly the modules the real shim would use (zsh/net/socket for the
# connect, zsh/system sysread/syswrite for the transfer, zsh/datetime for
# timing). Run beside echo-daemon.rs:
#
#   rustc -O echo-daemon.rs -o /tmp/clicue-spike-daemon
#   /tmp/clicue-spike-daemon /tmp/clicue-spike.sock &
#   zsh bench.zsh /tmp/clicue-spike.sock 1000
#
# Reports microseconds: min / p50 / p99 / max for
#   1. persistent connection (the shim's steady state)
#   2. connect-per-request   (the reconnect path after a daemon restart)
# plus one fork baseline, because the fork budget is the number the prototype
# lived by and the socket has to beat it comfortably.

emulate -L zsh
zmodload zsh/net/socket || { print -u2 "no zsh/net/socket"; exit 1 }
zmodload zsh/system     || { print -u2 "no zsh/system"; exit 1 }
zmodload zsh/datetime   || { print -u2 "no zsh/datetime"; exit 1 }

local sock=${1:-/tmp/clicue-spike.sock}
local -i n=${2:-1000}

_stats() {  # name times...
  local name=$1; shift
  local -a t=( ${(n)@} )
  local -i c=${#t}
  printf '%-22s n=%-5d min=%5dus  p50=%5dus  p99=%6dus  max=%6dus\n' \
    $name $c ${t[1]} ${t[$(( c / 2 ))]} ${t[$(( c * 99 / 100 ))]} ${t[-1]}
}

# one round trip on an open fd; sets rt_us
_roundtrip() {
  local -i fd=$1
  local -F t0 t1
  local buf='' chunk
  t0=$EPOCHREALTIME
  syswrite -o $fd $'ping\n'
  while [[ $buf != *$'\n' ]]; do
    sysread -i $fd -t 1 chunk || return 1
    buf+=$chunk
  done
  t1=$EPOCHREALTIME
  (( rt_us = (t1 - t0) * 1000000 ))
  # Sanity: got a card-sized reply. CHARACTERS, not bytes — the payload is
  # sized in bytes (2000+) but carries multibyte glyphs, so the char count is
  # lower. 1500 chars still proves a full card crossed the socket.
  (( ${#buf} > 1500 ))
}

local -i rt_us fd i
local -a persistent=() perconn=() forks=()

# ── 1. persistent connection ────────────────────────────────────────────────
zsocket $sock || { print -u2 "connect to $sock failed"; exit 1 }
fd=$REPLY
for (( i = 0; i < 50; i++ )); do _roundtrip $fd || exit 1; done   # warmup
for (( i = 0; i < n; i++ )); do
  _roundtrip $fd || { print -u2 "roundtrip $i failed"; exit 1 }
  persistent+=( $rt_us )
done
exec {fd}>&-

# ── 2. connect per request ──────────────────────────────────────────────────
local -F c0 c1
for (( i = 0; i < n; i++ )); do
  c0=$EPOCHREALTIME
  zsocket $sock || exit 1
  fd=$REPLY
  _roundtrip $fd || exit 1
  exec {fd}>&-
  c1=$EPOCHREALTIME
  (( rt_us = (c1 - c0) * 1000000 ))
  perconn+=( $rt_us )
done

# ── 3. fork baseline: the cost the prototype's no-fork rule avoids ──────────
local -F f0 f1
for (( i = 0; i < 200; i++ )); do
  f0=$EPOCHREALTIME
  : $(true)
  f1=$EPOCHREALTIME
  (( rt_us = (f1 - f0) * 1000000 ))
  forks+=( $rt_us )
done

_stats "persistent-conn" $persistent
_stats "connect-per-request" $perconn
_stats "fork-baseline" $forks
