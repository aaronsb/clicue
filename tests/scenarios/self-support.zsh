#!/usr/bin/env zsh
# clicue supports itself through the same universal path as every other
# command: `clicue init zsh` emits a clap-generated _clicue completer, so
# 'clicue ' + Tab harvests the real subcommand set — no special-casing,
# and the card can never drift from the binary.
source "${0:a:h}/../harness.zsh"

pty_start plain

pty_exec 'print "FN=$+functions[_clicue]"'
t_plain "$PTY_OUT"
[[ $REPLY == *'FN=1'* ]] || t_fail "_clicue completer not defined by the shim eval"
PTY_OUT=''

pty_type 'clicue '
PTY_OUT=''
# The FIRST Tab both harvests and renders the full card; later Tabs only
# repaint the moved marker cells, so assertions belong on this window.
pty_key $'\t'
pty_drain 0.9
pty_drain 0.4

t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]]      || t_fail "no card for clicue's own arguments"
[[ $REPLY == *doctor* ]]   || t_fail "subcommand cues missing (doctor)"
[[ $REPLY == *'Probe a live zsh'* ]] || t_fail "clap descriptions did not survive the harvest"

t_done
