# sources.md — candidate resolution and ranking

Extracted from `prototype/lib/candidates.zsh`, `prototype/lib/stats.zsh`,
`docs/design-notes/habits-in-argument-position.md`, and the candidate/ranking
sections of `prototype/test.zsh` (≈1143–2060). Target: the daemon's `sources`
and `rank` modules (ADR-100).

Line references are to the prototype at the freeze (main @ PR #1 merge).
Tags: **[domain]** survives the rewrite; **[zsh-hazard]** is a defense against
zsh-the-language — recorded where the *reason* still constrains the design, and
dropped where Rust makes the hazard unrepresentable. `[MEASURED]` provenance is
kept: those are facts about real shells and real histories, not opinions.

Scope note: the daemon receives corpus maps (built by its own corpus module),
the compsys harvest for the current buffer (relayed by the shim), and the
request context (buffer, words, prefix, mode). It returns an ordered candidate
list plus per-candidate display labels. Membership in argument position is
compsys's decision when compsys has spoken; ordering and presentation are
always clicue's (SPEC design value 5).

## A. Command position

- **A1 [domain]** Candidate sources and precedence: aliases, then functions,
  then builtins + reserved words, then commands on PATH; the first source to
  claim a name keeps it (alias > function > builtin > system).
  (candidates.zsh:76–88)
- **A2 [domain]** Function names beginning `_` or `.` are excluded.
  (candidates.zsh:80)
- **A3 [domain]** Each candidate carries its kind (alias/function/builtin/
  system); the renderer's gutter glyph and gloss fallback depend on it.
  (candidates.zsh:74, corpus.zsh:89–94)
- **A4 [domain]** Ranking is a partition, not a full sort: candidates with a
  nonzero score sort by score descending, all others alphabetically after
  them. Rationale: frequency data covers only commands actually used (~173 on
  the reference machine), so scoring the whole match set is wasted work.
  (candidates.zsh:7–10, 92–112)
- **A5 [domain]** The tier-1/tier-2 boundary is a fixed row count applied by
  the renderer, never a property of the data — otherwise the primary card's
  height would swing with how much history matches, which the display cannot
  tolerate. (candidates.zsh:108–111)
- **A6 [zsh-hazard]** The prototype sorts descending via a zero-padded string
  complement; the field must be 10 digits because frecency multiplies a count
  by up to 16 and an 8-digit field overflowed, wrapping the most-used command
  to the bottom of the card. [MEASURED] In Rust: sort by integer key; the
  invariant that survives is only "the score domain exceeds 8 digits".
  (candidates.zsh:99–101, test.zsh:1204–1211)

## B. Ranking modes

- **B1 [domain]** Three modes: `frequency` (count alone), `recency` (last-seen
  alone, day granularity), `frecency` (count × recency weight, the default).
  An unrecognised configured value falls back to `frecency` — never silently
  to some other metric. (candidates.zsh:29–36, test.zsh:1193–1199)
- **B2 [domain]** Frecency recency weights are bucketed multipliers on the
  count, Mozilla-shaped: ≤0 days → ×16, ≤7 → ×8, ≤30 → ×4, ≤180 → ×2,
  else ×1. Integer arithmetic on the keystroke path by design.
  (candidates.zsh:24–28, 38–51)
- **B3 [domain]** `recency` mode scores `last_seen / 86400`; a command with no
  recorded timestamp scores 0 and falls to the alphabetical tier, which is
  where it belongs. (candidates.zsh:60–62)
- **B4 [domain]** A command with no timestamp gets weight ×1 in frecency
  (degrades to plain frequency for that entry). When no clock is available at
  all, frecency behaves as frequency and the status surface says so rather
  than hiding it. (candidates.zsh:41–42, 658–659)
- **B5 [domain]** The ranking must be interrogable: a `why <prefix>` operation
  shows NAME / COUNT / AGE / WEIGHT / SCORE for the current mode's ordering.
  Every ranking improvement in the prototype started as "that order feels
  off" plus a measurement; the instrument is part of the contract, not a
  debug leftover. (candidates.zsh:637–694, test.zsh:1213–1219)
- **B6 [domain]** Mode is switchable at runtime and both silent degradations
  (no recency data in corpus; no clock) are reported on the status surface —
  design value 1: no invisible fallback. (candidates.zsh:646–660)

## C. The effective command (wrapper walk)

- **C1 [domain]** Pathish/source decisions are made on what the line actually
  runs: `sudo rm`, `env FOO=1 rm`, `command rm` all run `rm`. Wrapper set:
  sudo doas env command builtin exec nohup nice ionice setsid stdbuf time.
  (candidates.zsh:121–132)
- **C2 [domain]** Leading `NAME=value` assignment tokens belong to the wrapper
  and are skipped. (candidates.zsh:140–144)
- **C3 [domain]** A wrapper option (any `-` token) aborts resolution: whether
  the next token is the option's value or the command is per-wrapper
  knowledge this deliberately does not have — `sudo -u root rm` once resolved
  to `root`, `nice -n 10 rm` to `10`, both then replayed remembered paths.
  Unknown fails safe. [MEASURED] (candidates.zsh:145–150,
  test.zsh: "a wrapper option-argument does not become the command")
- **C4 [domain]** Walking off the end (`sudo <Tab>` alone) is failure, not
  "the wrapper is the command": what it will run is genuinely unknown, and
  the caller applies the same fail-safe as an absent pathish map. Without
  this, `sudo ` proposed a remembered `sudo rm -rf <path>` in full.
  (candidates.zsh:151–159)
- **C5 [domain]** Anything unrecognised stops the walk and is the answer; an
  unknown wrapper degrades to treating the wrapper itself as the command
  rather than guessing past it. (candidates.zsh:127–129)

## D. The bounded history window

The daemon owns history, so the zsh-side costs below do not transfer — but
they document *why the window exists* and what any replacement must preserve.

- **D1 [domain]** Whole-line lookups run against a bounded window of the
  newest N history lines (default 2000, configurable), not the full history.
  Recency is the ranking anyway, so a line old enough to fall outside the
  window could not have ranked. (candidates.zsh:183–204)
- **D2 [zsh-hazard]** The prototype's cost ladder, kept as provenance:
  subscript scan of full `$history` is 0.16 ms at 2k / 3.49 ms at 50k;
  newest-first indexed walk is quadratic (1525 ms at 50k); windowed lookup is
  0.047 ms flat. Seeding via `${(v)history}[1,win]` costs 0.5 ms at 2k /
  7.1 ms at 50k; `tail -n` is flat but forks and mis-handles multi-line
  entries; `fc -ln` is worst. Revisit trigger recorded: ~20k entries.
  [MEASURED] (candidates.zsh:184–204, design note "the window's seed still
  scales")
- **D3 [domain]** The window stays current within a session and is bounded as
  it grows — a long-lived shell must not grow back the cost the window
  removed. (candidates.zsh:245–265)
- **D4 [domain — privacy constraint]** Session top-up reads accepted lines
  from `$history` and NEVER from the edit buffer. The project promises no
  instrumentation; `HIST_IGNORE_SPACE` must work as a per-command opt-out,
  and a space-prefixed line never enters `$history`. Reading the buffer
  instead once proposed the operator's deliberately-hidden commands back to
  them in the same session. This constrains the rewrite's protocol: whatever
  feeds the daemon new lines must be derived from `$history` (or HISTFILE),
  never from keystrokes or accepted buffers. (candidates.zsh:230–244, design
  note "the opt-out is a constraint on this feature")
- **D5 [ambiguity — for protocol.md]** The daemon cannot read `$history`
  in-process the way the prototype does, and HISTFILE only sees new lines per
  the operator's append options. The shim relaying *from `$history`* honours
  D4; relaying from anywhere else does not. Decision deferred to the protocol
  spec.

## E. Whole-line history cues (non-pathish commands)

- **E1 [domain]** For commands whose arguments are values worth replaying
  (`ssh <user>@<host>`), tier 1 is whole prefix-matching history lines,
  values intact, ranked by recency — newest first. (candidates.zsh:161–182,
  design note Decision table)
- **E2 [domain]** Counting is structurally broken for invocations under
  deduplicated history (`HIST_IGNORE_ALL_DUPS` et al.): every unique line
  appears exactly once, so a count measures argument diversity, not habit —
  a habitual `rm -rf` reaches ~30 only because its paths varied; a listing
  typed identically every time sits at 1. Recency is the undistorted signal:
  dedup keeps the newest occurrence. Frecency at invocation level degenerates
  to the recency buckets with alphabetical tie-breaks — it would look
  principled and behave as noise. [MEASURED] (design note "counting is
  structurally broken", candidates.zsh:173–178)
- **E3 [domain]** A candidate is the matched line minus everything left of
  the word under the cursor, so it still begins with the typed prefix — this
  is what lets a multi-token cue reuse the single-token stem/insert
  arithmetic unchanged. (candidates.zsh:179–182, 275–281,
  test.zsh: "a multi-token candidate still begins at the cursor's own word")
- **E4 [domain]** A remembered line may continue past a separator into a
  different command; the candidate is one segment, truncated at the first
  unquoted separator token (`|`, `||`, `;`, `&&`, `&`, `|&`, `(`, `{`) —
  truncated, not rejected, because the part before the separator is a genuine
  cue. Tokenisation decides, so a quoted separator inside an argument is left
  alone. Measured incident: `git status && rm -rf node_modules` put the
  `rm -rf` on git's card. [MEASURED] (candidates.zsh:301–320)
- **E5 [domain]** Candidates equal to the typed prefix are dropped; distinct
  lines that share a suffix after head-stripping deduplicate; results cap at
  40 by default. (candidates.zsh:321–332)
- **E6 [domain]** A glob character anywhere in the buffer must not turn the
  lookup into a pattern match, in either direction: the buffer is matched
  literally against history, and the typed word is removed from matches by
  length, never by pattern-strip. [MEASURED both ways: an unquoted lookup
  matched every line; `:#` with quoting matched nothing]
  (candidates.zsh:280–299, design note "The rule"; test.zsh: "a glob in the
  buffer is matched literally", "splices by length, not by pattern")
- **E7 [zsh-hazard]** The underlying rule, recorded because the shim keeps
  some of this code: `[(r)]`/`[(R)]` subscripts re-scan an expansion as a
  pattern (so `(b)` quoting is required there); `%`, `#`, `:#`, `[[ == ]]`
  compare expanded values literally unless GLOB_SUBST is on (so `(b)` quoting
  is fatal there). Opposite of ksh/bash. Length-splice is correct under both
  regimes, but an index removes N characters unconditionally, so it must be
  guarded by a literal suffix check — `%` fails safe, arithmetic does not.
  (design note "The rule"/"The overreach", candidates.zsh:275–299)

## F. Invocation cues (pathish commands)

- **F1 [domain]** For pathish commands, tier 1 is flag-only invocation keys
  from the corpus (`rm` → `-rf`), never whole history lines — a whole line
  would offer a path deleted months ago, and a stale destructive path
  inverts the tool's purpose. (candidates.zsh:336–347, design note Rejected)
- **F2 [domain]** Ordering is last-seen descending (recency-dominant), for
  the E2 reason applied at invocation level. Prefix filter applies when the
  operator has typed one; results dedup and cap at 40.
  (candidates.zsh:348–377, test.zsh: "invocation cues rank by last-seen")
- **F3 [domain]** Invocation keys are stored under the spelling the operator
  typed; the canonical (letter-sorted cluster) form exists only inside the
  corpus builder to merge `-lat`/`-alt` into one habit. Proposals therefore
  need no un-canonicalisation. An alias map routes every non-winning
  spelling to the stored key, and *consumers* (invocation note, familiarity
  gate) must resolve through it or they go blank for exactly the clusters
  they exist to recognise. (candidates.zsh:360–363, stats.zsh:20–24, 50–51,
  build-corpus.zsh:255–274, test.zsh: "a habit is proposed in the spelling
  last typed", "the invocation note survives a non-winning spelling")
- **F4 [domain]** Filtering happens in the lookup, not by scanning every key:
  the invocation map holds every habit the operator has, of which one
  command's slice is small, and this runs per keystroke. [MEASURED]
  (candidates.zsh:355–358) — in Rust this is an index/prefix structure, not
  a linear scan.

## G. Source selection in argument position

- **G1 [domain]** The tier-1 source splits on pathish, tested on the
  *effective* command (section C): non-pathish → whole history lines (E);
  pathish → invocation cues (F). Tier 2 in both cases is the complete
  documented parameter set. (candidates.zsh:384–401, design note Decision)
- **G2 [domain]** The pathish set is data emitted by the corpus builder
  (`CLICUE_PATHISH`), one copy — it decides both what the builder collects
  and what the card proposes, and two copies of a 56-entry judgement call
  will drift. (build-corpus.zsh:345–351, design note)
- **G3 [domain]** Absent pathish data means UNKNOWN, and unknown fails safe
  to flags-only — withholding a whole line costs a cue; proposing a path that
  could not be ruled out costs more. Same fail-safe for an unresolvable
  wrapper (C3/C4). The gate tests the *data*, never the corpus format stamp:
  a stale cache is still sourced, and gating on the stamp would have made
  every command look non-pathish for one shell after upgrading.
  (candidates.zsh:386–401, test.zsh: "an absent pathish map fails safe")
- **G4 [domain]** When neither history source answers, the per-token argument
  map (`CLICUE_ARGS`) still does — a command whose arguments were never a
  whole line worth keeping, but whose subcommands were seen.
  (candidates.zsh:404–413)
- **G5 [domain]** Candidate list order is `hist` (tier-1 habits, already
  ranked) followed by the documented/compsys set sorted alphabetically; the
  seam between them is invisible to the renderer (A5 applies).
  (candidates.zsh:461–464, 617, 632)

## H. The flag set

- **H1 [domain]** The flag path engages when the prefix is empty, starts with
  `-`, or the line already carries an option token. Empty prefix loads the
  whole documented set so tier 2 is browsable the moment the cursor reaches
  argument position ("the parameter set is there to arrow into, not only to
  filter"); a non-empty non-dash prefix (`git sta`) is a subcommand being
  named and must NOT be answered with the flag set. (candidates.zsh:431–445,
  design note measured table: `git sta` → `status` alone)
- **H2 [domain]** Flag lookups key on the alias-resolved command path
  (`gh org list`, head resolved through aliases/`emulates`); the scan
  prefix must be the resolved path too — comparing the typed spelling made
  an aliased `ls` find zero options while `cat` worked. [MEASURED]
  (candidates.zsh:446–456)
- **H3 [domain]** Ordering hazard, on the common path: the grouped flag set
  resolves BEFORE raw compsys words, or identical input yields two different
  cards depending on cache warmth — `man -` showed 74 ungrouped rows on
  first Tab and 39 grouped rows in every later shell. [MEASURED]
  (candidates.zsh:418–424, 440–444)
- **H4 [domain]** One row per flag, not per spelling: spellings sharing a
  description collapse to one row; the inserted candidate is the canonical
  (shortest, cluster-composable) spelling, the label names all spellings
  short-forms-first. When the operator's typed prefix matches only the long
  form, the long form is inserted — typing `--rec` must not silently insert
  `-r`. (candidates.zsh:547–594, compsys.zsh:476–511)
- **H5 [domain]** Grouping results are memoised per (path, flag) and
  invalidated when the flag map grows — uncached it cost ~2.8 ms per render
  at ~80 options, the dominant cost of the card. [MEASURED]
  (candidates.zsh:560–581)
- **H6 [domain]** Membership is compsys's; presentation is clicue's. When
  compsys has answered for THIS buffer, its words are the candidate set —
  it knows repeatability and exclusivity the cache cannot (`rm -r -` omits
  `-r`; `tar -c -` offers nothing because cluster letters are exclusive).
  The cache still decides grouping and labels, and remains the membership
  source before the first Tab (provisional, fork-free). [MEASURED]
  (candidates.zsh:475–530)
- **H7 [domain]** On the cache path only, options already on the line are
  subtracted (all words except the command and the word under the cursor —
  `rm -r` must still offer `-r` while it is being typed). Known limit,
  accepted: a cluster subtracts as one token (`-rf` ≠ `-r` + `-f`); compsys
  supersedes with the right answer on first Tab. (candidates.zsh:511–529)
- **H8 [domain]** Two-pass prefix relaxation: if a dash-prefix matches no
  documented flag, the whole option set is offered instead, flagged so the
  card can say "nothing matches ⟨prefix⟩" — an unmatched option prefix is a
  typo, not a reason to delegate; delegation here let zsh's completion
  REWRITE `cat -l1` to `cat -A`, and losing what you typed is the worst
  outcome the project has. Pass 2 is skipped when compsys has spoken for
  this buffer — its empty answer is a decision, not a stale cache.
  [MEASURED] (candidates.zsh:466–474, 534–545)
- **H9 [domain]** Filter then sort: the flag map subscript filters before the
  ~80 survivors are sorted — 0.119 ms vs 2.70 ms against a 1,490-entry map,
  and this is on every argument-position card now. [MEASURED]
  (candidates.zsh:505–510)
- **H10 [zsh-hazard]** Composite keys `cmd|flag` are built in a variable
  because an unescaped `|` in an inline zsh subscript stores under the wrong
  key silently. Rust map keys make this unrepresentable; recorded only
  because the shim-side harvest relay must preserve the same key identity.
  (compsys.zsh:233–238)

## I. Compsys harvest merge and staleness

- **I1 [domain]** A harvest is usable only if the buffer it was taken for is
  a prefix of the current one — `git ` still answers for `git co`; nothing
  answers for a line that no longer starts the same way. A prefix filter on
  candidates alone cannot detect a harvest from a *different command* whose
  flags all pass the dash filter — probing `rm -r -` then `tar -c -` put
  rm's long options on tar's card. [MEASURED] (candidates.zsh:599–616)
- **I2 [domain]** Harvested words are filtered against the prefix compsys was
  matching (minus what compsys consumed into IPREFIX), then normalised to
  the full spelling, then deduped against everything already listed.
  (candidates.zsh:621–631)
- **I3 [domain]** In command position any previous harvest is cleared — a
  different command means the harvest no longer applies. (clicue.zsh:365)

## J. Stats: the invocation note and the familiarity gate

- **J1 [domain]** The invocation note reports the operator's own relationship
  to the exact line typed: run count, percentile ("top N% of your
  invocations"), and age (today / yesterday / Nd ago). Lookup resolves
  through the spelling-alias map (F3). It must not fork.
  (stats.zsh:14–40)
- **J2 [domain]** Percentile is rank among distinct invocations by count, so
  "top 10%" reads the same whatever the history size.
  (build-corpus.zsh:286–306)
- **J3 [domain]** The familiarity gate (collapse the explanation for
  invocations the operator demonstrably knows) is OFF by default
  (threshold 0): an unrequested verbosity change is design value 1's
  invisible behaviour shift. When enabled, familiar = percentile ≤
  threshold, resolved through the alias map. (stats.zsh:42–54)
- **J4 [domain]** Everything in this section derives from history at corpus
  build time — never instrumented — so `HIST_IGNORE_SPACE` remains a free
  per-command opt-out. (stats.zsh:1–8)

## Ambiguities and contradictions found

1. **D5** — how the daemon's history window stays session-fresh without
   violating D4 is undecided; belongs to protocol.md.
2. **`_clicue_history_stem` vs `_clicue_history_lines`** (render.zsh:908 vs
   candidates.zsh:267): same lookup, but the ghost-stem copy bypasses the
   bounded window and pays the full-history scan per keystroke, and does NOT
   truncate at separators (E4) while the cue path does — so the ghost can
   propose a continuation the card would refuse. In the daemon these must be
   one function; the separator rule wins. (Already logged as review finding
   #3.)
3. **Open questions carried from the design note, deliberately undecided:**
   merged dual-source tier 1 for commands like `git` (`git clo` now offers 27
   distinct clone URLs), operator-amendable pathish set, `clicue-rank why`
   for argument position, and staleness marking for dead hosts/repos. The
   Rust `sources` module should not foreclose these.
4. **Minor contradiction:** candidates.zsh:359 comment says keys are stored
   under the typed spelling "so this is already what gets proposed", but
   build-corpus emits *zero-count alias entries* under non-winning spellings
   (`CLICUE_INVOKE` count 0) — `_clicue_invocation_cues` iterates all keys
   with the command prefix and relies on `rest` dedup plus recency 0 to bury
   them, rather than filtering alias entries explicitly. Works, but by
   accident of ranking; the rewrite should filter alias entries from
   proposals explicitly.
