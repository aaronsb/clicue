# Corpus — what clicue remembers, and how it stays honest

Extraction of `prototype/build-corpus.zsh` (builder) and `prototype/lib/corpus.zsh`
(access, staleness, maintenance) for the daemon's corpus module. In the rewrite the
daemon owns build, storage, staleness, and lookup as one component — ADR-100 makes
the stamp single-owner, which retires the builder/runtime duplication the 2026-08-02
review ranked as its top finding. Tags per `spec/README.md`.

## C — content: the maps and their meaning

- C1 [domain] The corpus stores, per command: a one-line gloss, an invocation
  count, and a last-seen epoch; per (command, token): a usage count; per command,
  a ranked token list capped at 40; and per whole invocation: count, last-seen
  epoch, rank percentile, and a spelling-alias map. (build-corpus.zsh:341–406)
- C2 [domain] Glosses come from whatis/mandb, user and admin command sections
  only (1, 8, 1p), and only for commands actually installed — the full index
  carries ~2× entries for absent tools and storing them is pure load tax.
  First gloss wins per name. (build-corpus.zsh:26–56)
- C3 [domain] The pathish set — commands whose arguments are paths, not
  reusable cues — is a single judgement call emitted into the corpus, never
  duplicated into the runtime: "two copies of a 56-entry judgement call will
  drift." (build-corpus.zsh:97–105, 345–351)
- C4 [domain] CLICUE_KIND is built and emitted but never read at runtime
  (review, grep-verified); the rewrite drops it. Kind is derived live from
  shell state at render time instead. (build-corpus.zsh:357–361)

## K — invocation keys: what counts as one habit

- K1 [domain] A single-dash token containing hyphens is not a flag: clusters
  are letters and digits only (length ≤ 9), long options carry the second
  dash and may carry `=value` — the value is dropped, the name kept. A
  mangled path stored as a flag once (`-home-aaron-Projects-x`) costs more
  trust than the feature earns. (build-corpus.zsh:151–201)
- K2 [domain] Cluster spellings canonicalise for the key (letters sorted) and
  the display form is whichever spelling was typed most recently; every other
  spelling is emitted as an alias pointing at the winner. Keys are emitted
  under the SPELLING, never the canonical form — keying canonically silently
  broke the invocation note and familiarity gate for exactly the clusters
  they exist to recognise. [REVIEW] (build-corpus.zsh:205–217, 255–274)
- K3 [domain] Leading word tokens join the key for non-pathish commands only,
  capped at two (`gh org list`), stopped by the first non-word token — for
  pathish commands the word after the command is a path. Dropping them
  everywhere discarded `git clone`, the dominant git habit.
  (build-corpus.zsh:229–238)
- K4 [domain] `--` ends option collection for the segment: acting on tokens
  after it would key `grep -- -x file` as `grep -x`, claiming a flag the
  operator explicitly marked as not one. [REVIEW] (build-corpus.zsh:242–246)
- K5 [domain] No minimum count filters invocations. Under
  HIST_IGNORE_ALL_DUPS a line typed identically every time appears exactly
  once, so a count of 1 is the signature of the MOST habitual invocations —
  recency separates junk from habit; frequency cannot. (build-corpus.zsh:173–176;
  docs/design-notes/habits-in-argument-position.md)
- K6 [domain] History lines split into segments on `||`, `&&`, `|`, `;`
  before any per-invocation processing — the same rule the runtime uses to
  find command position, applied once at build. (build-corpus.zsh:110–121, 221–228)
- K7 [domain] The invocation percentile is rank among DISTINCT invocations in
  descending count order, so "top 10%" reads the same whatever the history
  size. (build-corpus.zsh:289–306)

## S — staleness: detected, never trusted

- S1 [domain] The corpus carries a stamp of its inputs: format version first
  (an added field cannot be noticed by input mtimes), then history file
  mtime+size ("have I run more commands"), then the mtime of every `$path`
  directory ("has anything been installed or removed") — no walk of the
  binaries themselves. (build-corpus.zsh:309–340; corpus.zsh:113–132)
- S2 [domain] ADR-100: the daemon is the stamp's single owner. The prototype
  computes it twice with a "must match" comment, and the miss already
  happened once (commit 8be7524). One process owns each fact.
