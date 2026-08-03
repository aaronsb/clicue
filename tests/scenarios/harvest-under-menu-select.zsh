#!/usr/bin/env zsh
# THE regression of 2026-08-02: 'ffmpeg -' + Tab under `menu select=1`
# leaked the full compsys listing over the card and inserted the first
# candidate into the buffer. Two causes, both must stay fixed:
#   - compstate suppression ordered AFTER _main_complete (shim capture)
#   - daemon accept under the 5ms deadline (FlagStore Arc, engine)
source "${0:a:h}/../harness.zsh"

(( $+commands[ffmpeg] )) || t_skip "ffmpeg not installed"

pty_start menu-select

pty_type 'ffmpeg -'
PTY_OUT=''
pty_key $'\t'
pty_drain 0.8

# compsys's listing rows are "<flag>  -- <desc>"; the card never uses ' -- '.
[[ $PTY_OUT == *' -- '* ]]            && t_fail "compsys listing leaked past the capture"
[[ $PTY_OUT == *'Hit TAB for more'* ]] && t_fail "list pager engaged"
[[ $PTY_OUT == *'╭'* ]]               || t_fail "no card painted on Tab"

# Second Tab cycles the card; still nothing from compsys.
PTY_OUT=''
pty_key $'\t'
pty_drain 0.5
[[ $PTY_OUT == *' -- '* ]] && t_fail "listing on cycle Tab"

# (Insertion without a listing cannot happen under menu select, so the
# ' -- ' checks above also cover the inserted-first-candidate failure.)
pty_key $'\x03'   # abort the line
pty_drain 0.3
pty_exec 'clicue data inspect ffmpeg | grep -q harvested && print MARK-STORED'
[[ $PTY_OUT == *'MARK-STORED'* ]] || t_fail "harvest did not reach the flag store"

t_done
