---
status: Accepted
date: 2026-08-02
deciders:
  - aaronsb
  - claude
related: []
---

# ADR-100: Rebuild as a Rust daemon behind a generated zsh shim

## Context

The prototype (`prototype/`, ~3,700 lines of zsh) proved the product: live, contextual command guidance that cooperates with zsh instead of replacing it — compsys supplies candidates, ZLE hosts the card, plain arrows and Enter keep their meanings, and everything ranks against the operator's own history. It also proved the cost. A structural review (2026-08-02) found that roughly a third of the code's intellectual content defends against zsh-the-language rather than expressing the domain: pattern-vs-literal strip hazards, GLOB_SUBST traps, subscript gotchas, fork-budget contortions, character-count width math that miscounts wide glyphs. Those defenses are duplicated at every site the hazard recurs, and the review's top findings (a stamp implemented twice, a history scan that missed the window optimisation, a teardown that unbinds the wrong keys) are all drift between such copies.

The operator's goals for the real tool go beyond what pure zsh can carry: fuzzy matching at keystroke latency, a corpus that is inspectable and portable, a configurator for themes and collected data, an installer with a conflict-checking doctor, and column-correct Unicode rendering.

One boundary is fixed by physics, not preference: the integration surface — ZLE hooks, POSTDISPLAY tenancy, region_highlight, bindkey delegation, and the compadd shadow that harvests compsys — only exists inside a live zsh process. Flyline's incompatibility with other line-editing tools comes from replacing that layer; clicue's entire value is that it does not.

## Decision

Rebuild clicue as **one Rust binary** (`clicue`) containing a daemon and a CLI tool surface, driven by a **thin zsh shim that the binary generates**.

**The shim** (zsh, permanent, emitted by `clicue init zsh`): registers ZLE hooks and key widgets, writes POSTDISPLAY and region_highlight, captures compsys output via the compadd shadow, and delegates every key it does not own. It contains no decision logic: per keystroke it sends (buffer, cursor, COLUMNS/LINES, keymap, event) to the daemon and paints the reply. Generated, not copied, so shim and daemon versions cannot drift.

**The daemon** (`clicue daemon`, auto-spawned): owns everything else — corpus build and storage, history ingestion, ranking, flag cache, spelling grouping, layout, and rendering. It returns finished card text plus highlight-span offsets. State machine decisions (standdown, yield-tab, mode, selection, engagement) live here.

**The protocol**: newline-delimited JSON over a per-user Unix socket. The shim applies a hard read timeout (single-digit milliseconds); on timeout or a dead daemon the card is **absent, not degraded** — the prototype's design value 1 (no invisible fallback) promoted to a protocol rule. The shim never blocks typing.

**The tool surface** (subcommands of the same binary):

- `clicue init zsh` — emit the shim (the zoxide pattern).
- `clicue install` / `uninstall` — doctor first, then add/remove the one `eval "$(clicue init zsh)"` line, plugin-manager-aware, diff shown before writing. Uninstall restores captured original bindings.
- `clicue doctor` — probe a captive `zsh -i` (never parse config text) and report: genuine fighters (zsh-autocomplete, fzf-tab, other Tab owners), coexistence checks (zsh-autosuggestions wrap targets), silent degradations (no EXTENDED_HISTORY → recency dead, small HISTSIZE, missing whatis), terminal quirks (konsole eating Shift+arrows). Re-runnable anytime.
- `clicue config` — TOML in `$XDG_CONFIG_HOME/clicue/`, hot-reloaded by the daemon; kills the "zstyles must precede source" footgun.
- `clicue theme` — list/set/preview; themes are TOML; validation with fallback to a base that renders anywhere; glyph widths measured with `unicode-width` instead of policed by hand.
- `clicue data` — `status | rebuild | gc | clear | inspect <cmd> | forget <cmd|invocation> | export | import`. Everything remains derived from history, never instrumented; `HIST_IGNORE_SPACE` stays the free per-command opt-out and `forget` adds the retroactive one.

**Process**: the prototype is frozen as the reference implementation. A spec extraction pass harvests its invariants, each tagged **domain** (survives the rewrite: constant card height per buffer, COLUMNS−1, never bind plain arrows, legend advertises only live gestures, grouped-flags-before-raw-compsys ordering, the -S suffix trichotomy, recency-not-count for deduplicated history, …) or **zsh-hazard** (dies with the rewrite). A differential harness replays test.zsh scenarios against both implementations; cutover is per-feature, and the prototype retires when the diff is quiet.

## Consequences

### Positive

- The zsh-hazard third of the maintenance burden is deleted rather than serviced forever.
- Crate leverage replaces hand-rolled machinery: `unicode-width` (fixes the latent wide-glyph layout bug class), `nucleo`-grade fuzzy matching the fork budget currently forbids, serde/TOML config, SQLite or bincode corpus storage replacing the triple-pass awk builder.
- The stamp-duplication class of bug becomes structurally impossible: one process owns each fact.
- A real test story: unit tests on layout and ranking, differential tests against the prototype oracle.
- The tool surface (doctor, configurator, data management) becomes buildable; none of it fits in the pure-zsh design.

### Negative

- Distribution changes from "source one file" to a release binary per platform (the zoxide/atuin cost, mitigated by their now-standard patterns).
- A new failure seam exists at the socket: daemon lifecycle, timeout, and reconnect logic that the in-process prototype never needed.
- The compsys bridge remains zsh and remains subtle; its harvest results now cross a process boundary.
- Two languages in the repo until the prototype retires.

### Neutral

- The prototype stays in-tree (`prototype/`, `experiments/`) as oracle and documentation of measured behaviour; the operator's live shell sources a snapshot outside the repo, so development churn cannot break it.
- Rust over Go: both suffice; Rust chosen for the terminal/matcher crate ecosystem (`unicode-width`, `nucleo`) and the precedent stack (atuin, zoxide) whose integration patterns this design borrows.

## Alternatives Considered

- **Stay pure zsh and refactor** — fixes the review findings but keeps paying the zsh-hazard tax forever, and cannot deliver fuzzy matching, the doctor, or column-correct rendering within the fork budget.
- **Full line-editor replacement (the flyline model)** — rejected outright: incompatible with the cooperation contract that is clicue's reason to exist. Compatibility comes from joining ZLE, not owning it.
- **Helper binary without a daemon (fork per event)** — violates the keystroke fork budget the prototype measured its way to; a persistent process is the only shape that meets latency without in-shell logic.
- **Go instead of Rust** — viable, faster first draft; rejected on crate ecosystem fit and single-static-binary parity being equal anyway.
