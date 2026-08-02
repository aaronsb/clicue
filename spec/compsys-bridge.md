# Compsys bridge — the harvest that stays in the shell

Extraction of `prototype/lib/compsys.zsh`. This component STAYS zsh (ADR-100):
the compadd shadow only exists inside a live zsh process, so its
[zsh-hazard] items are carried into the generated shim, not dropped. The
harvest's OUTPUT crosses the protocol as the `pending` payload
(spec/protocol.md §4); grouping, labels, and storage move to the daemon.

## B — the shadow's contract

- B1 [domain] Drive compsys only through documented interfaces: a
  `list-choices` completion widget, `compstate[insert]=''` and
  `compstate[list]=''` to keep the line and screen untouched, `compadd -O`
  to receive matches, `-D` to prune the display array in lockstep. Never
  round-trip compadd's body as text — zsh-autocomplete did, it failed to
  re-parse on `#` comments, and every completion broke. (compsys.zsh:1–17;
  clicue.zsh:114–130)
- B2 [domain] The shadow APPENDS `-O`/`-D` and hands everything else to the
  builtin. A call that already carries `-O`/`-A` is the completer probing
  ITSELF ("does anything match, how wide is the longest") — pass it through
  untouched: two `-O` arrays do not both fill, the FIRST wins, and stealing
  it corrupts the layout `_git` computes from exactly such an array.
  [MEASURED] (compsys.zsh:65–70, 103–107)
- B3 [zsh-hazard, stays] Option scanning stops at a bare `-` or `--`
  separator (words follow; a candidate may merely look like an option), and
  must handle clustered spellings: compdescribe emits `-ld`, so an exact
  `== -d` test silently never matches. `-d`'s argument resolves by parameter
  name or literal `(a b c)` form. [MEASURED] (compsys.zsh:43–64)
- B4 [domain] How a match ends is per-match DATA, not a decision: no `-S`
  means trailing space, `-S ''` means append nothing (clustering or attached
  value), `-S str` means append str. Three states; the empty-value case is
  recorded distinctly (the prototype uses `\0` in memory, `-`/`_`/literal on
  disk) because "no -S" and "-S with empty value" mean OPPOSITE things at
  insertion. (compsys.zsh:20–23, 73–76, 121–128, 341–345, 366–376;
  clicue.zsh:140–158)
- B5 [zsh-hazard, stays] Record IPREFIX with every harvest. `_tar` consumes
  the leading dash into IPREFIX and completes bare letters; `_man` leaves it
  in PREFIX and completes whole tokens. Without normalising both
  representations, tar's 14 candidates were all discarded for not starting
  with a dash. Store seen/suffix under the normalised spelling too — that is
  what the card offers. [MEASURED] (compsys.zsh:85–93, 121–128)
- B6 [zsh-hazard, stays] When descriptions and words come back misaligned,
  pad with one placeholder PER WORD, split on the empty separator — padding
  to width N yields a single N-char string, and splitting on spaces
  misaligned every group after an undescribed one. [MEASURED]
  (compsys.zsh:130–139)
- B7 [domain] Borrow `:completion:* list-grouped false` for the duration of
  one capture, restored in an always block, so an erroring completer cannot
  leave the operator's real Tab menu regrouped. With grouping on, `curl -`
  yields 664 words and ZERO descriptions; off, 332/331. It cannot be scoped
  by context: during capture the curcontext widget field is empty, so no
  pattern selects our call and not the operator's. [MEASURED]
  (compsys.zsh:141–173)
- B8 [domain] compdescribe packs display strings as
  `<word><padding>-- <description>`; unpack honouring the list-separator
  zstyle, and unpack against the ORIGINAL word, not the normalised one — the
  packing wrapped `A`, not `-A`. (compsys.zsh:178–215, 426–430)

## H — harvesting

- H1 [domain] Harvest TWO synthesised positions per path: `cmd ` yields
  subcommands, `cmd -` yields flags, and a comprehension pane that can
  explain `--limit` but not `list` is half a feature. The operator's buffer
  is swapped out and restored with no redraw between, so the substitution is
  never visible. (compsys.zsh:378–412)
