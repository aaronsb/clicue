# clicue — specification (draft)

> Status: **draft — findings, not decisions.**
> Captured 2026-07-28 from an evaluation session.
>
> Every claim below is tagged:
> **[MEASURED]** reproduced on this machine · **[DOCUMENTED]** from a manual/source
> · **[OBSERVED]** seen but not systematically verified · **[ASSUMED]** reasoned,
> **not tested — treat as a hypothesis to break, not a constraint to design around.**
>
> Architecture is deliberately **not** decided. See *Experiments to run first*.

## What this is

Live, contextual command guidance for the shell — the IntelliSense pattern applied
to the CLI.

As you type, a **cue card** renders below the prompt: candidates with real one-line
descriptions, narrowing with every keystroke. The goal is the hybrid of *typing a
command*, *getting it right the first time*, and *having contextual help
pre-render what you were probably reaching for* — without leaving the line editor.

## Vocabulary

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

## Design values

These are *constraints on acceptable solutions*, derived from failure modes we
observed directly. They are not assumptions about implementation, and they should
survive whatever the experiments say about architecture.

### 1. Not a completion engine — a decorator over one

Completion engines are hard. zsh's compsys represents many people iterating and
fine-tuning over decades. clicue does not reimplement any of that; it consumes the
output.

Authority splits cleanly:

| Question | Owner |
|---|---|
| Which candidates are valid *here*? | the completion engine |
| What does a candidate *mean*? | the corpus |

The completion engine is context-aware — it knows `cherry-pick` is a git
subcommand, that this argument position wants a branch, that this flag takes a
file. That is the part that took decades and must not be rebuilt.

The corpus earns its keep even where compsys already carries a gloss: compsys
descriptions are completion metadata, not documentation — terse and inconsistent
by design — and they will never cover locally authored tools. **[MEASURED]** 43 of
the 172 commands actually used on this machine have no gloss from any upstream
source.

### 0. Do not integrate with a mechanism that never agreed to be integrated with

The most expensive lesson of the prototype, and it comes before the others.

clicue spent a long session co-tenanting `POSTDISPLAY` with zsh-autosuggestions.
Both write that string for the same purpose — proposing what the operator probably
wants. autosuggestions has no notion of a second writer, so every interaction cost
a new dependency on its private internals:

| Mitigation | What it required knowing |
|---|---|
| yield before accept widgets | its `ACCEPT_WIDGETS` / `PARTIAL_ACCEPT_WIDGETS` lists |
| install at first `precmd` | that it defers its own widget rebinding |
| re-compose after the async writer | that it computes suggestions via `zle -F`, and that its `USE_ASYNC` flag is tested for existence rather than value |

Three reverse-engineered surfaces, each able to change without warning, and the
symptom the operator actually saw — grey ghost text and broken card rendering —
never stopped recurring in a new form.

The fix was not a fourth mitigation. It was to **stop integrating**: disable
autosuggestions and let clicue own ghost text outright, which it was already
half-doing. All three mitigations became dead code in one move.

The generalisable rule: *integrating someone else's complex mechanism into your own,
where the first party never agreed to the integration, ends in complexity and wasted
time.* Duplicated purpose is the tell — two components doing the same job for the
same reason will fight, and no amount of care at the seam fixes that. Pick one.

This is also the sharpest available argument about the render surface. Borrowing
`POSTDISPLAY` from ZLE is a milder instance of the same mistake: ZLE never agreed
to share it either.

### 2. Compose, don't capture

Every tool in this space we examined captures something it did not need to:

| Tool | What it captured | **[MEASURED]** |
|---|---|---|
| zsh-autocomplete | the `:completion:*` zstyles wholesale — `completer` and `matcher-list` replaced, not extended | ✓ |
| oh-my-posh | bound `zle-line-init` directly instead of via `add-zle-hook-widget` | ✓ |
| IRIS | the entire terminal, via a pty wrapper | ✓ |

The contract clicue should hold itself to:

- register through `add-zle-hook-widget`; never `zle -N` a hook someone else owns
- tag `region_highlight` entries with `memo=clicue` so it coexists with
  syntax-highlighting
