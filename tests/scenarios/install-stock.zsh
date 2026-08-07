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
# sentinel wait, not a fixed drain: the install runs a full doctor probe
# (nested zsh -i) whose duration varies by machine
local -F deadline=$(( EPOCHREALTIME + 30 ))
while [[ $PTY_OUT != *RC=[0-9]* ]] && (( EPOCHREALTIME < deadline )); do
  pty_drain 0.3
done
t_plain "$PTY_OUT"
if [[ $REPLY != *'RC=0'* ]]; then
  t_fail "clicue install failed"
  # The reason lives in the sandboxed log — surface it or CI shows
  # only this assert (first seen: ubuntu runner, review of PR #39).
  PTY_OUT=''
  pty_exec 'cat $HOME/install.log'
  t_plain "$PTY_OUT"
  print -u2 "── install.log ──"
  print -u2 "$REPLY"
fi
PTY_OUT=''
pty_exec 'print COUNT=$(grep -c "clicue init zsh" $ZDOTDIR/.zshrc)'
t_plain "$PTY_OUT"
[[ $REPLY == *'COUNT=1'* ]] || t_fail "install line not appended exactly once"

# reload: the freshly installed rc must come up with shim + compsys
pty_exec 'exec zsh -i'
pty_drain 1.5
PTY_OUT=''

pty_type 'tar -'
pty_key $'\t'
# Sentinel wait, not a fixed drain (same reason as the install above):
# the harvest runs a compsys capture whose duration varies wildly with
# the machine — a cold 2-core CI runner missed a 1.2s budget while the
# card itself was already up [MEASURED: ubuntu-latest, PR #39].
deadline=$(( EPOCHREALTIME + 8 ))
while (( EPOCHREALTIME < deadline )); do
  pty_drain 0.3
  t_plain "$PTY_OUT"
  [[ $REPLY == *'╭'* && $REPLY == *archive* ]] && break
done
t_plain "$PTY_OUT"
[[ $REPLY == *'╭'* ]] || t_fail "no card after stock install"
# tar's documented set proves the harvest crossed compsys — which only
# exists because the installer added compinit. Require a real tar desc,
# not any hyphenated word in card copy.
[[ $REPLY == *archive* ]] || t_fail "no tar flag descriptions harvested"
[[ $REPLY == *' -- '* ]] && t_fail "compsys listing leaked"

t_done
