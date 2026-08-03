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
zmodload zsh/zpty zsh/datetime zsh/system

# $0 is the harness path ONLY while sourcing (FUNCTION_ARGZERO); inside a
# function it is the function name. Resolve the tree once, now.
typeset -g T_ROOT=${0:a:h}

typeset -g PTY_OUT=''            # everything drained since last reset
typeset -g T_SANDBOX=''          # this scenario's sandbox dir
typeset -g T_STATUS=0
typeset -gi T_DAEMON_PID=0
typeset -g CLICUE_BIN=${CLICUE_BIN:-$T_ROOT/../target/debug/clicue}

t_fail() { print -u2 "FAIL: $1"; T_STATUS=1 }
t_skip() { print "SKIP: $1"; pty_stop 2>/dev/null; exit 0 }
t_done() { pty_stop 2>/dev/null; exit $T_STATUS }

# Sandbox + daemon + interactive zsh under zpty. $1 = profile (default plain).
pty_start() {
  local profile=${1:-plain}
  [[ -x $CLICUE_BIN ]] || { print -u2 "no clicue binary at $CLICUE_BIN (make build)"; exit 2 }
  T_SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/clicue-e2e-XXXXXX")
  mkdir -p $T_SANDBOX/run $T_SANDBOX/cache
  # A small real history so the corpus has something to rank.
  print -l 'git status' 'git log' 'ls -la' 'ffmpeg -i in.mp4 out.mkv' \
    > $T_SANDBOX/.zsh_history
  cp "$T_ROOT/profiles/$profile.zshrc" $T_SANDBOX/.zshrc || exit 2
  # The daemon is OURS: sandboxed env, tracked pid, killed in pty_stop.
  # (The shim would auto-spawn one detached — untracked processes leak.)
  HOME=$T_SANDBOX XDG_RUNTIME_DIR=$T_SANDBOX/run XDG_CACHE_HOME=$T_SANDBOX/cache \
    HISTFILE=$T_SANDBOX/.zsh_history $CLICUE_BIN daemon &>$T_SANDBOX/daemon.log &
  T_DAEMON_PID=$!
  local -F deadline=$(( EPOCHREALTIME + 15 ))
  until [[ -S $T_SANDBOX/run/clicue.sock ]]; do
    (( EPOCHREALTIME > deadline )) && { print -u2 "daemon never bound"; exit 2 }
  done
  # zpty inherits the exported sandbox; PATH keeps the build's binary first
  # so `clicue init zsh` in .zshrc emits the shim under test.
  export ZDOTDIR=$T_SANDBOX HOME=$T_SANDBOX HISTFILE=$T_SANDBOX/.zsh_history
  export XDG_RUNTIME_DIR=$T_SANDBOX/run XDG_CACHE_HOME=$T_SANDBOX/cache
  path=( ${CLICUE_BIN:h} $path )
  zpty clicue_pty 'zsh -i'
  pty_drain 1.5
  PTY_OUT=''
}

# Drain until $1 seconds of silence. Appends to PTY_OUT.
pty_drain() {
  local -F quiet=$(( EPOCHREALTIME + $1 ))
  local chunk
  while (( EPOCHREALTIME < quiet )); do
    if zpty -rt clicue_pty chunk 2>/dev/null; then
      PTY_OUT+=$chunk
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
  (( T_DAEMON_PID )) && kill $T_DAEMON_PID 2>/dev/null
  T_DAEMON_PID=0
  [[ -n $T_SANDBOX && $T_SANDBOX == */clicue-e2e-* ]] && rm -rf -- $T_SANDBOX
}

# Strip ANSI control sequences for content assertions.
t_plain() { REPLY=${1//$'\x1b'\[[0-9;]#[A-Za-z]/} }
