#!/usr/bin/env zsh
# Spec G1: the grid is entered by scrolling past tier 1 — from an engaged
# card, Down walks the tier-1 rows and crosses into the columnar grid,
# focus following the selection. (Tab deliberately wraps at the tier-1
# boundary, T5; arrows are the way in.)
source "${0:a:h}/../harness.zsh"

(( $+commands[ffmpeg] )) || t_skip "ffmpeg not installed"

pty_start plain

pty_type 'ffmpeg -'
pty_key $'\t'          # harvest + engage
pty_drain 0.8
t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]] || t_fail "card never engaged on Tab"
PTY_OUT=''
local -i i
for (( i = 1; i <= 16; i++ )); do
  pty_key $'\e[B'
  pty_drain 0.1
done
pty_drain 0.4

t_plain "$PTY_OUT"
[[ $REPLY == *'browsing'* ]] || t_fail "selection never crossed into the grid (no browsing header)"
[[ $REPLY == *'▸-'* ]]       || t_fail "marker never sat on a grid entry"

t_done
