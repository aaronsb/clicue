#!/usr/bin/env zsh
# Spec keys E1/E2: engaged, Enter means "put this on the line" — never
# "run it"; unengaged, Enter runs the line untouched. Caught live
# 2026-08-03: the shim sent the key as "insert", no engine arm matched,
# and every Enter fell through to accept-line while the legend advertised
# ⏎ insert. This seam is invisible to the in-process suite by nature —
# the names live on opposite sides of the wire.
source "${0:a:h}/../harness.zsh"

# A remembered line whose EXECUTION output ("42") never appears in its
# own text — so run-vs-composed is unambiguous in the pty stream.
T_SEED_HISTORY=( 'echo $((6*7))' )

pty_start plain

pty_type 'echo $'
pty_key $'\t'          # engage: cycle onto the remembered line's cue
pty_drain 0.8
t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]] || t_fail "card never engaged on Tab"
PTY_OUT=''

pty_key $'\r'          # engaged Enter: compose, do not run
pty_drain 0.8
t_plain "$PTY_OUT"
[[ $REPLY == *'6*7'* ]]  || t_fail "Enter did not insert the cue onto the line"
[[ $REPLY != *'42'* ]]   || t_fail "engaged Enter RAN the line (E2 violated)"
PTY_OUT=''

pty_key $'\r'          # unengaged Enter: the line belongs to the shell
pty_drain 0.8
t_plain "$PTY_OUT"
[[ $REPLY == *'42'* ]] || t_fail "unengaged Enter did not run the line (E1 violated)"

t_done