- configure through `zstyle ':clicue:*'` — the native idiom
- **never touch `:completion:*`**

The payoff is pluggable candidate sources. compsys, `$commands`, `$aliases`,
history — and equally carapace, Fig specs, or anything emitting
`name / gloss / source`. The renderer should be usable without our corpus, and the
corpus without our renderer.

### 3. Themes are legibility, not decoration

The IRIS look is a starting point, not the goal. Different people need different
visual encodings — contrast, density, color-blind-safe hues, or dropping color
entirely in favour of weight and glyph. A theme system is an accessibility
surface, and should be designed as one rather than as a skin.

### 4. Make the cheap path correct — don't add information

Expertise is **recognition, not recall**. An operator knows `gcc` exists and that
some flag does the thing they want; they do not hold 200 flags in memory. They run
`--help`, skim, take the first plausible answer, and move on. That is rational
satisficing, not a deficiency to compensate for.

`--help` fails not by lacking information but by being a **context switch** — you
leave the line you were composing, scan a wall, and return having lost your place.

So the goal is *not* to inform more. It is to make the cheap path — glance,
recognize, continue — land on the right answer more often. These are different
targets, and optimizing for the first damages the second: a card showing
everything is `--help` in a box, now also in your way.

Constraints that follow:

- **Ranking beats completeness.** Six well-chosen cues beat forty exhaustive ones.
  The card's job is to make the top three right.
- **Density is inversely proportional to attention.** Scanning six candidates →
  terse. Narrowed to one → the selected row can afford much more, because
  attention is already committed. This applies to *presentation*, not storage.
- **Agent-written corpus entries will drift verbose.** Thoroughness is the default
  failure mode of generated text. The enrichment prompt must fight it — but toward
  *the natural weight of a good gloss*, not toward an arbitrary word count.

#### Gloss length: measured, not prescribed **[MEASURED]**

| Corpus | n | mean | median | p90 | max |
|---|---|---|---|---|---|
| whatis / mandb | 31,788 | 35 | 35 | 53 | **57** |
| compsys `_git` | 445 | 35 | 34 | 60 | **139** |

Two independent corpora converge on **~35 characters** with no coordination. That
is what a good gloss naturally weighs; it emerges rather than needing enforcement.

The `max` column is the instructive part. whatis stops at 57 because mandb's
format truncates there — a **storage artifact, not an editorial judgment**.
compsys has no cap and reaches 139 when a command needs it. Given room, the richer
corpus uses it.

Therefore:

- **No hard length cap in the corpus.** The tail is sometimes real.
- **The corpus must not be shaped by any one head's column budget** — that is
  exactly the coupling the component seams exist to prevent. Store what is useful;
  let the presenter decide what to show.
- **Wrap, don't truncate.** Vertical space is cheap and terminals are rarely narrow
  for long. `Git extensions to provi…` is strictly worse than two lines.
- Corpus entries may be **tiered** — a one-line gloss plus a fuller description —
  so presenters can choose depth by available space and attention state.

---

## Components

A decomposition, not an implementation plan. The seams matter more than the parts:
the second head (see `MOTIVATION.md`) is a north star whose job is **architectural
discipline** — designing as though it exists keeps the separations honest without
committing to build it.

| # | Component | Responsibility |
|---|---|---|
| 1 | **Presentation engine** | on-screen formatting; the cue card. One *head* among possible heads. |
| 2 | **Corpus** | what a candidate means. Built and maintained over time. |
| 3 | **Candidate source adapter** | asks the completion engine what is valid *here*; normalizes its output |
| 4 | **Hooks / integration** | ZLE wiring — when we are called, where we may draw |
| 5 | **Tuning** | ordering and relatedness (see below) |
| 6 | **Enrichment pipeline** | fills corpus gaps; batch, background, agent-assisted |

Notes on seams:

- **3 and 4 are separate on purpose.** ZLE wiring and completion-engine adaptation
  change for different reasons; splitting them is what lets carapace, Fig specs or
  anything else slot in without touching the editor integration.
- **2 and 6 are separate runtimes.** Corpus *lookup* is hot-path and
  latency-critical; corpus *building* is batch and occasionally invokes an agent.
  Same data, opposite constraints.
