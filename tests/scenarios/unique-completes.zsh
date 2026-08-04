#!/usr/bin/env zsh
# Spec keys T4 (amended): a SOLE candidate inserts on the completion key,
# exactly typed or merely unique — the universal multi-level traversal
# `cd Pr<Tab>ai<Tab>ag<Tab><Enter>` is one gesture per level. Ambiguity
# still earns the card (enter-composes.zsh owns that half).
source "${0:a:h}/../harness.zsh"

pty_start plain
mkdir -p $T_SANDBOX/Projects/ai/agent-ways $T_SANDBOX/Projects/app
pty_type 'cd ~'
pty_key $'\r'; pty_drain 0.5; PTY_OUT=''

pty_type 'cd Pr'
pty_drain 0.4
pty_key $'\t'          # unique → inserts Projects/
pty_drain 0.7
pty_type 'ai'
pty_drain 0.4
pty_key $'\t'          # unique under Projects/ → ai/
pty_drain 0.7
pty_type 'ag'
pty_drain 0.4
pty_key $'\t'          # unique under ai/ → agent-ways/
pty_drain 0.7
t_plain "$PTY_OUT"
[[ $REPLY == *'Projects/ai/agent-ways'* ]] || t_fail "traversal did not compose: ${REPLY: -200}"
PTY_OUT=''

pty_key $'\r'          # not engaged after an insert: Enter runs the line
pty_drain 0.7
pty_type 'pwd'
pty_key $'\r'
pty_drain 0.7
t_plain "$PTY_OUT"
[[ $REPLY == *'Projects/ai/agent-ways'* ]] || t_fail "the line did not run where it said"

t_done
