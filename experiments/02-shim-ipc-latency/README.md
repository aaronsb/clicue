# 02 — shim ↔ daemon IPC latency

The evidence behind ADR-100's protocol section. The architecture leans on one
physics claim: a zsh widget can round-trip a card-sized reply over a Unix
socket inside a single-digit-millisecond budget, using only zsh's own modules
(`zsh/net/socket` to connect, `zsh/system` sysread/syswrite to transfer).

## Method

`echo-daemon.rs` (std only, `rustc -O`) serves a Unix socket: one
newline-terminated request line in, one ~2 KB newline-terminated reply out —
sized and shaped like a rendered card (JSON, multibyte glyphs included).
`bench.zsh` measures 1000 round trips after 50 warmups, plus the
connect-per-request path and a fork baseline.

```
rustc -O echo-daemon.rs -o /tmp/spike-daemon
/tmp/spike-daemon /tmp/clicue-spike.sock &
zsh bench.zsh /tmp/clicue-spike.sock 1000
```

## Results (2026-08-02, Arch, zsh 5.9, Ryzen workstation) [MEASURED]

```
persistent-conn        n=1000  min=   20us  p50=   25us  p99=    57us  max=    90us
connect-per-request    n=1000  min=   40us  p50=   49us  p99=   156us  max=   258us
fork-baseline          n=200   min=   95us  p50=  154us  p99=   245us  max=   258us
```

## Verdict — GO

- Persistent connection is **~100× inside** the single-digit-ms budget at p99.
- A socket round trip (25 µs) costs **~6× less than one fork** (154 µs) — the
  unit the prototype's no-fork rule was built around. The daemon path is
  cheaper than the cheapest thing the prototype was allowed to do.
- Reconnect-per-request stays under 0.3 ms worst-case, so a daemon restart
  mid-session costs one imperceptible keystroke, and the shim needs no
  connection pooling cleverness.

Implications for `spec/protocol.md`:

- Newline-delimited framing over `zsh/net/socket` + `sysread` is sufficient;
  no need for length-prefixing or zpty.
- The shim's read timeout can be tight (a few ms) and will fire only on a
  genuinely wedged daemon, never on a healthy slow reply.
- One measurement caveat to carry: `${#buf}` in zsh counts characters, not
  bytes — the first run of this very benchmark failed its own sanity check on
  a multibyte payload. The protocol spec must size frames in bytes.
