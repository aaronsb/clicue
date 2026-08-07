# clicue e2e harness — zpty scenarios against a SANDBOXED shell + daemon.
#
# Every scenario gets an isolated HOME/XDG universe and its own daemon on
# its own socket: nothing here touches the operator's corpus, flag store,
# or live daemon. The shell profile is a parameter — the menu-select leak
# hid for a whole session because the ad-hoc sandbox had no user zstyles
# (profiles/menu-select.zshrc is the configuration that caught it).
#
# The one non-negotiable mechanic: DRAIN CONTINUOUSLY. An undrained pty
# backpressures the card painter until zsh blocks on the tty write, which
# is indistinguishable from a shim deadlock [MEASURED, PR #6 era].
#
# Usage, from a scenario script:
#   source "${0:a:h}/harness.zsh"
#   pty_start menu-select        # profile name from tests/profiles/
#   pty_type 'ffmpeg -'          # keystroke by keystroke
#   pty_key $'\t'                # one key
#   pty_drain 0.5                # settle; output accumulates in $PTY_OUT
#   [[ $PTY_OUT == *'╭'* ]] || t_fail "no card"
#   pty_stop
#   t_done

emulate -L zsh
zmodload zsh/zpty zsh/datetime zsh/system zsh/zselect

# $0 is the harness path ONLY while sourcing (FUNCTION_ARGZERO); inside a
# function it is the function name. Resolve the tree once, now.
typeset -g T_ROOT=${0:a:h}

typeset -g PTY_OUT=''            # everything drained since last reset
typeset -gi T_ECHO=0             # 1 = relay drained output to stdout live
                                 #     (the demo recorder's hook)
typeset -ga T_SEED_HISTORY=()    # optional richer history for the sandbox
typeset -g T_SANDBOX=''          # this scenario's sandbox dir
typeset -g T_STATUS=0
typeset -gi T_DAEMON_PID=0
# :A canonicalizes — compinit's full rehash resolves a path entry with
# `..` in it to the WRONG binary (the installed one shadowed the build
# under test in every scenario until this bit) [MEASURED].
typeset -g CLICUE_BIN=${${CLICUE_BIN:-$T_ROOT/../target/debug/clicue}:A}

