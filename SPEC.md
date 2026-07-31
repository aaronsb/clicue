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
the ~170 commands actually used on the machine this was measured on have no gloss
from any upstream source.

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

### 1. No fallback may damage confidence in the UI

A fallback that silently changes behaviour is **worse than no fallback**. The
operator cannot distinguish working from broken, so trust in the whole surface
drops — not just in the path that fell back.

Found the hard way. Esc set a suppression flag that persisted until the line was
emptied, silently disabling the tool for the rest of that line with no indicator.
It was reported as clicue "occasionally dropping to the original completion
engine", intermittently and then not reproducibly — because it stopped recurring
as soon as a fresh line was started without pressing Esc. A full audit of every
zsh entry point found no residual; the cause was clicue's own designed behaviour.

Resolved by removing the persistence: Esc now dismisses for the **current buffer
only**, and typing brings the card straight back. Predictable, with no invisible
state to be surprised by.

The general rule: **any invisible mode in a live-feedback tool will be reported as
breakage**, because the operator has no way to attribute the change to their own
action. Either the state is visible, or it does not persist.

This constrains the remaining fallbacks too — Tab delegating to compsys outside
command position, and the card standing down on path-like input. Those are
acceptable because the *trigger is visible*: the operator can see they typed a
space or a slash. Suppression had no such tell.

**The same rule read from the other side: a legend that advertises a gesture which
does nothing damages confidence exactly as much as a hidden mode.** The operator
tries it, nothing happens, and they discount the whole legend — including the
segments that were true. So the hint line is *derived from live state* on every
render, not fixed at load: `↑↓ browse` appears only with more than one candidate,
`→ accept` only when a ghost stem exists, and an explanation-only card advertises
nothing but the way out. `dismiss` is the segment that survives every width, because
a narrow terminal that leaves the operator holding a card with no advertised exit is
this value's failure mode in its purest form.

This also settles what Tab *means*, which had drifted into looking like four
behaviours on invisible state. It is one rule — **Tab advances your position in the
candidate space** — whose outcome is a move when there is somewhere to move and an
insert when the highlighted cue is already the whole answer. Both outcomes are
knowable at render time, so the legend names which one applies (`Tab cycle` /
`Tab insert`) instead of leaving the operator to infer it from a `1/1` counter. The
verb is `insert` rather than `accept` because Tab's commit path runs the same code as
Enter, while `→ accept` takes the ghost — two different actions that must not share a
word. See `docs/design-notes/composition-and-comprehension.md`.

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
- **borrow from `:completion:*`, never keep.** This originally read "never touch",
  which is no longer true and was corrected rather than quietly left standing.
  clicue borrows exactly one style — `list-grouped`, for the duration of a single
  capture, restored in an `always` block so an aborting completer cannot leave the
  operator's own Tab menu regrouped. The distinction that matters is not whether a
  style is touched but whether anything is **left changed**: zstyle is compsys's
  own configuration API, and using it for the length of one call is composing.
  Overwriting the operator's `completer` and `matcher-list` wholesale, as
  zsh-autocomplete does, is capturing.

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

### 5. Decide vs. show — the boundary test

**compsys decides. clicue shows.**

| compsys decides | clicue shows |
|---|---|
| what matches | in what order |
| where the current word starts and ends | with what gloss |
| how a match is inserted — suffixes, quoting, `IPREFIX` | grouped how, laid out how |
| when a completer forks and what it costs | with what statistics from the operator's own history |

**A fix that requires knowing more about how compsys _decides_ is a signal to
delegate, not to model harder.** A fix about how information is _shown or ranked_
is ours.

This value was earned, not designed. Four consecutive fixes were all compsys-model
semantics rather than presentation: `compadd`'s clustered option grammar (`-ld`),
caller-supplied `-O`/`-A` probe calls, `list-grouped`'s effect on where a
description lives, and `IPREFIX`'s notion of the current word. Every one of those
is a documented API, so this is *not* the design value 0 situation — compsys agreed
to be driven. But the shape is the same, and the shape is the warning.

