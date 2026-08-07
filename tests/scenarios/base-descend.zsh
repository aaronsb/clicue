#!/usr/bin/env zsh
# Design note "locations are navigable": a typed base (`cd ../`) plus the
# completion key engages the card, arrows walk the destinations, and the
# pick inserts WITH the base intact. This flow crosses the RPC deadline
# with the fattest traffic the protocol carries (harvest-laden request,
# ~27KB nav card), which is exactly how the 5ms deadline was caught
# failing healthy round trips (spec §8, amended) — a fired deadline here
# delegates the completion key, which inserts a bare name.
source "${0:a:h}/../harness.zsh"

pty_start plain

pty_type 'cd ../'
pty_drain 1.0
pty_key $'\t'
pty_wait_for '*↑↓ browse*'
t_plain "$PTY_OUT"
[[ $REPLY == *'↑↓ browse'* ]] || t_fail "Tab did not engage on a path base"
PTY_OUT=''

pty_key $'\e[B'
pty_drain 0.8
pty_key $'\r'
pty_wait_for '*../*' 5
t_plain "$PTY_OUT"
[[ $REPLY == *'../'* ]] || t_fail "the pick lost its ../ base"

t_done
