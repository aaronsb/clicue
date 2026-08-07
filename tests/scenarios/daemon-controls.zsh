#!/usr/bin/env zsh
# spec §9b (ADR-300): status names the running daemon by pid, restart
# hands the socket to a fresh pid, stop reports what it stopped. What
# this deliberately does NOT assert: "stopped stays stopped" — in a
# wired shell the next prompt repaint auto-spawns a successor (§9),
# which is the product working, not the test failing.
source "${0:a:h}/../harness.zsh"

pty_start plain
PTY_OUT=''

pty_exec 'clicue daemon status'
pty_wait_for '*running*pid*' 5
t_plain "$PTY_OUT"
[[ $REPLY == *"running (pid $T_DAEMON_PID"* ]] || t_fail "status did not name the harness daemon"
[[ $REPLY == *'binary current'* ]] || t_fail "status did not vouch for the binary"
PTY_OUT=''

pty_exec 'clicue daemon restart'
pty_wait_for '*restarted: pid*' 15
t_plain "$PTY_OUT"
[[ $REPLY == *'restarted: pid'* ]]      || t_fail "restart did not report"
[[ $REPLY == *"(was $T_DAEMON_PID)"* ]] || t_fail "restart did not stop the old pid"
PTY_OUT=''

pty_exec 'clicue daemon status'
pty_wait_for '*running*pid*' 5
t_plain "$PTY_OUT"
[[ $REPLY == *'running (pid'* ]]        || t_fail "no daemon after restart"
[[ $REPLY != *"pid $T_DAEMON_PID"* ]]   || t_fail "status still shows the pre-restart pid"

# The restarted daemon is detached — the harness tracks only its own
# spawn, so stop it here or it outlives the sandbox. A §9 auto-spawn
# may follow within the scenario's lifetime; its 30s window was already
# consumed above if so, and pty_stop tears the sandbox out from under
# any straggler's socket path either way.
PTY_OUT=''
pty_exec 'clicue daemon stop'
pty_wait_for '*stopped*pid*' 10
t_plain "$PTY_OUT"
[[ $REPLY == *'stopped (pid'* ]] || t_fail "stop did not report what it stopped"

t_done