The operator named it before the code did: *"so we don't sink into rebuilding the
real completer in thousands of lines of bespoke zsh script, are we doing this the
right way?"* `clicue.zsh` had grown from 1,085 to 1,824 lines in one session.

Where the line actually falls, measured: the corpus, history ranking, gloss
pairing, cluster decomposition and the familiarity gate are all genuinely ours —
compsys provides none of them. **Candidate filtering and insertion are not.**

### Insertion drops semantics compsys already knows **[MEASURED — open defect]**

clicue computes `LBUFFER` itself, and is wrong in at least two ways:

```
git commit --fi   clicue: "git commit --file "     compsys carries -S= → "--file="
tar -             clicue: "tar -A "                tar's letters cluster; the
                                                   trailing space breaks "tar -Ac"
```

The second breaks the cluster-building the card exists to support. Also discarded:
`-q` (suffix removed on the next keypress), `-r` (removed on given characters),
quoting, and `IPREFIX` — which had to be reimplemented by hand after `tar` broke.

`compstate[insert]` accepts **a number**: "the match whose number is given will be
inserted into the command line." So compsys can do this correctly.

### Resolved: replay the declaration, don't re-run the decision **[MEASURED]**

`compstate[insert]=<n>` turned out to be unusable here: `compadd -O array`
explicitly does *not* add matches to the match set — the very property that lets
clicue harvest without disturbing the line — so there is no match list to index
into.

**Handing the line back to compsys was tried and rejected on measurement.** A
second, unshadowed completion pass at accept time does fix the `=` cases, but
placing the candidate on the line **moves the completion position**:

| buffer | delegated pass inserted | correct |
|---|---|---|
| `git commit --fi` | `--file=` ✓ | `--file=` |
| `man --enc` | `--encoding=` ✓ | `--encoding=` |
| `tar -` | `tar -Af` ✗ | `tar -A` |
| `rm -` | `rm -df` ✗ | `rm -d` |

With `-A` on the line compsys stops offering `-A` and starts offering the next
cluster letter, so it completed straight past the operator's choice. Any mechanism
that re-enters completion inherits this, which rules out the index approach too.

**What works instead:** how a match ends is per-match *data*, handed to us in the
`compadd` call at the position where the candidate is actually valid.

| declaration | meaning | measured on |
|---|---|---|
| `-S ''` | append nothing — clusters, or takes an attached value | `tar -` (all 7), `man -H` |
| `-S <str>` | append that string | value-taking long options (`=`) |
| *no* `-S` | ordinary trailing space | `rm -`, most of `man -` |

Recording that at harvest time and replaying it at insert time gets all five cases
right, and has no position-shift failure mode. `-S ''` and "no `-S`" mean opposite
things, so the empty string cannot represent both — the sentinel matters.

This is the distinction design value 5 is really about: **replaying what compsys
declared is showing; re-deriving where the word begins is deciding.** Capturing
three documented per-match flags is a different scale of coupling from modelling
the word grammar, which is what `IPREFIX` forced and what broke `tar`.

The suffix is persisted in the flag cache with a format version, because the mtime
stamp cannot notice that clicue started writing a fourth field — and a warm cache
that silently regressed what a fresh harvest gets right would only show up in the
*second* shell.

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

### POSTDISPLAY must be constant height — **SUPERSEDED** [was ASSUMED]

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

~~This is a hard constraint on any POSTDISPLAY-based renderer — **the card cannot grow
or shrink in response to state**, so every layout decision must be made against a fixed
budget rather than to fit content.~~

**Superseded, and it was never true of the shipped code. [MEASURED]** Height changes on
nearly every keystroke:

```
[g] 29   [gi] 21   [git] 17   [git ] 16   [git c] 8   [git commit] 3   [git commit ] 18
```

