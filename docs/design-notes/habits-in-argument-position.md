# Habits belong in argument position, and recency is what ranks them

> Status: **implemented.** The measurements are real and the decision below is in the
> code. What remains open is listed at the end, and is open on purpose.
> Sibling to [composition-and-comprehension.md](composition-and-comprehension.md),
> which split the card into two jobs. This one decides what fills the composition
> half when the cursor is past the command.

## The value being protected

Stated by the operator, across three examples that look unrelated and are not:

> often I just use `ls` but sometimes I use `ls -lat` and it would be nice to tab once
> into `ls -lat` … presenting the most commonly used parameters at the top is still a
> time saver

> once in parameters on a chosen command, providing the list of full previous
> invocations with parameters and cycling through with tab, and then arrow into *all*
> the parameters in the secondary cue card

> invocations like `ssh <user>@<host>` — it would be great to be able to tab through
> matching full invocations

(Hosts and usernames are generalised throughout this note. The repo's published docs
give usage as shape rather than as a transcript, which is a profile of somebody rather
than evidence.)

The third example is the one that breaks the obvious implementation, which is why it
is load-bearing rather than a nice-to-have.

## The shape, which the card already has one level up

| | Tier 1 — primary, Tab cycles | Tier 2 — grid, arrows browse |
|---|---|---|
| **Command position** (today) | ranked commands you actually run | every matching command, alphabetical |
| **Argument position** (this note) | ranked invocations you actually run | every documented parameter |

The same contract at both levels: **your habits first, the complete reference behind
them.** Two properties follow, and both are why this is cheap:

- The selection already flows continuously from tier 1 into the grid (`render.zsh`,
  focus follows the selection — scroll past the end of tier 1 and you are in the grid).
  "Arrow into all the parameters" needs no mode and no new gesture.
- A multi-token row needs no new insertion contract. `_clicue_cue_stem` is pure string
  arithmetic — cue minus prefix — so a cue `ls -lat` at prefix `ls` yields the stem
  ` -lat` unchanged, and `_clicue_insert` replays it the same way it replays one word.
  Multi-token rows stay confined to tier 1; tier 2 remains one flag per row. Two kinds
  of thing, two boxes, which is what the split was for.

## What the measurement changed

### Counting is structurally broken on this history **[MEASURED]**

`SPEC.md` already recorded the mechanism under *"history frequency ≠ usage frequency"*.
Verified live: `HIST_IGNORE_ALL_DUPS`, `HIST_IGNORE_DUPS` and `HIST_SAVE_NO_DUPS` are
all set, across a 1,770-line history. Every unique command line appears **exactly
once**, however often it was run.

So a count does not measure usage. It measures **how many distinct lines a token
appeared in** — which is argument *diversity*:

| Invocation | count | why |
|---|---|---|
| a habitual destructive one | ~30 | the paths after it varied, so it spans ~30 distinct lines |
| a habitual listing | 1 | typed identically every time, so dedup collapsed it to one |

The listing is the more habitual of the two and scores lowest. SPEC's phrasing was
*"the distortion is real and in the worst possible direction,"* and this note extends
that finding one level down, where it gets worse:

> At **command** level the count survives, because a command accumulates occurrences
> across many differing lines. At **invocation** level it does not, because an
> invocation is habitual precisely to the degree that it is retyped *identically*.

That is fatal to the obvious implementation. `frecency` is `count × recency_weight`;
when the count is 1 for every habitual entry, frecency degenerates to the five-bucket
recency weight alone, with mass ties broken alphabetically. It would have looked
principled and behaved as noise.

**Recency is the undistorted signal**, as SPEC predicted: de-duplication keeps the
*newest* occurrence, so history order survives intact where counts do not. The
operator's own instinct — *"the last -property I used is proposed"* — was a recency
rule all along.

### Two corpus maps, and neither covers the `ssh` case **[MEASURED]**

| | `CLICUE_ARGS` (per token) | `CLICUE_INVOKE` (per invocation) |
|---|---|---|
| holds | single tokens, incl. subcommands | command + its flag tokens |
| drops | anything path-like, and all 56 `pathish` commands | **all values**, and all flagless invocations |

Probed against the live corpus:

