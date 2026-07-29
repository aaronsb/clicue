# Composition and comprehension are two jobs, not one

> Status: **proposal.** Written to harmonize several pending decisions rather than
> answer them one at a time. Nothing here is implemented except where noted.

## The value being protected

Stated by the operator, and it is the sharpest articulation of the product so far:

> start with a command with large surface area (`gh`, `ffmpeg`), and slowly accumulate
> the parameters — either by typing them in manually or using tab + arrows + select to
> build up the command. This means that any sort of copy/paste from documentation or
> examples auto-evaluates commands too, with an auto-explanation for each property and
> subcommand.

Two distinct activities are named there, and clicue currently conflates them:

| | **Composition** | **Comprehension** |
|---|---|---|
| question | what can go *here*? | what does this line *say*? |
| driven by | the cursor position | every token on the line |
| source | compsys at the cursor | the corpus + cached flag sets |
| trigger | typing, Tab, arrows | a line existing at all — including pasted |
| when the line is complete | nothing to offer | **most** to offer |

The last row is the important one. Composition and comprehension are strongest at
opposite ends of a line's life, which is precisely why one must not displace the other.

## Measured state today

- **Composition works.** `ffmpeg -i x -ab` offers 185 candidates; `gh org<Tab>` now
  descends a level; grouped spellings collapse; insertion replays compsys's own suffix.
- **Comprehension barely exists.** `gh org list --limit 10` pasted explains **nothing**:
  the explanation loop considers only tokens starting with `-`, and the flag cache is
  keyed on the head command (`gh`), so `--limit` is not found even though it is a real
  `gh org list` option.

So the half the operator values most on paste is the half that is missing.

## Proposal

### 1. Explain every token, not only flags

Drop the `-*` filter. A row per token, with its kind:

```
gh org list --limit 10
├ typed ─────────────────────────────────────────────────────┤
│ › org         Manage organizations                          │
│ › list        List organizations for the authenticated user │
│ · --limit     Maximum number of items to fetch              │
│   10          value for --limit                             │
```

The gutter already distinguishes subcommand (`›`) from flag (`·`), so the kind is
carried without a new column.

### 2. Cache flag sets per command PATH, not per command

`--limit` belongs to `gh org list`, not to `gh`. The cache key becomes the path:

```
flags/gh.zsh              subcommands of gh, and gh's own flags
flags/gh:org.zsh          subcommands and flags of `gh org`
flags/gh:org:list.zsh     flags of `gh org list`
```

Harvested the same way, by synthesizing `gh org list -` and driving compsys. Depth-N
nesting costs N harvests, once ever, cached against the binary's mtime exactly as now.

An uncached path explains what it can and marks the rest — the cold-flag affordance
already built for this ("press Tab to load"), reused rather than reinvented.

### 3. Tab has ONE rule, and the hint says what it will do

An earlier framing called Tab "four behaviours on invisible state". That was
pessimistic. There is one rule:

> **Tab advances your position in the candidate space.**

- many candidates → advance to the next one (the history-ranked ordering means this is
  usually one press, which is why the operator chose cycling)
- one candidate, already typed → there is no "next", so advance a *level*: commit it
  and descend
- flag set not loaded → loading is a precondition of having a candidate space at all,
  and it no longer consumes the press
- clicue stood down → there is no candidate space; compsys owns the position

Nothing changes behaviourally except that the **hint line names the next action** —
`Tab insert` when the press will commit, `Tab cycle` when it will move. The hint is
already segment-based and width-aware, so it can carry this. That converts an
invisible mode into a labelled one, which is what design value 1 actually asks for,
without overturning the operator's decision that Tab cycles.

**Implemented.** The legend is now derived from live state on every render rather than
built once at load. Two corrections came out of building it:

The verb is **`insert`, not `accept`** — the legend already used `accept` for `→`,
which takes the *ghost text*, and Tab's commit path calls `_clicue_insert`, the same
code Enter runs. Naming Tab's commit `accept` would have put two different actions
under one word while hiding that Tab and Enter had become the same key. `Tab insert ·
⏎ insert` reads as a duplication and is one: two keys, one action, said plainly.

The legend also had to stop advertising **inert** gestures. On a one-candidate card
there is nothing to browse and no ghost to accept, and on an explanation-only card
(`rm -rf` — a complete invocation has no candidate left to propose) every navigation
gesture is inert. Listing them is the same failure as an invisible mode, arrived at
from the other side: the operator tries the gesture, nothing happens, and they
discount the whole legend. So each segment is now gated on the thing it names being
real, and `dismiss` — the way out — is the segment that survives every width.

### 4. Comprehension needs no paste detection

A pasted line is just a line. Because the explanation pane is driven by tokens rather
than by the cursor, paste is handled by doing nothing special — which is the test that
the split is the right one. No bracketed-paste hook, no heuristic, no new mode.

## What this resolves

| Open question | Resolved how |
|---|---|
| Tab semantics (#15) | one rule, plus a hint that names the next action |
| info-mode placeholder (#12) | disappears: a line always has something to explain |
| gloss bar duplicating a row (#12) | the explanation pane subsumes it; the bar can go |
| candidate filtering coupling (#13) | unchanged — still ours, still the honest gap |

## What it costs

- N harvests for depth-N nesting, once per path per binary version. `gh` has ~70
  subcommands; caching every path eagerly would be 70+ forks, so harvesting stays
  **lazy and on demand**.
- More vertical space when both panes are full. The budget split landed already, and
  the fit is verified from 32 columns up.
- The explanation is only as good as the cache is warm. That is visible, not silent,
  which is the difference that matters.

## Open, and deliberately not decided here

- Whether a **value** token (`10`, `potato.file`) deserves a row, or only named things.
  Explaining `10` as "value for --limit" is nearly content-free.
- Whether to explain tokens **after** the cursor. A pasted line has them; a line being
  typed does not. Explaining ahead of the cursor may read as clairvoyant or as noise.
- Whether comprehension should work for a line recalled from **history** without the
  operator typing anything, which is the same case as paste and probably the answer
  is yes.
