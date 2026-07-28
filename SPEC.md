# clicue — specification (draft)

> Status: **draft**. Captured 2026-07-28 from an evaluation session.
> Nothing here is built yet. Measurements are real and reproducible;
> architecture is provisional and marked as such.

## What this is

Live, contextual command guidance for the shell — the IntelliSense pattern applied
to the CLI.

As you type, a **cue card** renders below the prompt: candidate commands,
subcommands, flags and paths, each with a real one-line description, narrowing
progressively with every keystroke. The goal is the hybrid of *typing a command*,
*getting it right the first time*, and *having contextual help pre-render what you
were probably reaching for* — without leaving the line editor or opening a manual.

## Vocabulary

The naming is theatrical and should stay consistent throughout the codebase:

| Term | Meaning |
|---|---|
| **clicue** | the tool (CLI + cue) |
| **cue card** | the overlay panel rendered below the prompt |
| **cue** | a single row on the card — one candidate |
| **gloss** | the description text attached to a cue |
| **corpus** | the description database backing the glosses |
| **prompter** | the resident process/engine that produces cues |

A theatrical prompter feeds an actor the line they are reaching for, before they
falter. That is the product.

## The core insight

There are two separable layers, and every existing tool gets exactly one right:

1. **Data** — what candidates exist here, and what do they *mean*
2. **Render** — how they are presented

- **IRIS** owns its render surface (good) but hand-authors ~600 command specs in
  Go (bad — half the coverage of what ships with zsh, and it will rot).
- **zsh** has an excellent, distro-maintained data layer (good) but its line editor
  cannot render richly (constrained — see the render ceiling below).

**clicue = zsh's data layer + an owned render surface.**

---

## Findings: the data layer

Measured 2026-07-28, Arch Linux, zsh 5.9.2.

### The corpus already exists

| Source | Scope |
|---|---|
| `whatis` / mandb index | **31,788** entries, precompiled, distro-maintained |
| zsh compsys completion functions | **1,107** functions, **876** (79%) carry descriptions via `_describe`/`_arguments` |
| `_git` alone | **445** described entries |

Quality is good and disambiguating. The exact case that motivated this project:

```
cherry:'find commits not merged upstream'
cherry-pick:'apply changes introduced by some existing commits'
```

### Coverage against actually-installed commands

| Tier | Count | % of installed |
|---|---|---|
| Installed commands on `$PATH` | 6,173 | — |
| Have a `whatis` description (§1/8) | 3,378 | 54.7% |
| Have a compsys completion function | 453 | 7.3% |
| **Base corpus (either source)** | **3,439** | **55.7%** |
| Raw gap | 2,734 | 44.3% |

### The gap collapses when weighted by usage

The raw 44% gap is almost entirely noise nobody types — `pw-encplay`,
`x86_64-pc-linux-gnu-gcc-16`, `ibfindnodesusing.pl`, `xembedsniproxy`.

Cross-referenced against real shell history:

- **172** distinct commands ever used
- **43** of those have no description from any source

And those 43 are exactly the ones no upstream corpus will *ever* cover, because
they are locally authored: `kg`, `ways`, `claude`, `dotfiles`, `mmm`,
`cookiedumper`, `qrc`, `posh-theme`, `attend`, `otp`, `askd`, `agent`,
`transcribbler`, `yay-friend`, …

**This is the central scoping result.** The enrichment job is ~43 descriptions on
a typical machine, not 2,734 — a nightly cron's worth of tokens, not a
corpus-building project.

### The corpus pipeline

```
  base corpus            scan installed          diff
  (whatis + compsys) ──> commands on PATH ──> undescribed set
                                                    │
                                                    ▼
                                          agent enrichment
                                          (--help, man, README)
                                                    │
                                                    ▼
                                       stamped corpus entry
                                    {gloss, source, stamp}
```

**Invalidation:** each enriched entry records a stamp of the binary it describes
(version string, mtime, and/or checksum — TBD). An entry is only re-derived when
its stamp changes. Described entries are marked so the agent never re-describes
them, which is what keeps the steady-state token cost near zero.

**Precedence (provisional):** compsys > whatis > agent-enriched. Compsys entries
are context-aware (they know `git cherry-pick` is a subcommand of `git`); whatis
is command-level only; agent-enriched fills what neither has.

**Portability:** a machine can ship with the base corpus and build its extended
corpus locally, so bespoke tooling gets first-class descriptions without anyone
publishing them.

---

## Findings: the render ceiling

This is why the architecture must own its render surface.

| Capability | ZLE `POSTDISPLAY` | fzf / fzf-tab | zsh-autocomplete | Self-rendered TUI |
|---|---|---|---|---|
| Live, per keystroke | ✓ | ✗ (Tab only) | ✓ | ✓ |
| fg / bg / bold / underline / inverse | ✓ | ✓ | ✓ | ✓ |
| Italic | ✗ | ✓ | ✗ | ✓ |
| OSC 8 hyperlinks | ✗ | ✗ | ✗ | ✓ |
| Arbitrary border control | limited | ✓ | limited | ✓ |
| compsys descriptions | needs building | ✓ | ✓ | needs wiring |

### The hard constraint

`zshzle(1)` documents `region_highlight` as supporting exactly `fg=`, `bg=`,
`bold`, `standout`, `underline`. **There is no italic** (zero occurrences in the
manual) and no escape-sequence passthrough.

Worse: `POSTDISPLAY` is a *text buffer with a span-coloring overlay*, not a canvas.
ZLE computes display width over its contents, so embedding raw escape sequences
(as OSC 8 hyperlinks require) corrupts that math and misdraws the card.