It does not mangle, and padding is not why. **POSTDISPLAY is emptied and rebuilt on
every redraw** — 19 of 19 renders reported `pd=0` after the clear, and the rebuilt
length always equalled the card's own, so nothing accumulates. ZLE then sees a complete
new tail and does its own erasing, which is ordinary multi-line editing behaviour it
gets right. The original defect was a POSTDISPLAY *grown without being cleared*; the
clear fixed it, and the constant-height rule was a second, unnecessary fix for a bug
already dead.

Two things this changes for anyone reading further:

- **The fixed budget stays, for a different reason.** It bounds the card so it cannot
  shove the scrollback away (see the clamp finding below) — a UX constraint, not a
  rendering one. Layout may fit content freely within it.
- **The invariant worth protecting is the clear, not the height**, and that is what the
  assertions now cover. Encoding constant height would preserve a constraint the code
  does not have.

Honest limit on this measurement: it establishes that height varies and that the clear
happens on every render. It does **not** visually confirm the absence of orphaned rows
on a large shrink — the ANSI grid interpreter used elsewhere in this project produces
the same interleaving artefacts for a known-good control, so its output is not evidence
either way there. The absence of leftover-row reports from daily use is the evidence
standing in for that, which is weaker than a measurement and is labelled as such.

### The card may be COLUMNS-1 wide, never COLUMNS **[MEASURED]**

zsh's redisplay **will not write into the last column** — it wraps there instead. A
card drawn exactly `$COLUMNS` wide therefore has the closing border of *every* row
pushed onto a line of its own, which reads as a total malfunction rather than as a
cramped card. In a real 104-column pty the 104-character top border came back as 103
characters on one row with the 104th on the next.

This is the same class as the constant-height constraint above and stacks with it: the
budget must be measured against the terminal, and the terminal always wins.

Two things kept it hidden, both worth remembering:

- **A cap accidentally supplied the missing column.** `max-width` clamps to 120, and
  the author's terminal is 121 columns — leaving exactly one column of slack. Every
  width that was *not* clamped was broken. A constant that makes one configuration
  correct by coincidence will make every other configuration wrong silently.
- **A preferred minimum was allowed to win last.** `(( width < 30 )) && width=$COLUMNS`
  was written to stop a floor exceeding the terminal, and did the opposite. A clamp
  ordering rule follows: *the terminal's limit is applied after every preference, never
  before.* The height had the identical latent defect — a fixed 14 lines in a 12-row
  window — fixed the same way.

**The assertions could not have caught this, and the method matters more than the fix.**
They measure the rendered string, which is 104 characters whether that is correct or
catastrophic; the length that mangles the display and the length that fits are the same
number. Only a *screen* distinguishes them. It was diagnosed by running zsh on a pty of
a known size and replaying the captured output through a minimal ANSI grid interpreter
— which is the same lesson recorded in the method note: rendering the card and looking
at it catches what inspecting state cannot. The regression assertions consequently test
the **budget** (`_clicue_layout_width`, `_clicue_layout_height` — extracted for exactly
this reason) rather than the output.

### A guidance surface must not destroy the context it supports **[MEASURED]**

Typing `s` offers 460-odd commands. The grid took whatever the terminal could spare
(`LINES - tier1-rows - 10`), which sounds generous and is not: it grew to 68 rows in an
88-row window, and the resulting 83-line card shoved the scrollback — *including the
output of the command the operator had just run* — off the screen. The tool that exists
to help you compose the next command had erased the evidence you were composing it
from.

The grid is now clamped to **a third of the window, floored at 10 rows**, still bounded
by what the window can spare. `Alt+M` trades it back for the whole window, because a
deliberate and reversible shove is a different thing from a surprising one.

Two structural corrections came with it:

- **`max-lines` did not do what it documented.** It defaulted to 14 and bounded only
  the explanation pane, while the card's real height was `tier1-rows + tier2-rows + 5`
  with tier2 sized to fill the window — so the "fixed total line budget" was not a
  budget, and no combination of row settings was prevented from drawing a card taller
  than the terminal. It now derives from the window and is *enforced* on the row
  totals, with the grid giving up rows before tier 1 does (the grid pages, so a row
  costs a scroll there and a ranked cue here).