- H2 [domain] Harvest every ANCESTOR path, not just the deepest: `gh org
  list --limit 10` explains `org` from `gh`'s set, one level up. One fork
  per level, once per path per binary version, cached. (keys.zsh:255–271)
- H3 [domain] One harvest attempt per command per shell — mark attempted
  BEFORE harvesting, so a failing completer cannot retry per keystroke.
  "Fetched and empty" is recorded distinctly from "not fetched yet"; the
  two must not render the same. (compsys.zsh:385–387, 459–467; corpus.zsh:43–56)
- H4 [domain] The flag cache is stamped with the command's own mtime plus a
  format version — a rebuilt binary may document new flags, an unchanged one
  cannot; a layout change invalidates what an mtime cannot see. Non-file
  commands stamp as `builtin`. (compsys.zsh:302–315; clicue.zsh:174–179)

## A — alias resolution

- A1 [domain] A declared mapping (`zstyle ':clicue:emulates' ls lsd`) wins
  over inference: an alias is a deliberate act, and it is the only thing
  that works when the alias lands on a shell function, whose options are not
  discoverable without guessing. (compsys.zsh:264–285)
- A2 [domain] Otherwise walk `$aliases` at most 5 hops with a seen-set,
  stopping at self-reference (`alias ls='ls --color'`), taking the FIRST
  WORD of each expansion only. Resolution applies to the HEAD of a command
  path; subcommands are never aliases. (compsys.zsh:239–247, 287–300)
- A3 [zsh-hazard, stays] First-word extraction must split into a real array
  first: `${${(z)x}[1]}` indexes the first CHARACTER of the joined string —
  it yielded `l` from `lsd`. (compsys.zsh:281–284)

## G — grouping and decomposition (daemon-side in the rewrite)

- G1 [domain] Spellings sharing an identical description are one option —
  but only groups of 2 or 3. Four or more sharing one sentence is a generic
  description (`display help information`), and grouping those would be a
  guess. (compsys.zsh:441–454) [MEASURED: rm 17/17 words described, 4 shared;
  ls 98 words, 24 shared]
- G2 [domain] The label lists short spellings first, then long, comma-joined
  — the manual-page convention. The INSERTED spelling is the shortest short
  form, because that is what composes into a cluster; a typed long prefix is
  honoured over the canonical short (`--rec` must not insert `-r`).
  (compsys.zsh:476–511; candidates.zsh:585–594)
- G3 [domain] Decompose a cluster token (`-lat`) only when EVERY letter is a
  documented flag of the command; a partial match means the token is
  something else — a value, a negative number — and inventing properties is
  ruled out. (compsys.zsh:518–536)
- G4 [zsh-hazard, stays] The cluster shape test uses a plain glob
  deliberately: `##` needs EXTENDED_GLOB, and an unsupported operator
  matches literally rather than failing — the shape test then silently
  rejects every cluster. (compsys.zsh:522–526)

## Z — shell-side hazards the shim keeps

- Z1 [zsh-hazard, stays] Composite keys are built in a variable, never
  written inline as `assoc[${a}|${b}]` — an unescaped `|` in a subscript
  stores under a different key, silently, and the map simply stays empty.
  (compsys.zsh:233–238)
- Z2 [zsh-hazard, stays] Registration lives beside definition: `zle -C`
  accepts a name whose function does not exist and fails silently at load,
  surfacing only as "no such shell function" on a keypress. (compsys.zsh:538–543)
- Z3 [domain] On-disk flag-cache authority moves to the daemon in the
  rewrite; the shim ships raw harvest output (words, descriptions, IPREFIX,
  suffixes) across the protocol and keeps no store of its own. Real tabs in
  any interim serialization — `print -r` does not expand `\t`, and a cache
  that reloads as garbage puts wrong descriptions on right flags.
  (compsys.zsh:351–376)
