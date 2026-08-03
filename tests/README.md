# clicue e2e test library

`make check` proves the modules; this directory proves the *experience*: a
real interactive zsh under a pty, the real shim, a real daemon, real
keystrokes. Everything runs sandboxed — own HOME, own XDG dirs, own daemon
on its own socket — and never touches the operator's corpus, flag store,
or live daemon.

```
make e2e            # build + run every scenario (tests/run.zsh)
zsh tests/scenarios/<one>.zsh    # run one scenario
```

## Layout

- `harness.zsh` — zpty plumbing: `pty_start <profile>`, `pty_type`,
  `pty_key`, `pty_drain`, assertions. Read its header before writing a
  scenario; the continuous-drain rule is not optional (an undrained pty
  backpressures the painter until the shell blocks on the tty write, which
  looks exactly like a shim deadlock).
- `profiles/` — the `.zshrc` a scenario's shell boots with. `plain` is the
  friendliest host; `menu-select` is the configuration class that hid the
  capture leak for a whole session. A capture-adjacent scenario that only
  runs under `plain` is not verified.
- `scenarios/` — one behavior each, exit 0/1, `SKIP` when an optional
  command (e.g. ffmpeg) is missing.
- `bench/` — informational measurement tools, not gates. `rpc_latency.py`
  times daemon round-trips from outside the shim; run it against a
  sandbox daemon by preference (against the live one it will store a
  `clicue-bench-synthetic` flag table you may want to
  `clicue data forget clicue-bench-synthetic` afterwards).

## Provenance of the gates

- 25 ms/key typing gate: measured ~3 ms/key locally after the quadratic
  reply-parse fix (spec §7a); the regression it guards sat at ~600 ms/key.
- 5 ms in `rpc_latency.py`'s warning: the shim's read deadline (spec §8).
  A daemon answer near it means Tab silently falls back to raw compsys —
  the harvested card loses every race it should win.