- **A clamped list must stay traversable, and say where you are.** `PgUp`/`PgDn` move
  by the page the renderer is *showing* — published rather than invented by the keys,
  so a press cannot disagree with the `page 3/11` counter it sits under. `Home`/`End`
  reach the ends. All of them go through `_clicue_move`, inheriting its clamping and
  its delegate-when-not-navigating contract rather than restating either.

### Resolved: compsys decides membership, the cache decides presentation **[MEASURED]**

Design value 5 said compsys decides and clicue shows. In flag position clicue had been
deciding, and the gap was measurable:

| position | compsys offers | the cache offered |
|---|---|---|
| `rm -r -` | 14, omitting `-r` | 12, **including `-r`** |
| `man -a -` | — | 40, **including `-a`** |
| `tar -c -` | **0** — the cluster letters are exclusive and one is chosen | 7, all of them |

The cached flag set is a snapshot taken at ONE canonical position (`cmd -`) and replayed
at every other, so it is position-blind by construction. It cannot know that `-r` is
already given, and it cannot know that `tar -c` forecloses `-x`.

Resolution, and it did not require giving up the cache:

- **When compsys has answered for this buffer, its words ARE the candidate set.** The
  cache still supplies grouping and labels — what it was built for, and what compsys
  does not provide. Membership and presentation were conflated; separating them is the
  whole fix.
- **An empty answer is a decision, not a stale cache.** `tar -c -` gets no options
  because none are valid, and overriding that with the full set would be clicue deciding
  again. Distinguished from the typo case (`cat -l1`, where compsys was never asked a
  question it could answer) by whether compsys has spoken for this exact buffer.
- **Before the first Tab the cache is still the membership source** — a provisional
  answer with no fork, which is the only reason the card has content in flag position at
  all. It is superseded the moment compsys speaks. On that path only, options already on
  the line are subtracted; repeatability is precisely why that subtraction does not
  belong on the compsys path, since only the `_arguments` spec knows which flags may
  repeat.

**A prefix filter cannot tell a stale harvest from a live one.** The old guard filtered
compsys's words by the typed prefix and called that staleness protection. Every flag of
every command starts with a dash, so they all pass: probing `rm -r -` and then `tar -c -`
in one shell put `--no-preserve-root` and `--one-file-system` on tar's card. A harvest is
now reused only for a buffer the harvested one is a prefix of — `git ` still answers for
`git co`, and nothing answers for a line that no longer starts the same way.

### Delegating in flag position rewrites the line **[MEASURED]**

`cat -l1<Tab>`. No cat option starts with `-l1`, so the candidate set was empty, the
card bailed, and Tab handed the line to the operator's completer — which drew zsh's own
uncoloured listing *and changed the buffer to* `cat -A`.

Two conclusions, one of them stronger than the UI-consistency argument that has driven
this before:

- **A leading dash is never a filename, so Tab does not delegate there at all.** The
  earlier fix established clicue owns flag position; this closes the hole where an
  empty candidate set reopened it. Delegation there is not a cosmetic fallback, it is
  destructive: it silently discards what the operator typed. Design value 1 bites
  harder when the thing damaged is the line rather than the display.
- **A prefix that matches nothing is a typo, not an absence of information.** clicue
  already holds the command's whole documented option set, so it offers that — with the
  card saying `nothing matches -l1` rather than implying these are matches. The
  operator sees what they meant and arrows to it, which is the composition loop doing
  its job instead of a dead end.

### An aliased command found none of its own options **[MEASURED]**

Reported as `ls -<Tab>` failing to bring up a card at all, and guessed to be a missing
`emulates` declaration. It was not: the declaration was present and correct.

