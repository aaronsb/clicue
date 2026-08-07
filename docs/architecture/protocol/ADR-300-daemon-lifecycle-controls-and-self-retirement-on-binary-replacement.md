---
status: Accepted
date: 2026-08-06
deciders:
  - aaronsb
  - claude
related:
  - ADR-401
---

# ADR-300: Daemon lifecycle: controls and self-retirement on binary replacement

## Context

The daemon outlives its binary. Measured today: a daemon started Aug 3
from `~/.cargo/bin/clicue` was still serving on Aug 6 — three days and
two releases stale, its executable long deleted — and the operator's
first symptom was maximally confusing: `clicue theme powerline`
"defaulted to the default theme" (the old parser rejects the new
theme's keys; an unknown shipped name falls back to base), while aura
worked fine. Nothing named the actual problem. The pacman post_upgrade
hook asks the operator to `pkill -x clicue` by hand, and `clicue
daemon` had no verbs at all: no way to ask whether a daemon runs, which
binary it runs, or to bounce it.

The hot-reload contract (S7) deliberately covers derived inputs —
config, corpus, themes — so no CLI verb needs a restart. The binary
itself is the one input it cannot swap in-process.

## Decision

**1. The binary is a watched input; the response is retirement, not
reload.** At startup the daemon stamps its own executable (path +
device/inode). The reloader's existing rate-limited poll also checks
that stamp; when the file at that path is gone or a different inode,
the daemon logs one line and exits cleanly. The shim's §9 auto-spawn
brings up the replacement on the next keystroke — the same
absent-not-degraded posture as every other failure. This fixes every
install channel at once (pacman, AUR, cargo, the curl installer), and
in development a rebuilt `target/debug/clicue` retires the old daemon
for free.

**2. `clicue daemon` grows verbs: `status`, `stop`, `restart`** (bare
`clicue daemon` still runs it — the shim's spawn line is unchanged).
The lockfile is the truth and now carries the holder's pid: flock
acquirable means no daemon; held means the pid in the file is alive.
`status` reports pid, socket, and whether the running binary is
current (`/proc/pid/exe` deleted-or-moved is exactly the stale-daemon
signal). `stop` verifies the pid's comm is `clicue`, SIGTERMs, and
waits for the lock to free. `restart` is stop-then-spawn-detached,
waiting for the lock to be held again.

**3. The pacman hook stops daemons instead of asking.** post_upgrade
runs `pkill -x clicue` (root reaches every user's daemon; each respawns
fresh on the next keystroke). Needed exactly once per pre-0.4.0
upgrade; afterwards self-retirement makes it a harmless no-op, and the
hook keeps working on systems where it is the only mechanism.

## Consequences

- A replaced binary costs each open shell one absent card (the
  keystroke that triggers the poll) plus one respawn; sessions lose
  their hello universes until shells re-hello — the same cost a crash
  already had, now bounded to one per upgrade.
- The retirement check lives behind the reloader's poll gate
  (`WatchSet::retire_on_exe_change`, set only by the daemon's watch
  set), so engine tests and other reloader users never exit the test
  process.
- `stop` does not escalate to SIGKILL: a daemon that survives SIGTERM
  is an incident to name, not to mask.
- spec/protocol.md §9 gains the retirement and control clauses.