**Hyperlinks are therefore not a styling gap — they are an architectural one.**
Anything emitting OSC 8 must own its render surface and do its own width
accounting. Since clickable file paths and `man`/doc URLs on the cue card are a
requirement, this decides the architecture.

Confirmed capable of note:
- `POSTDISPLAY` *does* support newlines (documented) — multi-line is supported, just
  not richly styleable.
- `region_highlight` supports `memo=token` (zsh > 5.8; we have 5.9.2), so multiple
  plugins can coexist without clobbering each other.

---

## Architecture (provisional — not decided)

Requirement: own the render surface, without owning the user's process tree.

- **Rejected:** pty wrapper (IRIS's choice). It works, but `exec`ing the shell
  inside a wrapper is a large blast radius for a completion UI, and it is not
  required to own a screen region.
- **Candidate:** a helper process driven from a ZLE `zle -F` async handler,
  drawing into the region below the prompt with its own escape sequences and
  width accounting, while ZLE stays out of that region.

Open: how to reserve and reclaim the region cleanly across terminal scroll,
resize, and prompt redraw (oh-my-posh repaints). This is the main technical risk
and should be prototyped before anything else.

### Driving compsys without Tab

compsys is rich *because* it is expensive — 1,107 lazily-autoloaded functions that
fork subprocesses (`git branch`, `docker ps`) for context-aware candidates. It is
designed to run once, on demand.

zsh-autocomplete solves this by running completion asynchronously. That approach is
proven and should be studied. The cheap in-memory sources (`$commands` 6,173,
`$functions` 1,250, `$aliases`, builtins/reswords 136, plus history) can drive the
card at zero fork cost, with compsys results merged in asynchronously as they
arrive.

---

## Design language

Inherited from IRIS's overlay (0BSD, no attribution required) — the **Aura**
palette. Two-hue semantic scheme: **purple = static/defined, mint = you/your
behavior.**

| Role | Hex |
|---|---|
| Border / primary | `#a277ff` |
| Accent / match / candidate name | `#61ffca` |
| Text / selected text | `#edecee` / `#ffffff` |
| Gloss / selected gloss | `#9692a8` / `#edecee` |
| Selection background | `#3d375e` |
| Ghost text | `#4B4A4C` |

Source badges invert on selection — the nicest detail in IRIS's UI and three lines
of ANSI:

| Badge | Unselected (bg/fg) | Selected (bg/fg, bold) |
|---|---|---|
| `alias` | `#2a2342` / `#a277ff` | `#a277ff` / `#110f18` |
| `history` | `#1a2d36` / `#61ffca` | `#61ffca` / `#110f18` |
| `system` | `#1e1d28` / `#a277ff` | `#a277ff` / `#110f18` |

Beyond this: italic for glosses, inverse for matched substrings, OSC 8 hyperlinks
on file paths and doc URLs (konsole, kitty, wezterm, Ghostty, iTerm2 all support
OSC 8).

---

## Prior art evaluated

### IRIS (`github.com/versenilvis/IRIS`) — UX validated, architecture rejected

0BSD, Go, single pseudonymous author, ~3.5 months old. Audited 2026-07-28: no
telemetry (verified — only 3 network egress points, all user-initiated), AI off by
default, thoughtful prompt-injection fencing. Not malicious.

Rejected because:
- pty wrapper: `exec iris` from `.zshrc`, wrapping the shell as a child
- ~600 hand-transcribed command specs vs zsh's 1,107 maintained ones
- debug mode logs every raw stdin byte to a world-readable `0644` log, and the
  documented bug-reporting flow tells users to enable it and attach the result
- no release checksums or signatures; `iris update` is `curl | sh` from main HEAD

Taken from it: the UX pattern, the Aura palette, the source-badge idea.

### zsh-autocomplete — closest existing thing

Delivers the live-narrowing loop convincingly. Two problems:
- **Broken out of the box** on zsh 5.9.2: it rebuilds `compadd` by round-tripping
  the function body through text, and that body contains `#` comments which fail
  to re-parse without `setopt interactivecomments`. Every completion throws;
  nothing renders. Fixed by setting that option ([upstream #761](https://github.com/marlonrichert/zsh-autocomplete/issues/761)).
- Opinionated: takes over the completion zstyles wholesale.
- Render ceiling is zsh's (no italic, no hyperlinks).

Worth studying for its async compsys driver.

### fzf-tab — good, but Tab-triggered

Uses the real completion functions and themes well, but cannot be live, and fzf has
`--ansi` only (no OSC 8).

---

## Open questions

1. **Region ownership** — how to reserve/reclaim screen space below the prompt
   across scroll, resize, and prompt repaint. Main technical risk; prototype first.
2. **Implementation language** — Go (IRIS's choice, good TUI ecosystem), Rust, or
   as much zsh as possible. Affects distribution.
3. **Shell scope** — zsh first is obvious. Is bash/fish a goal, or a
   non-requirement? Affects how tightly we can couple to compsys.
4. **Corpus format and location** — sqlite? flat files? `$XDG_DATA_HOME/clicue/`?
5. **Stamp granularity** — binary mtime, `--version` output, or checksum.
6. **Agent enrichment transport** — how the pipeline invokes a coding agent, and
   whether that is optional (base corpus alone is 55.7% coverage, ~75% of *used*
   commands).
7. **Minimum input length** before the cue card appears — typing `g` matching 100
   candidates may be noise rather than signal.
8. **Latency budget** — compsys forks for context-aware candidates. What is the
   deadline before we render without them and fill in late?

## Non-goals

- Replacing zsh's completion engine. clicue *presents* compsys; it does not
  reimplement it.
- Hand-authoring command specs.
- Wrapping or replacing the user's shell process.
- Telemetry of any kind.