The flag map is keyed on the **alias-resolved** path — `_clicue_flag_load` and
`_clicue_fkey` both resolve before touching it, so `ls` (declared to emulate `lsd`)
stores `lsd|--long`. The candidate scan compared against the **typed** path and looked
for `ls|`, matching nothing. So every aliased command found zero options and the card
bailed with `render-failed`, while unaliased `cat -` drew a full card — which is
exactly what made it read as an alias-configuration problem rather than a key-format
one.

The general shape, worth more than the fix: **when one side of a map resolves a key and
the other side does not, the failure is silent and looks like missing data.** Both sides
now go through `_clicue_resolve_path`.

### Two legend claims that were false, one of them dangerously **[MEASURED]**

Found by reading the rendered legend against what the widgets actually test, after the
operator reported that `→ accept` was wrong inside the grid — which it was, because
`_clicue_arrow_right` tries the grid move first and never reaches the ghost.

The other two were worse, and neither had been noticed:

- **`↑↓ browse` before the card is engaged.** The arrows require `_clicue_engaged`,
  which only Tab sets. Until then they reach command history.
- **`⏎ insert` before the card is engaged.** Enter requires the same flag, so before
  Tab it **runs the line**. The legend was inviting the operator to press Enter
  expecting text to be placed on the command line, and execute the command instead.

This sharpens design value 1. An inert advertised gesture costs confidence; one that
names the *wrong outcome for a destructive key* costs more than that. The rule is
therefore not "list the keys" but **every segment is gated on the state its own widget
tests** — including `Alt+M`, which is offered only where maximising would change
something, and `PgUp/PgDn`, which is offered only when there is more than one page.

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

**Resolved, and it resolved differently at each level.** Ranking is a switchable
zstyle — `frequency`, `recency`, `frecency` — defaulting to frecency, a count
weighted by bucketed age. `clicue-rank` switches it mid-session and `clicue-rank
why <prefix>` prints the counts, ages, weights and scores behind an order, because
every improvement to this tool began as "that order feels wrong" and then cost a
measurement to explain.

#### The distortion is fatal one level down **[MEASURED]**

The paragraph above under-stated its own finding. De-duplication does not merely
deflate counts; it deflates them **in proportion to how habitual an invocation is**,
and that bites much harder for whole invocations than for commands.

A *command* still accumulates a count, because it appears across many differing
lines — different arguments, different paths, all distinct, all kept. An
*invocation* does not, because an invocation is habitual precisely to the degree
that it is retyped identically, and identical lines collapse to one.

So at invocation level a count measures **argument diversity**, not use:

| | count | why |
|---|---|---|
| a habitual destructive one | ~30 | the paths after it varied, so it spans ~30 distinct lines |
| a habitual listing | 1 | typed the same way every time, so dedup collapsed it |

The listing is the more habitual of the two and scores lowest. This makes frecency
unusable there rather than merely imprecise: frecency is `count × recency_weight`,
so when the count is 1 for every habitual entry it degenerates to the age bucket
alone, with mass ties broken alphabetically — an order that looks principled and
behaves as noise.

Argument position therefore ranks on **recency alone**, at both of its sources.
Command position keeps frecency, where the count is real. One metric was never
going to fit both, and the reason is a property of the history file rather than of
the ranking.

See `docs/design-notes/habits-in-argument-position.md`.

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

### Driving compsys for descriptions: four defects **[MEASURED]**

The adapter harvested candidates correctly from the first day and yet the cards
showed bare names. Four separate defects, found by logging every `compadd` call
rather than by reading the rendered output — a description gap is only visible at
the call site, because by render time "compsys described nothing" and "we dropped
what it described" look identical.

| # | Defect | Why it was invisible |
|---|---|---|
| 1 | `-d` arrives **clustered** as `-ld` (compdescribe emits it that way); an exact `== -d` test never matched | no error — the array simply stayed empty |
| 2 | placeholder padding built one `@@@@…` blob instead of N elements, so every group after an undescribed one was **misaligned** | wrong glosses on the right names reads as bad data, not as a bug |
| 3 | prepending `-O` **steals the caller's own array** — with two `-O`, the *first* wins | `_git` derives its description column width from exactly such an array, so this corrupted the layout of the descriptions being read |
| 4 | `list-grouped` (on by default) routes long options through a grouped path that moves the description out of `-d` **and emits every option twice** | looked like compsys just has no flag descriptions |

