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

# Cleanup runs on EVERY exit path — a failed pty_start or an aborted
# scenario must not leak its daemon or sandbox.
TRAPEXIT() { pty_stop }

t_fail() { print -u2 "FAIL: $1"; T_STATUS=1 }
t_skip() { print "SKIP: $1"; pty_stop 2>/dev/null; exit 0 }
t_done() { pty_stop 2>/dev/null; exit $T_STATUS }

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