- `ls` has **no** token-level argument data at all — it is on the `pathish` list, whose
  members are excluded because their positional arguments are paths and compsys does
  paths better. Correct at the token level; it just means no amount of ranking tuning
  reaches `ls`, because the data was never collected.
- The pathish class contains the single highest-count invocation in the corpus. `rm`
  proposes nothing from history today.
- `git clone` is the dominant `git` habit by a wide margin and is **absent** from
  `CLICUE_INVOKE`, because the builder discards invocations carrying no flag.
- `ssh <user>@<host>` is absent from **both**: the host is a value, and values are
  stripped at build time on purpose — including them would make every invocation unique
  and the count meaningless. What the map does hold for `ssh` is three flags and one
  truncated token fragment.

The stripping is right for what the map was built for. It is wrong as the only source
for a card that must propose `ssh <user>@<host>`.

## Decision

**Tier 1 in argument position is sourced by splitting on `pathish`.**

| | source | ranked by | serves |
|---|---|---|---|
| **non-pathish** (`ssh`, `git`, `ffmpeg`, …) | whole prefix-matching history lines, values intact | recency | a partial host → the full one |
| **pathish** (`rm`, `ls`, `cat`, `tar`, `cp`, …) | flag-only invocation keys | recency-dominant | `ls` → `-lat`, `rm` → `-rf` |

Tier 2, in both cases, is the complete documented parameter set.

The `pathish` list is reused rather than reinvented. It already encodes exactly the
distinction that matters here — *this command's arguments are filesystem data, not
reusable cues* — and that is the same reason a path must never be re-proposed as a
habit. It existed only as a build-time local and had to reach the runtime; emitting it
into the corpus keeps one copy, and two copies would drift.

**Implemented.** The corpus format moved to v4, carrying `CLICUE_PATHISH` and
`CLICUE_INVOKE_ALIAS`, and the invocation builder was repaired. Measured against a real
history, the four defects and what fixing them changed:

| Defect | Before | After |
|---|---|---|
| single-dash token with hyphens keyed as a flag | a mangled path stored as an invocation of `cd` | rejected; clusters are letters and digits only |
| cluster spellings fragment | `-lat` and `-alt`, 1 each, neither can rank | one key at 3, displayed as the spelling last typed |
| flagless invocations discarded | `git clone` absent, `git --tags` present | `git clone` present, and the dominant `git` entry |
| — | 181 distinct invocations | 519 |

Two things were **not** done, both deliberately. Single-occurrence invocations are not
filtered: under `HIST_IGNORE_ALL_DUPS` a count of 1 is the signature of the most
habitual entries, so that filter would have deleted the motivating example. And the
truncated fragments left in history are not scrubbed — they are what the operator
actually typed, they carry old timestamps, and recency buries them without a rule.

The non-pathish source is not new machinery. `_clicue_history_stem` already finds the
most recent prefix-matching line and proposes its remainder as ghost text; this
generalises it from one match to N, cycled with Tab.

**Implemented**, along with the tier-1 split and the tier-2 ungating. Measured against
a real history and corpus:

| buffer | tier 1 | tier 2 |
|---|---|---|
| `ls ` | `-lat`, `--color`, `--help`, … | 59 candidates total |
| `rm ` | `-rf`, `-rt`, `-f` — no path | 14 total |
| `cat ` | `-pp`, `--help`, `-p` | — |
| `ssh <partial>` | the newest matching host, then the rest | — |
| `git sta` | `status` alone | correctly **not** flooded with git's flag set |

Building it surfaced one real bug and, in diagnosing it, an incorrect generalisation
that is worth recording because getting it wrong cost time in both directions.

**The rule.** `[(r)]` and `[(R)]` subscripts re-scan an expansion as a pattern.
`%`, `#`, `:#` and `[[ == ]]` do **not** — a value that arrives by expansion is compared
literally unless `GLOB_SUBST` is set, which is off by default and rarely on. This is the
opposite of ksh and bash, and it is exactly why `(b)` quoting is *required* in the
subscript form and *fatal* in the `:#` form.

**The bug**, which follows from that rule: `${(M)history:#${(b)buf}*}` compares the
quoted result as literal text, backslashes included, so a buffer carrying a glob matched
nothing at all. The `(R)` subscript does re-scan, and is what `_clicue_history_stem`
already used one letter away — `(r)` for the first match, `(R)` for all of them.

