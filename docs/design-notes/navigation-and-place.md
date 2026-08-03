# Navigation is about place, and place is relayed, never recorded

> Status: **proposal, implementation starting.** Sibling to
> [composition-and-comprehension.md](composition-and-comprehension.md) (which split
> the card into two jobs) and
> [habits-in-argument-position.md](habits-in-argument-position.md) (which decided
> what fills the composition half). This note decides what the card does when the
> command *is a movement* — `cd`, `pushd`, `popd`, `dirs` — and why the first slice
> of it needs no history at all.

## The value being protected

Stated by the operator, across three remarks that pull in different directions and
must all survive:

> thinking about when a cd */to/* a directory vs */from/* a directory, and its
> commonality. for example `cd ~` I often invoke anywhere as a 'return to home base'

> maybe they're just used to 30 years of using `cd` everywhere, maybe someone else
> uses pushd and popd all the time — we don't really know

> we don't want to force a design decision

The first names the real structure of navigation habits: some destinations are
**source-independent** (home base, reachable from anywhere) and some are
**source-conditional** (from this project root, you usually go one place). The second
forbids the tool from having an opinion about which navigation dialect an operator
speaks. The third, said about theming, generalises: where this note can define a
semantic contract instead of a concrete rendering, it must.

A fourth value arrived with a deadline attached: the tool will be put in front of
operators with **empty histories** — people who have only ever opened a terminal
with a stock zsh, learning why `git clone` from a directory of their choosing is
something to understand rather than delegate. What serves them is decided below, and
it turns out to be exactly the part that needs no data.

## Measured: history cannot fund a ranked-destination card **[MEASURED]**

Probed against a real 1,792-line history, 340 of them cd-family:

| shape | count | usable as a ranked destination? |
|---|---|---|
| relative (`cd <name>`) | 311 (91%) | no — meaning depends on the cwd at the time, which history never recorded |
| absolute / `~/`-anchored | 17 | yes, but thin |
| `cd ~` exactly | 1 | see below |
| bare `cd`, `cd -` | 1 each | same |

Two findings, both extensions of the habits note:

1. **The motivating example is invisible in the data.** The operator describes
   `cd ~` as their most habitual invocation, and `HIST_IGNORE_ALL_DUPS` collapses it
   to exactly one line — the same count as a typo. This is "counting is structurally
   broken" at its limit: the invocation that is habitual *precisely because it is
   retyped identically from anywhere* is the one a deduplicated history cannot
   distinguish from noise. Recency does not rescue it either: `cd ~` is refreshed
   often, but so is every recent one-off.
2. **91% of the data is unanchorable.** History records the *text* of navigation,
   not the *place*. `cd <name>` 28 times almost certainly means one directory — but
   that is an inference about the operator, not evidence. This gap is exactly what
   zoxide fills by instrumenting `chpwd`, and exactly what this project's promises
   prevent it from filling the same way (next section).

Consequence: **ranked destination proposals are deferred**, not designed here. The
slice below is everything that needs no ranking — and the empty-history audience
makes the same cut from the other side: they have no habits to rank, and need all of
what remains.

## Relay, never record

The pane below needs the shell's place: `$PWD`, `$OLDPWD`, the dirstack. These are
**relayed** with the request — read at request time, used for that render, never
persisted. The distinction is the same one the protocol already draws for the
compsys harvest, and it is a hard line, not a preference:

- The project promises `HIST_IGNORE_SPACE` works as a per-command opt-out. A
  space-prefixed ` cd <secret>` never enters history — but a `chpwd`-based recorder
  would capture the transition anyway. Recording place does not merely bend the
  no-instrumentation promise; it **defeats an existing opt-out**.
- Consuming zoxide's database, when the operator has installed zoxide, stays on the
  right side of the line: they opted into that recorder themselves, and it carries
  its own opt-out (`_ZO_EXCLUDE_DIRS`). That is the compsys pattern — consume the
  engine, add ranking and presentation — and it is the *deferred* path to ranked
  destinations, not part of this slice.

Spec consequence (protocol.md): nav context is an optional request field; the daemon
must never write it to disk. Sibling constraint to sources.md D4.

## The navigational class

`cd`, `pushd`, `popd` sit in `pathish`, so tier 1 is flag-only invocation keys —
which for `cd` means the card is empty by design. The pathish rationale (F1: a
remembered path may be stale, and a stale *destructive* path inverts the tool's
purpose) fails twice for navigation:

1. Navigation is non-destructive. The worst stale proposal costs an error message.
2. Unlike an `rm` argument, a navigation target's staleness is **verifiable before
   render** — stat it and drop it.

`pathish` was built for commands whose path arguments are *data*; for the cd family
the path is the *entire habit*. So: a **navigational** class — `cd`, `chdir`,
`pushd`, `popd`, `dirs` — resolved through the same effective-command walk and alias
map as pathish. It begins as a runtime constant; when the corpus builder starts
emitting destination data it moves into the corpus for the G2 reason (one copy of a
judgement call, or two copies drift). Membership stays a judgement call exactly as
pathish's is.

Dialect neutrality falls out of the class being about *shape*, not verbs: every
member gets the same pane, destination data (when it exists) pools across verbs — a
place you go often is a habit regardless of which verb takes you there — and the
verb typed decides only what the explanation pane explains. Nobody is asked whether
they are a pushd person. One honest edge: an operator with `AUTO_PUSHD` has a
dirstack whether they know it or not; showing it is disclosure of state that exists,
not a recommendation. Discovery by seeing is the only teaching this product does.

## Decision — the zero-data slice

Five pieces, each usable with an empty history:

### 1. Nav context in the protocol

`pwd`, `oldpwd`, `dirstack` as an optional request field, following the
`pending`/`env` pattern. Relay-only per above.

### 2. The fisheye "you are here" pane

For a navigational command in argument position, the comprehension box becomes a
degree-of-interest view of place. Detail falls off with distance, and the falloff
**is** the cost model:

| ring | source | cost [MEASURED, warm] |
|---|---|---|
| ancestors (breadcrumb) | string-split of relayed pwd | zero I/O |
| siblings + children | one `read_dir` each | ~0.01 ms |
| grandchild counts | one `read_dir` per child, early-stop at 100 | 0.1–0.3 ms even for `/usr` and a build dir |

Uncapped, counting `/usr/bin`'s ~5k entries cost 3.0 ms; the display cap ("99+")
bounds the scan too. Below the count ring: nothing — "how many levels down" is an
unbounded walk and is not promised. Above: the breadcrumb answers it for free.

```
├ you are here ─────────────────────────────────────────┤
│  ~ › Projects › app › clicue                           │
│  ▾ crates/ 1    docs/ 4       spec/ 9     tests/ 3     │
│    dist/ 2      packaging/ 3  prototype/ 6   +3 more   │
│  ⌂ beside you: patchbay · yay-friend · +6 more         │
```

Mechanics: cache per `(dir, mtime)`, revalidated by one stat per render; the daemon
outlives shells, so the cache is shared. Dotdirs fold into a `+n hidden` cell.
Symlinks are not followed. A total scan deadline (~5 ms) covers cold network
filesystems: on overrun, render breadcrumb and names with reserved `…` cells where
counts go, and fill them on a later render — **cells, not rows**, so card height
never changes for a given buffer (layout H7). Scanning is event-driven only; a
non-interactive shell has no ZLE, never loads the shim, and can never reach this
path, so scripts are structurally unaffected.

For `pushd`/`popd`/`cd -N`, the dirstack is rendered with indexes and full paths —
this is not a special presentation; the dirstack *is* the complete candidate space
for those commands, so showing it is the tier-2 contract taken literally. The
landing entry is marked.

### 3. Resolution and existence

Every navigation target the operator has typed resolves against relayed place and
says where it lands: `-` → old pwd, `..` → parent, `+2` → dirstack entry, a
relative name → its absolute resolution, each with an existence mark. The habits
note found 91% of cd lines are relative and therefore useless as *proposals*; as
*comprehension* they are fully resolvable, and the card catches a doomed `cd` before
Enter instead of after. This is also where the empty-history audience lives: the
lesson "commands act where you are" is not told, it is made ambient.

### 4. Failure-only recommendation

> **Recommend only at the moment the typed line is about to fail. Otherwise,
> explain.**

"Did you mean" fires only when (the target does not resolve from here) AND (a
unique suffix/component match exists among known directories — dirstack, ancestors,
scanned children/siblings in this slice; the ranked pool later). It is a candidate
row, Tab-reachable, never a buffer rewrite (H8: losing what you typed is the worst
outcome). Ambiguity degrades to silence — guessing wrong three ways is worse than
the honest resolution-failure row alone. The rule's payoff is structural: the
recommendation surface cannot accumulate, and an operator who never mistypes never
sees one. Recommending at success-point ("you could have used `z`") is nagging at a
30-year habit and is rejected below.

### 5. `nav.view` — two views later, one now, and off means off

```toml
[nav]
view = "fisheye"   # fisheye | columns | off
```

Default `fisheye` (survives every width; the pane it replaces was near-empty for
nav commands, so default-on displaces nothing in use). `off` disables the scanner
entirely — no hidden I/O behind a hidden pane. `columns` (Miller columns: parent |
here | attended child, headers carrying orientation, familiar from Finder and
ranger) is designed but **deferred**; until it renders, the parser rejects the
value rather than accepting a spelling that lies — accepting-and-substituting is
design value 1's invisible fallback. When it lands it needs a width floor with a
*visible* fallback (config provenance names it), and both views are projections of
the same ring data: one scanner, two renderers.

### Falloff is semantic; themes own its look

The renderer emits three distance classes — `falloff-0/1/2` (focus, adjacent,
distant) — and the theme binds each to a palette entry and a glyph-set entry. Aura
can bind brightness interpolation; mono binds weight and dimming (its whole
vocabulary); a theme author can bind a braille density ramp; plain binds nothing and
**structural falloff** — names → counts → `+n more` → nothing — carries the meaning
alone, which is why it is the information design and not themable. The renderer says
how far; the theme says what far looks like. Nothing is hardcoded, per the operator's
stated constraint.

One hazard recorded now because it is this project's kind of bug: the CP437 shades
`░ ▒ ▓` (U+2591–2593) are East-Asian-**ambiguous** width — `unicode-width` says one
column, CJK-configured terminals may render two, the T6 failure arriving through a
side door. Theme validation warns on ambiguous-width bindings (the T7 posture: the
author who knows their terminal opts in; the default never gambles), and shades are
used only in fill positions, where a disagreement truncates a fill instead of
misaligning content. In this slice the pane emits distance via existing theme
styles; the `falloff-*` vocabulary lands with the theming work, spec first.

## Rejected

**A chpwd recorder of our own.** Defeats `HIST_IGNORE_SPACE`, per above. This is
the one rejection that is a promise, not a trade-off.

**Whole history lines for cd** (the F1 debate rerun for navigation). Not for
staleness this time — 91% of the lines are relative and unanchorable. The data is
simply not there.

**Success-point recommendations.** A card that interrupts a working `cd` to promote
a different verb demands complexity from the operator to *stop* being helped. The
familiarity gate ships off for the same reason (J3).

**Subsequence-fuzzy matching** for partial destinations. Component-anchored prefix
matching at most; H8's incident (completion rewriting `cat -l1` to `cat -A`) stands
as the boundary — clever matching that loses what you typed costs more than it
saves.

## What it costs

- A protocol field and its spec constraint; a version-compatibility check for the
  additive case.
- A scanner module with a cache, a cap, and a deadline — three knobs that must each
  be tested, including permission-denied and symlink-loop fixtures.
- The layout engine learns a second pane shape inside the existing height budget;
  the reserved-cell fill must be exercised for height constancy.
- A second judgement-call list (navigational), with the G2 drift obligation when it
  reaches the corpus.
- An e2e scenario (`tests/scenarios/`) for the pane: the zpty harness can now
  exercise a real shell, so breadcrumb rendering, count-fill without height jump,
  and a live `nav.view` flip are provable there; what still needs a human at a
  prompt is the subjective part — whether the pane reads as orientation or noise.

## Open, and deliberately not decided here

- **Ranked destinations** — the pooled cross-verb destination map, zoxide as an
  opted-in source, existence-checked history fallback, and whether tier 1 should mix
  contextual candidates (high-ranked subdirectories of here) above global ones. The
  from/to question in its sharpest form; wants a week of real navigation against
  both orderings, not an argument.
- **Miller columns** — column headers' exact grammar, the width floor number, and
  whether the attended-child column scans on highlight (cost proportional to
  attention) or renders from the count ring.
- **Insert form** — display the absolute truth, insert the shortest spelling that
  resolves (H4's shape). Unimplemented until destinations are proposable at all.
- **Whether the pane participates in grid selection** (S1) in this slice or is
  display-only at first. The seam is recorded either way.
- **`git clone` and friends** — commands that *create* directories could state
  where the result will land, which is the offsite lesson in one row. A different
  class (creational?) and a different note.