- S3 [domain] A stale corpus is still loaded and still rendered from — the
  stamp triggers a rebuild, never a feature gate. Consumers test for the data
  they need, not the stamp: gating on the stamp would have made every command
  look non-pathish for one shell after upgrading, and `rm <Tab>` would have
  proposed deleted paths. [REVIEW] (corpus.zsh:23–29, 113–119; candidates.zsh:385–397)
- S4 [domain] Rebuild runs in the background, detached, output discarded, at
  most once per shell; the writer is atomic (tmp + rename), so a reader
  mid-rebuild sees the old corpus or the new one, never a partial.
  (corpus.zsh:136–149; build-corpus.zsh:408–410)
- S5 [zsh-hazard, dies] zstat accepts one `+spec` per call — a second is
  parsed as a filename and the component vanishes silently. [MEASURED]
  (corpus.zsh:122–126; build-corpus.zsh:315–317)
- S6 [domain] Not every stamp mismatch means the same thing. zsh appends each
  command to HISTFILE as it runs — `clicue data` itself moves the history
  before it can look — so in a live shell the corpus is always at least one
  command behind, and a rebuild can never present as "current" for more than
  zero keystrokes. [MEASURED 2026-08-03] Status reporting therefore
  distinguishes *trailing history* (the working state of derived data;
  resolved at the next daemon start or an explicit `clicue data rebuild` —
  there is no background schedule, and the wording must not imply one) from
  *structural* staleness (format version or `$path` changed — glosses may be
  missing or wrong; worth a hand rebuild). A vanished histfile still reads
  as trailing: a structural verdict there would advise a rebuild that erases
  the only remaining copy of the habits. Every reporting surface routes
  through the one classifier — two surfaces disagreeing about the same
  corpus undermines the one that is right. The rebuild trigger itself stays
  exact-match: folding new history at the next build point is what it is
  for. Two guards keep the classifier honest: the stamp grammar lives in a
  single render/parse pair beside the producer (S2 — one owner per fact,
  pinned by a round-trip test), and the stamp is taken BEFORE the inputs
  are read, so a change landing mid-build (whatis takes seconds)
  reschedules instead of hiding behind a stamp newer than the data it
  describes. (corpus.rs `StampParts`/`staleness`/`build_with`; main.rs data
  status; doctor.rs corpus_state)
- S7 [domain] Every artifact the daemon derives itself from — config file,
  corpus cache, operator theme files — is watched by ONE reloader, so every
  CLI verb that rewrites an input (`config set`, `theme set`, `data
  rebuild`, `data forget`) applies live through the same engine swap, and
  none of them may tell the operator to restart. Two deliberate exclusions:
  the flag store (the daemon's own harvest ingests write it — watching it
  would make the daemon reload itself on every first-Tab), and hot-reload
  swaps never rebuild a merely-stale corpus (`CorpusPolicy::LoadOnly`).
  Only the daemon's FIRST engine rebuilds-if-stale: a live histfile moves
  with every command, so a swap that rebuilt-if-stale would run a
  whatis-sized build on every config edit and — because the build's save
  re-triggers the corpus watch — could chase a busy shell in a rebuild
  loop. (daemon.rs `WatchSet`/`reloading_render`; engine.rs `CorpusPolicy`)

## L — load and lifecycle

- L1 [domain] The corpus loads lazily: shell startup pays nothing, the first
  card pays the load once (~8 ms in the prototype). (corpus.zsh:12–13)
- L2 [zsh-hazard, dies] Every map is declared before the cache is sourced so
  an older cache degrades to empty maps instead of erroring on undefined
  subscripts. The daemon replaces this with versioned storage. (corpus.zsh:15–22)
- L3 [domain] GC drops cached flag sets for commands that no longer resolve
  to anything (command, builtin, function, or alias). (corpus.zsh:154–169)
- L4 [domain] All corpus and cache content is derived data; deleting it is
  always safe and says so. (corpus.zsh:207–210)

## P — privacy

- P1 [domain] Everything is derived from shell history; nothing is
  instrumented. Reading from history — never from the live buffer — is what
  makes HIST_IGNORE_SPACE a free per-command opt-out: a space-prefixed line
  never enters history, so clicue never learns it. Reading the buffer instead
  proposed deliberately-hidden commands back in the same session. [REVIEW]
  (build-corpus.zsh:10–12; candidates.zsh:230–244; stats.zsh:1–8)
- P2 [domain] The rewrite extends the opt-out retroactively: `clicue data
  forget <cmd|invocation>` deletes a recorded habit; `inspect` shows what is
  known before deciding. (ADR-100 tool surface)