**The overreach.** This was first diagnosed as three bugs of one kind, on the assumption
that `%`, `#` and `!=` pattern-matched too. Measured: `${buf%$pfx}` with `pfx` of `?`
returns the string unchanged, and `[[ $c != $pfx ]]` with `pfx` of `*` is true. Neither
was broken. The splices were changed to length arithmetic anyway and that change stands
— it is correct under `GLOB_SUBST` as well, which the pattern forms are not — but it is
hardening, not a fix, and the record should not claim otherwise.

One consequence of the change is real and was not obvious: `%` fails *safe* when the
prefix is not actually a suffix, returning the string untouched, while length arithmetic
removes N characters regardless. A guard costs nothing and is now in place.

### Rejected

**History lines for everything.** Simplest to build, and it makes `rm <Tab>` offer
`rm -rf /tmp/build-1234` and other dead paths. A guidance surface that proposes a
stale destructive path has inverted its own purpose, and the same objection applies in
weaker form across the whole pathish class.

**Invocation keys for everything.** Never proposes a stale path, and never proposes
`ssh <user>@<host>` either — one of the three motivating examples simply unserved,
because the host was discarded before the map was written.

## What it costs

- A corpus format bump. The runtime needs `pathish`, so the stamp moves and existing
  caches invalidate rather than being read without it.
- The invocation builder needs repair before it can feed a card. Probing the live
  corpus surfaced a path fragment keyed as a flag, a mis-parsed cluster, a truncated
  token, and the flagless-invocation exclusion. At 1× each these rank last and stay
  invisible — but proposing a mangled path even once costs more trust than the feature
  earns.
- Ungating tier 2 at empty prefix puts the flag-set path on **every** argument-position
  card rather than only on dash-typing. That path has a recorded ordering hazard: the
  grouped set must resolve before the raw compsys words, or identical input yields two
  different cards depending on cache warmth. It has to hold under more traffic.
- The grid is clamped rather than filled, for a measured reason — an unclamped grid
  once grew to 68 rows in an 88-row window and shoved away the output of the command
  just run. Full option sets at empty prefix push more candidates through that clamp.

### The opt-out is a constraint on this feature, not a footnote

The search window must be read from `$history` and never from `$BUFFER`. README, SPEC,
`stats.zsh` and the corpus builder all state that nothing here is instrumented, and that
`HIST_IGNORE_SPACE` therefore works as a per-command opt-out. A space-prefixed line
never enters `$history`, so a window built from it honours that for free.

The first cut of the session top-up took the accepted line straight off the buffer. That
is instrumentation, and it proposed the operator's deliberately-hidden commands back to
them in the same session — a promise the project makes about secrets, broken by a
convenience. Anything that keeps this window current has to go through `$history`.

**Not yet verified.** Everything above was measured through the candidate functions
directly. The suite is in-process by design — a pty harness was tried for this project
and abandoned as unreliable — so the parts that only exist on a real terminal have not
been exercised: that card height stays constant while typing, that the ghost and the
legend agree with the new tier 1, and that a 32-column terminal still fits now that
tier 2 fills at empty prefix. Those need a human at a prompt.

## Open, and deliberately not decided here

- Whether a command that is neither cleanly pathish nor cleanly value-reusable should
  draw tier 1 from **both** sources, merged. `git` is the awkward case and it is no
  longer hypothetical: `git clo` now offers 27 candidates, every one of them a
  `clone` of a different repository URL. The subcommand is a habit; the URL after it
  is not, and the split has no way to say so because the split is per-command.
- Whether `pathish` should become a zstyle the operator can amend. It is currently a
  fixed list of 56, chosen by one developer's judgement about what holds paths — and
  it now decides card *content*, not just what the builder collects, which is more
  weight than the list was chosen to carry.
- Whether an argument-position order should be interrogable the way command position
  is. `clicue-rank why` explains a command ordering; there is no equivalent for a
  tier-1 argument ordering, and the reason this feature is right at all came out of
  exactly that kind of measurement.
- What a *stale* remembered line should do. History proposes hosts that may no longer
  resolve and repositories that may no longer exist; recency makes them rank low
  eventually, but nothing marks them.