Defect 4 is the interesting one. The descriptions were never missing — `_arguments`
hands `_describe` an array of `--all:stage all modified and deleted paths` pairs.
With `list-grouped` on, each option becomes its own single-match group and the
description leaves the display array entirely.

| Buffer | before | after |
|---|---|---|
| `curl -` | 664 words, **0** described | 332 words, **331** described |
| `git commit -` | 118, 0 | 74, **59** |
| `git ` | 306, 0 | 153, **152** |
| `docker ` | 120, 0 | 60, **60** |
| `systemctl ` | 154, 0 | 77, **77** |

The word counts halve because the duplicate emission goes away too.

Three candidate explanations were tested and **ruled out** before this one: our own
`compstate[list]=''` (no effect at either clear point), the `verbose` /
`descriptions` styles (no effect), and `compadd -X` group explanations (never
present). Recording the disproofs because the same shape — plausible mechanism,
a fix that works, no isolation step — is what produced two wrong `[MEASURED]`
tags earlier in this project.

`list-grouped` is **borrowed, not kept**: set for the duration of one capture and
restored in an `always` block, so a completer that aborts cannot leave the
operator's normal Tab menu quietly regrouped (design value 1). It cannot be
scoped by context instead — during capture `curcontext` is `:complete:<cmd>:<tag>`
with an empty widget field, so no pattern selects clicue's call and not the
operator's. Configuring compsys by zstyle is using its own API; this is not the
kind of reaching-in that design value 0 forbids.

### A flag's meaning is constructible; its short/long pair is too **[MEASURED]**

The count of how often a flag was used answers a question the operator rarely
has. What the flag *does* is the useful thing, and compsys already carries it —
two properties make a real reference page constructible with no hand-authoring:

1. Driving `<cmd> -` yields the documented flag set with descriptions.
2. A short flag and its long spelling carry the **identical** description, so they
   can be paired by grouping on description text.

| Command | words | described | distinct descriptions | shared by 2 names |
|---|---|---|---|---|
| `rm -` | 17 | 17 | 12 | 4 |
| `ps -` | 62 | 62 | 44 | 17 |
| `ls -` | 98 | 81 | 57 | 24 |
| `curl -` | 332 | 331 | — | — |

Pairing requires **exactly two** spellings sharing a description. Three or more
means the description is generic (`display help information`) and pairing it
would be a guess.

Clustered short flags decompose only when **every** letter is documented:

```
rm -rf     -r            remove directories and their contents recursively
           -f, --force   ignore nonexistent files, never prompt
curl -fsSL -f, --fail    Fail fast with no output on HTTP errors
           -s, --silent  Silent mode
           -S, --show-error  Show error even when -s is used
           -L, --location    Follow redirects
ps -aux    REFUSED — ps documents no dashed `u`
```

`ps -aux` refusing is the guard working. It is also a famously wrong invocation
(BSD `aux` takes no dash), so inventing an explanation would have taught the
operator something false.

Harvesting forks, so it happens on the first Tab per command and is cached in
`~/.cache/clicue/flags/<cmd>.zsh` against the binary's mtime — a command cannot
document new flags without the binary changing.

### Whole-invocation statistics gate verbosity **[MEASURED]**

Per-token counts answer "which flags do I use". The whole invocation answers
"do I know this by heart", keyed on the command plus its flag tokens only — paths
and values are data, and including them would make every invocation unique.

Measured on one developer's history. Figures are given as shape rather than as a
transcript — the distribution is what the design rests on, and a verbatim table of what
somebody runs and how often is a profile of them, not evidence.

