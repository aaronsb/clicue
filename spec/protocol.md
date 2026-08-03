# Protocol — shim ↔ daemon

The seam ADR-100 creates. Evidence: `experiments/02-shim-ipc-latency/`
(round trip p50 25 µs / p99 57 µs for a card-sized reply, ~6× cheaper than
one fork [MEASURED]). Everything here is [domain] unless tagged otherwise.

## Transport

1. Per-user Unix stream socket at `$XDG_RUNTIME_DIR/clicue.sock`, falling
   back to `$XDG_CACHE_HOME/clicue/clicue.sock` when `XDG_RUNTIME_DIR` is
   unset. Mode 0600; the daemon refuses to serve a socket whose parent
   directory is writable by another user.
2. Framing is newline-delimited JSON: one request line in, one reply line
   out. No length prefix — the spike showed none is needed. Frame limits are
   counted in **bytes**; zsh `${#var}` counts characters and must never be
   used as a frame size. [zsh-hazard, stays: the shim reads frames]
   [MEASURED: the spike's own sanity check failed on this]
2a. One frame is capped at `MAX_FRAME` (1 MiB, defined once in
   protocol.rs). An oversized frame gets an error frame naming the limit,
   then the connection closes — resync inside an overlong line is
   impossible, and reconnect costs 49 µs. Unbounded reads measured 266 MB
   RSS from one connection on review of PR #5. [MEASURED]
3. The shim holds one persistent connection per shell. On error it may
   reconnect once per event; reconnect worst-case is 0.26 ms [MEASURED], so
   no pooling or retry sophistication is warranted.
3a. The daemon is a singleton per socket, enforced by an flock'd lockfile
   beside the socket (`clicue.lock`) held for the daemon's lifetime. The
   connect-probe alone loses the start race — measured: 6 concurrent
   starts against a stale socket yielded two live daemons [MEASURED] — and
   §9's auto-spawn fires N times at once when a multiplexer restores a
   session. A pre-existing path that is not a socket is never removed.

## Request

4. One request per ZLE event, sent by the shim with no local decision
   logic. Fields: `buffer`, `cursor`, `cols`, `lines`, `keymap`, `event`
   (redraw | key name | line-finish), `pending` (compsys harvest payload,
   present only on the event that produced one), and `session` (shell PID +
   start time, so the daemon can key per-shell state like selection and
   engagement).
4b. The first event of a session is `hello`, carrying `env`: the alias
   map (name → expansion), function names, and builtin names — the three
   name universes only a live shell can enumerate. The daemon walks
   `$PATH` itself. The prototype read these per keystroke from shell
   globals; once per session is enough because new aliases mid-session
   are rare and a fresh `hello` after `clicue-off`/on re-syncs.
4a. `cursor` travels in CHARACTERS — ZLE's `$CURSOR`, forwarded untouched;
   the daemon converts to bytes. Converting in zsh would put logic back in
   the shim, and an unstated unit here is the exact defect class §2
   records. Every offset in the REPLY is bytes (§7); the asymmetry is
   deliberate and this clause is its single statement.
5. The daemon owns the state machine: standdown, yield-tab, mode, selection,
   engagement, suppression. The shim never interprets buffer content.
   (Prototype provenance: the state globals of clicue.zsh:80–215 become
   daemon per-session state.)
5a. History freshness (resolves sources.md ambiguity D5): on `line-finish`
   the shim includes `hist`: `[event-number, line]` pairs appended to
   `$history` since the last number the daemon acked — read from
   `$history`, never from `$BUFFER`. A space-prefixed line never enters
   `$history`, so `HIST_IGNORE_SPACE` remains a free per-command opt-out;
   reading the buffer would re-propose deliberately hidden commands, the
   exact defect the prototype records at candidates.zsh:230–245. Every
   reply carries `ack`: the highest event number incorporated for the
   session, so the shim knows what to resend after a daemon restart and
   the mechanism is expressible on the wire. [domain]

## Reply

6. One reply per request: `card` (text to append to POSTDISPLAY, empty
   means no card), `ghost`, `spans` (byte-offset ranges with styles, relative
   to the appended text), and `action` for key events (consume | delegate |
   insert {text} | yield), mirroring the delegation contract the prototype's
   widgets implement in-shell.
7. Span offsets are in CHARACTERS of the reply's card text — amended from
   bytes once the shim was designed: region_highlight is character-indexed,
   and byte→char conversion in zsh would be real decision logic in the one
   component specified to have none. The daemon converts (trivial in Rust),
   the same division as `cursor` in §4a. Frames themselves stay
   byte-limited per §2/§2a.
7a. The shim must never strip from the head of a reply-sized string with
   `${j#*needle}`: zsh finds the shortest match by probing every prefix
   length, so the strip is quadratic in the needle's position — 433 ms
   against a 12 KB reply with the needle near the end, 617 ms for one full
   reply parse, felt as per-keystroke lag [MEASURED]. The linear idiom is
   `pre=${j%%needle*}` plus length arithmetic (0.24 ms on the same reply;
   the shim's `_clicue_cut`). Substring TESTS (`[[ $j == *needle* ]]`) and
   `%%` strips are linear and fine. [zsh-hazard]

## Failure

8. The shim applies a hard read deadline of 5 ms per event. On timeout,
   connection error, or absent socket: **no card, ever a degraded one** —
   POSTDISPLAY untouched, all keys delegate to their original owners. The
   prototype's design value 1 (no invisible fallback) promoted to a wire
   rule. A healthy daemon replies in <0.1 ms [MEASURED], so a fired deadline
   means the daemon is genuinely wedged, not slow.
8a. Closing the socket fd must be a BARE `exec {fd}>&-`: redirections on
   `exec` are permanent, so an error-suppressing `2>/dev/null` on that
   line rewires the shell's stderr to /dev/null for the session — every
   later command's errors silently vanish, in clicue's name [MEASURED
   2026-08-03: surfaced by the first RPC timeout after a config
   hot-reload; latent since the shim's first version]. [zsh-hazard]
9. The shim auto-spawns `clicue daemon` when it cannot connect, detached,
   output discarded — the corpus-refresh precedent (prototype
   corpus.zsh:138–149) — at most once per 30-second window. Amended from
   once-per-shell: the shell that had spawned the daemon could never
   revive it after a manual kill, stranding that terminal cardless for
   its lifetime [MEASURED 2026-08-03, `theme set` era]. The window keeps
   the original rule's intent — a crash-looping daemon costs one fork
   per window, never a hot loop — and repeat deaths still surface via
   `clicue doctor`.

## Versioning

10. Request and reply carry `v` (integer). The daemon probes `v` BEFORE
    parsing the full request — a bumped version means a changed shape, so
    shape-first parsing would report gibberish for the one case this frame
    exists to name. Mismatch → an error frame naming both versions; the
    shim goes silent (rule 8) and stashes the error for `clicue doctor`.
    The generated-shim model (`clicue init zsh`) makes mismatch a
    transient of mid-upgrade shells only.
11. Error frames never echo request content — a request is usually the
    operator's command line, and these frames are stashed (rule 10) and
    later shown by `clicue doctor`. Positions and limits only.
