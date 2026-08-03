#!/usr/bin/env zsh
# The compadd-shadow capture in isolation: `zle _clicue_cap` on 'ffmpeg -'
# must fill the capture arrays and leave the buffer and screen alone —
# under the hostile profile, where _main_complete recomputes compstate.
source "${0:a:h}/../harness.zsh"

(( $+commands[ffmpeg] )) || t_skip "ffmpeg not installed"

pty_start menu-select

pty_exec '_cap_probe() {
  BUFFER="ffmpeg -"; CURSOR=8
  zle _clicue_cap 2>/dev/null
  local w=${#_clicue_cs_words} b=${(q)BUFFER}
  BUFFER=""
  zle -M "PROBE words=$w buf=$b"
}; zle -N _cap_probe; bindkey "^T" _cap_probe'
PTY_OUT=''
pty_key $'\x14'
pty_drain 0.8

[[ $PTY_OUT == *'PROBE words='* ]] || t_fail "probe never reported"
[[ $PTY_OUT == *'buf=ffmpeg\ -'* ]] || t_fail "capture mutated the buffer"
[[ $PTY_OUT == *'words=0'* ]] && t_fail "capture saw no candidates"
[[ $PTY_OUT == *' -- '* ]] && t_fail "capture leaked the compsys listing"

t_done