- **1 is the replaceable head.** Corpus and tuning are the body and should not
  know what is rendering them.

**Ecosystem:** zsh first — a deliberate starting point, not an exclusion.

### Where the card's authority ends **[decided in prototype]**

The card and zsh's own completion menu present the same candidates. Showing both
is strictly worse than showing either — the operator gets a styled card stacked
above a wide, unstyled listing of its own contents.

So the boundary is by **position**, not by mode:

| Context | Owner |
|---|---|
| Command position (first word) | **clicue** — the card is the completion UI; Tab accepts the highlighted cue |
| Arguments, paths, flags | **compsys** — card is not shown, Tab delegates untouched |
| zsh menu selection active (`KEYMAP == menuselect`) | **compsys** — card stands down entirely |

This is not a capture: no `:completion:*` zstyle is touched, and Tab delegates to
whatever it was previously bound to whenever the card is not showing. The card
simply owns interaction *while it is on screen*.

The boundary moves outward only when the candidate-source adapter (component 3)
can drive compsys — at which point the card can present argument and flag
candidates too, still rendered by clicue and still sourced from compsys.

### Tier 2 is menuselect in our visual language **[decided in prototype]**

The operator's own framing, and it settles what looked like a contradiction.

Tier 2 renders as a **column grid** (column-major, as zsh's own listing does) with
a one-line gloss bar beneath it for whatever is highlighted. Hundreds of
candidates in a single scrolling column is poor UX; a grid shows an order of
magnitude more at a glance, and the gloss bar keeps descriptions without
spending a column on them.

Inside the grid, **plain arrows navigate** — including Up/Down, which the
plain-arrow invariant otherwise forbids. That is not an exception to the
invariant; it is the same contract zsh's own `menuselect` has always had:

- the grid is a **mode**, entered deliberately by scrolling past the end of tier 1
- while in it, arrows address the grid
- on leaving it, every arrow delegates untouched to whatever owned it before

Focus is *derived* from the selection index rather than toggled, so there is
nothing to enter and nothing to remember. `_clicue_install_arrows` captures the
prior binding per key and delegates whenever the grid does not have focus — so
`history-substring-search-up` still owns Up in every other situation.

### POSTDISPLAY height: constraint or not? **[ASSUMED — being re-tested]**

**Status changed 2026-07-28.** The padding that enforced constant height has been
removed at the operator's request, so the card now sizes to its content. This
deliberately re-tests the claim below, which was never isolated.

The honest account: a visual bug was reported (the second card drawing over the
first), constant height was *inferred* as the cause, and making the height
constant appeared to resolve it. That is correlation, not diagnosis — the same fix
also stabilised several other things at once.

If display mangling returns while typing narrows the candidate set, the inference
was right and padding must come back. If it does not, the constraint was imaginary
and cost real UX (blank filler rows in every small card).

The claim as originally recorded follows.

### POSTDISPLAY must be constant height **[ASSUMED]**

A second POSTDISPLAY defect, found via a visual bug: Alt+Down made the second
card draw *on top of* the first rather than below it.

Cause: the gloss bar was rendered only when the selection sat in the grid, so
crossing the tier boundary grew the card by two lines mid-redraw. **ZLE mishandles
a POSTDISPLAY that changes height**, painting the taller content over the shorter
rather than reflowing.

First fix rendered the gloss bar unconditionally, which stabilised height *within*
a prefix. Insufficient: height still varied *across* prefixes — 21 lines for `g`,
9 for `claude` — so it mangled as the operator typed and the candidate counts
changed.

Real fix: the card has a **fixed total line budget** (`zstyle ':clicue:*'
max-lines`, default 14) which both boxes divide and pad into.

```
both tiers:   border + r1 + border + r2 + hint + gloss + close   = r1 + r2 + 5
tier 1 only:  border + r1 + hint + gloss + close                 = r1 + 4
```

Two numbers that are easy to conflate and must stay separate: a box's **layout**
rows come from its content (so few grid items spread across columns instead of
stacking in one), while its **allocation** is padded to a constant. Verified
identical at 14 lines across nine prefixes × three selection positions.

This is a hard constraint on any POSTDISPLAY-based renderer — **the card cannot
grow or shrink in response to state**, so every layout decision must be made
against a fixed budget rather than to fit content. It stacks with the
single-tenancy finding below.

### POSTDISPLAY is single-tenant **[MEASURED]** — the strongest evidence yet

The composability contract works for two of the three shared resources ZLE
exposes, and fails on the third:

| Shared resource | Multi-tenancy affordance | Verdict |
|---|---|---|
| ZLE hooks | `add-zle-hook-widget` — a real registry | ✓ works; clicue, syntax-highlighting and zsh-autocomplete coexisted |
| `region_highlight` | `memo=token` tagging | ✓ works; spans are separable and removable |
| **`POSTDISPLAY`** | **none** | ✗ **a bare string with no ownership convention** |

zsh-autosuggestions accepts a suggestion by doing, literally:

```zsh
BUFFER="$BUFFER$POSTDISPLAY"
```

It assumes the whole of `POSTDISPLAY` is its own. With the cue card appended
there, pressing Right Arrow shovelled the entire multi-line card into the
command buffer.

**Mitigation applied:** wrap every widget known to consume `POSTDISPLAY`
(`forward-char`, `end-of-line`, the vi equivalents, the partial-accept word
widgets), strip *our* card, then delegate. This must be installed at first
`precmd` — zsh-autosuggestions defers its own widget rebinding until then, so
wrapping at source time captures the bare builtin and leaves autosuggestions
wrapping *us*, reading `POSTDISPLAY` before we can clear it.

**A third consumer: the async writer [MEASURED].** zsh-autosuggestions computes
suggestions *asynchronously* by default — it sets `ZSH_AUTOSUGGEST_USE_ASYNC` to
the empty string and then tests only for the parameter's **existence**, so async
is on even though the value looks falsy. The result arrives through a `zle -F` fd
handler at an arbitrary moment, frequently *after* `line-pre-redraw` has already
composed the card, and writing `POSTDISPLAY` there destroys it.

Symptom: the card vanished on roughly **alternate keystrokes** — whichever writer
landed last won. Diagnosed from the operator's own hypothesis that keys were being
consumed by a race; the state log had already ruled out every synchronous
explanation by showing a correct card composed on every single keystroke while the
screen disagreed.

Mitigation: wrap `_zsh_autosuggest_async_response` and re-compose after it. Forcing
synchronous mode would also work but puts a history search on every keystroke.

**Why this matters beyond the bug.** The mitigation is fragile by construction:
it depends on knowing the private widget list of another plugin, and it breaks
whenever that plugin adds one or another `POSTDISPLAY` consumer appears. There
is no protocol to negotiate with, only a convention to guess at.

This is the strongest argument so far for **owning the render surface** rather
than borrowing `POSTDISPLAY` — not for the italic/hyperlink reasons originally
supposed, but because the borrowed resource has no multi-tenancy story at all.
A card drawn into a region clicue manages itself would have no such conflict,
and would not need to know that zsh-autosuggestions exists.

Still not a decision — it is one input, and the mitigation does work. But it
inverts the earlier reasoning: the render-surface question is now driven by
**composability**, which is a design value, rather than by escape-sequence
richness, which was an untested assumption.

### Terminal-level key conflicts are a real constraint **[MEASURED]**

Card scrolling was first bound to Shift+Arrow. The widget worked correctly —
verified in a pty — but **konsole binds Shift+Up/Down to Scroll Line Up/Down at
the terminal level**, consuming the keystrokes before any shell process sees
them. Moved to Alt+Arrow.

Two consequences worth carrying:

- No architecture avoids this. A pty wrapper would be equally blind — the
  terminal intercepts before *any* process it hosts.
- Bindings will therefore vary by terminal, which makes advertising them in the
  card's hint line load-bearing rather than decorative.

Diagnostic: `cat -v`, press the key. Nothing printed means the terminal ate it;
a sequence printed means it reached the shell and the binding is at fault.

### Tuning is two jobs

| Job | Nature | Tension |
|---|---|---|
| **Frequency ranking** | you use `git commit` constantly → it sorts first | none; pure optimization of the cheap path |
| **Relatedness** | surface commands you *don't* invoke but might want | **conflicts with design value 4** — this is adding information |

Relatedness is valuable (you only ever improve at what you already do) but cannot
live on the main card without diluting the top three with noise in service of
occasional teaching. Likely a separate mode or an explicit gesture — *"what else
could do this?"* — rather than a default. **First real tension between two things
we both want; unresolved.**

### Statistics: derive, don't instrument

A tuning layer that records command usage is structurally a thing that records
everything you type — the exact critique we levelled at IRIS. It is avoidable.

**The frequency data already exists in shell history.** The 172-distinct /
43-undescribed measurements in this document came from `~/.zsh_history` with no
instrumentation.

Deriving rather than collecting means: zero new collection surface; data stays
under controls the operator already owns; `HIST_IGNORE_SPACE` already works as a
per-command opt-out (space-prefix and it never enters the corpus's view); and it
stays inspectable with `grep`.

A tool that watches your terminal and writes its own usage database must be
trusted. One that reads a file you already curate need not be.

#### But history frequency ≠ usage frequency **[MEASURED]**

This operator's `10-history` sets `HIST_IGNORE_ALL_DUPS` (and `HIST_SAVE_NO_DUPS`).
Every unique command line therefore appears in history **exactly once**, no matter
how many times it was run. `ls -lat` scores 1 despite being habitual.

What history counting actually measures is **the number of distinct command lines
containing a token** — a proxy that systematically under-weights the commands run
most identically, which are precisely the most habitual ones. It still works
directionally (`git` outranks everything because it appears with many different
argument strings; `git clone` scores 28 across 28 distinct lines) but the
distortion is real and in the worst possible direction.

**Recency is the undistorted signal.** De-duplication keeps the *newest*
occurrence, so history order survives intact even where counts do not. Under
these options recency is strictly more reliable than frequency, and the operator's
own instinct — *"the last -property I used is proposed"* — is a recency rule, not
a frequency one.

Open: whether ranking should be recency-weighted, frequency-weighted, or a decay
blend. Not yet decided; the prototype currently ranks on raw frequency and is
therefore known-wrong for habitual commands.

---

## Lineage

Worth stating plainly: this is **restoration, not invention**. Interactive systems
did this well and the CLI regressed from them.

- **TOPS-20 `COMND` JSYS** (mid-1970s) — system-level command parsing available to
  every program, where `?` listed valid options *with descriptions* and ESC
  completed. The actual ancestor of shell completion, with help text built in from
  the start rather than bolted on.
- **Genera / CLIM** on Lisp Machines — *presentation types*: displayed output
  retained its semantic type and stayed live and directly actionable. The
  hyperlink idea, decades early and more general.
- **MULTICS**, **VMS DCL** — same family; structured command definitions with
  integrated help.

**[ASSUMED]** — these are recollections offered as design references to mine, not
verified history. Specifics should be checked before any of it is repeated as
fact. The value is directional: prior art exists, it was good, and it is worth
reading before designing.

---

## Findings: the data layer

Measured 2026-07-28, Arch Linux, zsh 5.9.2. **This section is the solid part of
this document.**

### The corpus already exists **[MEASURED]**

| Source | Scope |
|---|---|
| `whatis` / mandb index | **31,788** entries, precompiled, distro-maintained |
| zsh compsys completion functions | **1,107** functions; **876** (79%) carry descriptions via `_describe`/`_arguments` |
| `_git` alone | **445** described entries |

Quality is good and disambiguating:

```
cherry:'find commits not merged upstream'
cherry-pick:'apply changes introduced by some existing commits'
```

### Coverage against installed commands **[MEASURED]**

| Tier | Count | % of installed |
|---|---|---|
| Installed commands on `$PATH` | 6,173 | — |
| Have a `whatis` description (§1/8) | 3,378 | 54.7% |
| Have a compsys completion function | 453 | 7.3% |
| **Base corpus (either source)** | **3,439** | **55.7%** |
| Raw gap | 2,734 | 44.3% |

### The gap collapses when weighted by usage **[MEASURED]**

The raw gap is mostly things nobody types — `pw-encplay`,
`x86_64-pc-linux-gnu-gcc-16`, `ibfindnodesusing.pl`, `xembedsniproxy`.

Cross-referenced against real shell history:

- **172** distinct commands ever used
- **43** of those have no description from any source

Those 43 are locally authored tools no upstream corpus will ever cover: `kg`,
`ways`, `claude`, `dotfiles`, `mmm`, `cookiedumper`, `qrc`, `posh-theme`,
`attend`, `otp`, `askd`, `agent`, `transcribbler`, `yay-friend`, …

**This is the central scoping result**, and it is measured, not assumed: the
enrichment job is ~43 descriptions on a typical machine, not 2,734.

### Corpus pipeline — sketch, not design **[ASSUMED]**

```
  base corpus            scan installed          diff
  (whatis + compsys) ──> commands on PATH ──> undescribed set
                                                    │
                                                    ▼
                                          agent enrichment
                                                    │
                                                    ▼
                                       stamped corpus entry
```

Stamp the binary (version / mtime / checksum — undecided) so entries are only
re-derived when it changes. Everything about precedence, format, storage and
transport is **open** — see *Open questions*.

---

## Findings: rendering

### What zsh's line editor supports **[DOCUMENTED]**

From `zshzle(1)`:

- `region_highlight` supports exactly `fg=`, `bg=`, `bold`, `standout`, `underline`.
  **No italic** — zero occurrences in the manual.
- `POSTDISPLAY` explicitly supports newlines: *"to display a complete line, a
  newline must be prepended explicitly."* Multi-line is a supported use.
- `region_highlight` spans cover `POSTDISPLAY`, and support `memo=token` (zsh > 5.8;
  we have 5.9.2) so plugins can coexist without clobbering each other.

### What fzf supports **[MEASURED]**

`--ansi` for color codes. No mention of hyperlinks or OSC 8 in `--help` or the man
page.

### The untested claim that must not become a constraint **[ASSUMED]**

> Raw escape sequences (e.g. OSC 8 hyperlinks) embedded in `POSTDISPLAY` will
> corrupt ZLE's display-width accounting and misdraw the card.

This follows from ZLE counting display width over `POSTDISPLAY` contents, but it
was **never tested**. It is the single claim that would push toward owning the
render surface, so it deserves an experiment before it shapes anything.

**A cheaper possibility that may make it moot [OBSERVED]:** konsole (and others)
auto-detect URLs and file paths in **plain text** and make them clickable — no
escape sequences involved. If that covers the cases we care about, clickable paths
cost nothing and the constraint disappears. Untested; see experiments.

### Capability matrix — mixed confidence

| Capability | ZLE `POSTDISPLAY` | fzf / fzf-tab | zsh-autocomplete | Self-rendered TUI |
|---|---|---|---|---|
| Live, per keystroke | ✓ [DOCUMENTED] | ✗ Tab only | ✓ [OBSERVED] | ✓ |
| fg/bg/bold/underline/inverse | ✓ [DOCUMENTED] | ✓ | ✓ | ✓ |
| Italic | ✗ [DOCUMENTED] | ✓ [ASSUMED] | ✗ | ✓ |
| OSC 8 hyperlinks | ? **[ASSUMED ✗]** | ✗ [MEASURED] | ? | ✓ |
| Auto-linkified plain text | ? [OBSERVED] | ? | ? | ? |
| Border control | limited [ASSUMED] | ✓ | limited | ✓ |
| compsys descriptions | needs building | ✓ | ✓ [OBSERVED] | needs wiring |

---

## Architecture

**Not decided. Deliberately.**

Nothing above justifies choosing an architecture yet. The pty wrapper is *not*
rejected on technical grounds — it is disliked for blast radius, which is a
preference, not a finding. A ZLE-native approach, a helper process drawing below
the prompt, and a pty wrapper are all live until the experiments below say
otherwise.

Committing now would foreclose designs we have not looked for.

---

## Experiments to run first

Ordered by how much they would change the design.

1. **Does OSC 8 actually break `POSTDISPLAY`?** Emit a hyperlink escape inside a
   multi-line `POSTDISPLAY` and observe whether the card misdraws, and how badly.
   Resolves the claim the whole architecture question hangs on.
2. **Does konsole auto-linkify plain text in a ZLE-drawn region?** If yes, much of
   the hyperlink requirement may be free.
3. **How rich can a `POSTDISPLAY` card actually get?** Build a throwaway multi-line
   box with borders, colors, and inverse badges. Find the real ceiling by hitting
   it rather than by reading the manual.
4. **Region ownership under stress.** Whatever draws below the prompt: what happens
   on scroll at screen bottom, on resize, on oh-my-posh repaint? Likely the
   hardest problem regardless of architecture.
5. **Can compsys be driven per-keystroke at acceptable latency?** zsh-autocomplete
   does it asynchronously and is worth studying. Measure before assuming it is
   expensive.
6. **Is the cue card even wanted at 1 character?** Typing `g` matches ~100
   candidates. Find the input threshold empirically.

---

## Design language

Inherited from IRIS's overlay (0BSD, no attribution required) — the **Aura**
palette. Two-hue semantic scheme: **purple = static/defined, mint = you/your
behavior.** A starting point to react against, not a decision.

| Role | Hex |
|---|---|
| Border / primary | `#a277ff` |
| Accent / match / candidate name | `#61ffca` |
| Text / selected text | `#edecee` / `#ffffff` |
| Gloss / selected gloss | `#9692a8` / `#edecee` |
| Selection background | `#3d375e` |
| Ghost text | `#4B4A4C` |

Source badges invert on selection — the nicest detail in IRIS's UI:

| Badge | Unselected (bg/fg) | Selected (bg/fg, bold) |
|---|---|---|
| `alias` | `#2a2342` / `#a277ff` | `#a277ff` / `#110f18` |
| `history` | `#1a2d36` / `#61ffca` | `#61ffca` / `#110f18` |
| `system` | `#1e1d28` / `#a277ff` | `#a277ff` / `#110f18` |

---

## Prior art evaluated

### IRIS (`github.com/versenilvis/IRIS`) **[MEASURED]**

0BSD, Go, single pseudonymous author, ~3.5 months old. Audited 2026-07-28: no
telemetry (verified — 3 network egress points, all user-initiated), AI off by
default, thoughtful prompt-injection fencing. Not malicious.

Concerns found:
- pty wrapper: `exec iris` from `.zshrc`, wrapping the shell as a child
- ~600 hand-transcribed command specs vs zsh's 1,107 maintained ones
- debug mode logs every raw stdin byte to a world-readable `0644` log, and the
  documented bug-reporting flow tells users to enable it and attach the result
- no release checksums or signatures; `iris update` is `curl | sh` from main HEAD

The UX is validated — the live-narrowing pattern is what started this project.

### zsh-autocomplete **[MEASURED]**

Delivers the live loop convincingly; currently running as a reference
implementation.

- **Broken out of the box** on zsh 5.9.2: rebuilds `compadd` by round-tripping the
  function body through text, and that body contains `#` comments which fail to
  re-parse without `setopt interactivecomments`. Verified with a control (+14
  parse errors without, 0 with). [Upstream #761](https://github.com/marlonrichert/zsh-autocomplete/issues/761).
- Opinionated: takes over the completion zstyles wholesale.

Worth studying for its async compsys driver.

### fzf-tab

Uses the real completion functions and themes well, but is Tab-triggered.
Not yet trialled.

---

## Open questions

Everything in *Experiments to run first*, plus:

1. Implementation language — Go, Rust, or as much zsh as possible.
2. Shell scope — zsh first is obvious; is bash/fish a goal or a non-requirement?
3. Corpus format, location, and precedence between sources.
4. Stamp granularity for invalidation.
5. Agent enrichment transport, and whether it is optional at all (base corpus alone
   covers 55.7% of installed and ~75% of *used* commands).
6. Latency budget before rendering without compsys results.

## Non-goals

- Reimplementing zsh's completion engine. clicue should *present* compsys.
- Hand-authoring command specs.
- Telemetry of any kind.