# Headless runners (CI, containers) hand us neither a terminal type nor
# a locale; a developer shell supplies both invisibly. Without TERM zle
# never paints POSTDISPLAY (no card, and the Tab harvest that rides the
# card dies with it); without a UTF-8 locale every multibyte glyph
# assertion fails [MEASURED: rust:bookworm, ubuntu-latest, PR #39].
export TERM=${TERM:-xterm-256color}
[[ $LANG == *(#i)utf-8* || $LC_ALL == *(#i)utf-8* ]] || export LANG=C.UTF-8

# Cleanup runs on EVERY exit path — a failed pty_start or an aborted
# scenario must not leak its daemon or sandbox.
TRAPEXIT() { pty_stop }

t_fail() { print -u2 "FAIL: $1"; T_STATUS=1 }
t_skip() { print "SKIP: $1"; pty_stop 2>/dev/null; exit 0 }
t_done() {
  # A failing scenario on a machine you cannot poke (CI) is undebuggable
  # without the daemon's and the SHIM's own accounts — dump both before
  # the sandbox dies. The shim silences itself for the shell's lifetime
  # on an error frame (spec §10); whether it did, and why, is the first
  # question every no-card failure needs answered.
  if (( T_STATUS != 0 )) && [[ -n $T_SANDBOX ]]; then
    local tail_out=${PTY_OUT: -600}
    PTY_OUT=''
    zpty -w clicue_pty ' print "T-DEAD=$_clicue_dead T-ERR=$_clicue_err"' 2>/dev/null
    pty_drain 0.6
    print -u2 "── shim state ──"
    t_plain "$PTY_OUT"
    print -ru2 -- "$REPLY"
    print -u2 "── last screen output ──"
    t_plain "$tail_out"
    print -ru2 -- "$REPLY"
    print -u2 "── daemon.log (${T_SANDBOX}) ──"
    tail -n 40 $T_SANDBOX/daemon.log 2>/dev/null >&2
  fi
  pty_stop 2>/dev/null
  exit $T_STATUS
}

# Sandbox + daemon + interactive zsh under zpty. $1 = profile (default plain).
pty_start() {
  local profile=${1:-plain}
  [[ -x $CLICUE_BIN ]] || { print -u2 "no clicue binary at $CLICUE_BIN (make build)"; exit 2 }
  T_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/clicue-e2e-XXXXXX")
  mkdir -p $T_SANDBOX/run $T_SANDBOX/cache
  # A small real history so the corpus has something to rank; scenarios
  # (and the demo) may seed their own richer one via T_SEED_HISTORY.
  if (( ${#T_SEED_HISTORY} )); then
    print -l -- "${(@)T_SEED_HISTORY}" > $T_SANDBOX/.zsh_history
  else
    print -l 'git status' 'git log' 'ls -la' 'ffmpeg -i in.mp4 out.mkv' \
      > $T_SANDBOX/.zsh_history
  fi
  cp "$T_ROOT/profiles/$profile.zshrc" $T_SANDBOX/.zshrc || exit 2
  # Pin layout values scenarios depend on — a changed default must fail
  # the default's own test, not silently reshape every scenario.
  mkdir -p $T_SANDBOX/.config/clicue
  print 'tier1-rows = 10' > $T_SANDBOX/.config/clicue/config.toml
  # The daemon is OURS: sandboxed env, tracked pid, killed in pty_stop.
  # (The shim would auto-spawn one detached — untracked processes leak.)
  HOME=$T_SANDBOX XDG_RUNTIME_DIR=$T_SANDBOX/run XDG_CACHE_HOME=$T_SANDBOX/cache \
    HISTFILE=$T_SANDBOX/.zsh_history $CLICUE_BIN daemon &>$T_SANDBOX/daemon.log &
  T_DAEMON_PID=$!
  local -F deadline=$(( EPOCHREALTIME + 15 ))
  until [[ -S $T_SANDBOX/run/clicue.sock ]]; do
    (( EPOCHREALTIME > deadline )) && { print -u2 "daemon never bound"; exit 2 }
    zselect -t 1 2>/dev/null   # 10ms; TRAPEXIT reaps on the failure path
  done
  # The socket existing is NOT the daemon answering: it binds before the
  # corpus build (a cold whatis sweep takes seconds on slow machines) and
  # serves after. A scenario that types immediately lands every keystroke
  # inside that window, each reply absent by the 25ms deadline, and fails
  # having never seen a card [MEASURED: ubuntu-latest, PR #39]. Gate on a
  # real answered request — the protocol's own minimal redraw frame — from
  # a DISPOSABLE zsh: a probe crash or wedge then costs one retry, never
  # the scenario shell.
  local ready_req='{"v":1,"session":{"pid":'$$',"start":0},"event":{"kind":"redraw"},"buffer":"","cursor":0,"cols":80,"lines":24,"keymap":"main"}'
  deadline=$(( EPOCHREALTIME + 20 ))
  until zsh -fc '
    zmodload zsh/net/socket zsh/system || exit 1
    zsocket '$T_SANDBOX'/run/clicue.sock 2>/dev/null || exit 1
    syswrite -o $REPLY -- ${1}$'\''\n'\'' 2>/dev/null || exit 1
    local chunk
    sysread -i $REPLY -t 2 chunk 2>/dev/null && [[ -n $chunk ]]
  ' probe "$ready_req" 2>/dev/null; do
    (( EPOCHREALTIME > deadline )) && { print -u2 "daemon bound but never answered"; exit 2 }
    zselect -t 20 2>/dev/null
  done
  # zpty inherits the exported sandbox; PATH keeps the build's binary first
  # so `clicue init zsh` in .zshrc emits the shim under test.
  export ZDOTDIR=$T_SANDBOX HOME=$T_SANDBOX HISTFILE=$T_SANDBOX/.zsh_history
  export XDG_RUNTIME_DIR=$T_SANDBOX/run XDG_CACHE_HOME=$T_SANDBOX/cache
  path=( ${CLICUE_BIN:h} $path )
  zpty clicue_pty 'zsh -i'
  pty_drain 1.5
  # Integrity gate: the pty MUST resolve `clicue` to the binary under
  # test — a wrong resolution invalidates every assertion after it.
  PTY_OUT=''
  zpty -w clicue_pty ' print "T-BIN=$(whence -p clicue)"'
  pty_drain 0.5
  t_plain "$PTY_OUT"
  if [[ $REPLY != *"T-BIN=$CLICUE_BIN"* ]]; then
    print -u2 "sandbox shell resolves the wrong clicue (want $CLICUE_BIN); got: ${REPLY##*T-BIN=}"
    exit 2
  fi
  PTY_OUT=''
}

# Drain until PTY_OUT matches the glob $1, or ${2:-8}s passes. Returns
# whether it matched. Scenarios began life with fixed drains tuned to an
# idle machine; on a starved CI VM the first Tab's compsys work blew
# every one of them, while the sentinel-waiting scenario passed (PR #39).
# Wait for the thing itself, not for an amount of time.
pty_wait_for() {
  local pat=$1
  local -F wait_deadline=$(( EPOCHREALTIME + ${2:-8} ))
  while (( EPOCHREALTIME < wait_deadline )); do
    [[ $PTY_OUT == ${~pat} ]] && return 0
    pty_drain 0.25
  done
  [[ $PTY_OUT == ${~pat} ]]
}

# Drain until $1 seconds of silence. Appends to PTY_OUT.
pty_drain() {
  local -F quiet=$(( EPOCHREALTIME + $1 ))
  local chunk
  while (( EPOCHREALTIME < quiet )); do
    if zpty -rt clicue_pty chunk 2>/dev/null; then
      PTY_OUT+=$chunk
      (( T_ECHO )) && print -rn -- "$chunk"
      quiet=$(( EPOCHREALTIME + $1 ))
    fi
  done
}

# Type text one keystroke at a time, draining between keys (real typing).
pty_type() {
  local -i i
  for (( i = 1; i <= ${#1}; i++ )); do
    zpty -w -n clicue_pty "${1[i]}"
    pty_drain 0.04
  done
}

pty_key() { zpty -w -n clicue_pty "$1" }

# Run a raw command line in the pty shell and drain its output.
pty_exec() { zpty -w clicue_pty " $1"; pty_drain 0.4 }

pty_stop() {
  zpty -d clicue_pty 2>/dev/null
  # Reap BEFORE the rm: a dying daemon (or the pty shell's exit) racing
  # the delete is how skeleton dirs leak. Profiles set SAVEHIST=0 so the
  # shell writes no history at exit either.
  if (( T_DAEMON_PID )); then
    kill $T_DAEMON_PID 2>/dev/null
    wait $T_DAEMON_PID 2>/dev/null
    T_DAEMON_PID=0
  fi
  if [[ -n $T_SANDBOX && $T_SANDBOX == */clicue-e2e-* ]]; then
    rm -rf -- $T_SANDBOX
    T_SANDBOX=''
  fi
}

# Strip ANSI control sequences for content assertions. Always strip BEFORE
# matching words: zsh's redisplay paints per CHARACTER, each wrapped in its
# own colour escape, so a word like 'browsing' never appears contiguously
# in the raw stream — raw greps silently fail [MEASURED, twice in one day].
t_plain() {
  setopt localoptions extendedglob   # `#` in the pattern needs it
  REPLY=${1//$'\x1b'\[[0-9;?]#[A-Za-z]/}   # '?' covers private modes (\e[?2004h)
}