| Invocation | count | percentile | last |
|---|---|---|---|
| a habitual destructive one | ~30 | top 1% | today |
| a habitual inspection one | ~5 | top 7% | days ago |
| a download idiom | ~3 | top 12% | weeks ago |
| a listing typed once | 1 | top 58% | today |

Order ~180 distinct invocations across order ~1,700 history lines. Counts are deflated
by `HIST_IGNORE_ALL_DUPS` — the top invocation reaching ~30 *despite* dedup is the
signal, not the number. Recency is free: `EXTENDED_HISTORY` already stamps every line, so
nothing is instrumented here either.

The familiarity gate defaults to **off**. A card that quietly shows less than it
did yesterday is indistinguishable from a broken one, and the collapsed row names
the key that expands it — design value 1 applied to a feature whose whole purpose
is showing less.

**These keys now feed the card, not only the gate**, which raised the bar on what
belongs in one: a key has to be worth *proposing*, not merely worth counting. Four
things had to change, each invisible while the map only counted.

A single-dash token carrying hyphens is not a flag — one was being stored as an
invocation of `cd`, and a mangled path offered even once costs more trust than the
feature earns. Cluster spellings are canonicalised, since one habit typed two ways
was two entries of 1 and neither could ever rank; the key sorts the letters and the
*spelling last typed* is what gets shown. Leading subcommands count, for commands
whose arguments are not paths — requiring a flag had been discarding the dominant
habit of the most-used command in the corpus while keeping rarer flagged forms of
it. Order ~180 distinct invocations became order ~500.

What was **not** added is a minimum-count filter. It is the obvious way to drop the
junk, and under `HIST_IGNORE_ALL_DUPS` a count of 1 is the signature of the most
habitual invocations rather than of noise — the filter would have deleted exactly
what the feature exists to surface. Recency separates junk from habit here without
a threshold, because junk is old.

### Two zsh behaviours that fail by storing the wrong thing **[MEASURED]**

Both cost debugging passes here, and neither produces an error:

| Construct | What actually happens |
|---|---|
| `assoc[${a}|${b}]=$v` | does **not** store under `a|b`; the write lands where the read never looks, and the map stays silently empty |
| `print -r -- "x\ty"` | `-r` does not expand escapes, so this writes backslash-t; a reader splitting on a real tab merges every field |

A third of the same shape: a glob operator needing `EXTENDED_GLOB` matches
**literally** when it is off, so `-[a-zA-Z][a-zA-Z]##` silently rejected every
cluster it was written to match.

All three are now asserted across the whole file rather than at the site that
happened to be wrong, and the `\t` guard was mutation-tested — reintroducing the
broken form does fail it.

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

- order **~170** distinct commands ever used
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

### Dismissal was invisible, and read as a malfunction **[MEASURED — resolved]**

> Resolved: see design value 1. Esc now applies to the current buffer only.
> Original finding retained below because the diagnostic path is the lesson.

#### Original finding

The operator reported clicue "occasionally dropping to the original completion
engine", intermittently and then not reproducibly. A full audit of every zsh entry
point found **no residual** — no live autosuggestions reference, one `compinit`,
Tab correctly owned, and `/etc/zsh/zshrc` inert (it guards on a file its own
package never installed).

The cause is clicue's own designed fallback. `_clicue_accept` delegates to
`complete-word` whenever the card is not visible, and one reason it is not visible
is `_clicue_suppressed` — set by Esc, and cleared only when the line is emptied.

**That state has no visual indication at all.** One Esc press silently disables the
tool for the rest of the line, which is indistinguishable from a malfunction, and
it stops "happening" as soon as a fresh line is started without pressing Esc —
which is exactly the reported pattern.

The behaviour is as specified. The defect is that a mode with no indicator is
indistinguishable from a bug. Open: either surface the dismissed state, or relax
suppression to clear when the command word changes rather than when the line
empties.

Generalises: **any invisible mode in a live-feedback tool will be reported as
breakage**, because the operator has no way to attribute the change to their own
action.

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
