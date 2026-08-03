#!/usr/bin/env zsh
# The stock-zshrc journey: no conf.d pattern, no plugin manager, no
# compinit — `clicue install --yes` must produce a config where the card
# AND the flag harvest work. The installer appends its own compinit when
# the probed shell lacks one; without it a stock install is silently
# half-working (cards yes, Tab-harvest never).
source "${0:a:h}/../harness.zsh"

pty_start stock

# install from inside the sandboxed shell (probe sees the stock rc)
pty_exec 'clicue install --yes >$HOME/install.log 2>&1; print RC=$?'
pty_drain 2.0   # the install runs a full doctor probe (nested zsh -i)
t_plain "$PTY_OUT"
[[ $REPLY == *'RC=0'* ]] || t_fail "clicue install failed"
pty_exec 'grep -c "clicue init zsh" $ZDOTDIR/.zshrc'
t_plain "$PTY_OUT"
[[ $REPLY == *1* ]] || t_fail "install line not appended"

# reload: the freshly installed rc must come up with shim + compsys
pty_exec 'exec zsh -i'
pty_drain 1.5
PTY_OUT=''

pty_type 'tar -'
pty_key $'\t'
pty_drain 0.8
pty_drain 0.4
t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]] || t_fail "no card after stock install"
# tar's documented set proves the harvest crossed compsys — which only
# exists because the installer added compinit
[[ $REPLY == *'-'[A-Za-z]* ]] || t_fail "no flag cues harvested"
[[ $REPLY == *' -- '* ]] && t_fail "compsys listing leaked"

t_done
