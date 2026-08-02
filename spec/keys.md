# Keys — what clicue may take, and when it must give back

Extraction of `prototype/lib/keys.zsh`. In the rewrite the shim owns the
bindings and the capture/delegate mechanics; the daemon owns every decision
(the reply's `action`: consume | delegate | insert | yield —
spec/protocol.md §6). Each invariant below states WHICH side enforces it.

## R — refusals (shim, absolute)

- R1 [domain] Unmodified Up/Down are never bound. They walk command history;
  that muscle memory predates this tool. Enforced at bind time with a
  refusal on stderr, not merely intended — a stray config line is all it
  would take to break it silently. (keys.zsh:70–78)
- R2 [domain] No bare printable character is ever bound: binding `q` as an
  alternate dismiss would break every command containing a q. Typing IS how
  the operator narrows a card. (keys.zsh:79–85)
- R3 [domain] ^A is deliberately not taken even though Home is: a key that
  load-bearing in every shell is not worth a second binding for the same
  action. ^C cannot be dismiss — the tty raises SIGINT before ZLE sees the
  character. (keys.zsh:167–169, 469–473)

## D — defaults and the legend (single source)

- D1 [domain] Every binding is configuration; multiple sequences per action
  are legal because terminals disagree. Defaults: accept Tab, dismiss Esc,
  expand Alt+E, maximize Alt+M, scroll Shift+↑↓ with Alt+↑↓ beside it
  (konsole eats Shift+arrows at the terminal level — a doctor finding, see
  spec/doctor.md). (keys.zsh:41–90, 543–551)
- D2 [domain] The key defaults exist in ONE place serving both the binder
  and the legend. The prototype wrote them twice (keys.zsh:56–68;
  render.zsh:778–785) — change one and the legend advertises an unbound
  key, the exact failure its legend doctrine forbids. (2026-08-02 review #2)

## C — capture and delegation (shim)

- C1 [domain] Borrow, never own: before binding any key, capture what owned
  it; every widget delegates to that original whenever the card is not being
  navigated. Nothing is swallowed. (keys.zsh:92–104, 441–493)
- C2 [domain] Teardown RESTORES the captured originals. The prototype's
  clicue-off got this wrong in both directions — one binding loop never
  recorded its keys (arrows, Enter, End stayed clicue's), and the removal
  used `bindkey -r`, deleting the operator's PgUp/PgDn/Home instead of
  restoring them. `clicue uninstall` replays originals. (2026-08-02 review
  #6; clicue.zsh:420–427; keys.zsh:441–493)
- C3 [domain] POSTDISPLAY has no multi-tenancy protocol, so widgets known to
  consume it (forward-char, end-of-line, the vi/emacs word family) are
  wrapped: strip OUR card first, leave other tenants' content, then
  delegate. Right-arrow once shovelled the entire card into the command
  buffer. (clicue.zsh:449–464; keys.zsh:495–510)

## E — engagement (daemon decides, shim reports events)

- E1 [domain] Arrows and Enter act on the card only once it is ENGAGED, and
  only Tab engages. Before that, ↑↓ reach history and Enter runs the line —
  both correct, and the legend must say so (a legend advertising `⏎ insert`
  on an unengaged card invites executing the command). (keys.zsh:96–104;
  render.zsh:847–862)
- E2 [domain] Enter, while navigating, means "put this on the line" — never
  "run it". Composition, not execution. Untouched, Enter delegates and
  behaves as it always did. (keys.zsh:342–374)
- E3 [domain] Dismissal (Esc) hides the card for the CURRENT buffer only;
  typing brings it back. Persisting longer is indistinguishable from a
  malfunction and was reported as one. (keys.zsh:169–177; clicue.zsh:229–245)

## T — the Tab machine (daemon state, in prototype order)

- T1 [domain] Stood down → delegate IMMEDIATELY, before any harvest. The
  harvest branch ran first once, so `cd pro<Tab>` forked compsys for data
  nothing would display, consumed the press, and the completion the
  operator asked for arrived on the second Tab. (keys.zsh:210–219)
- T2 [domain] A card may be shown and still not own Tab (`cd `, `pushd `,
  `popd `, `source ` — path-centric, no documented options): the card stays
  up naming the command, the keystroke yields to compsys on the FIRST
  press. (keys.zsh:221–235; clicue.zsh:336–357)
- T3 [domain] The first Tab in argument position harvests compsys for this
  buffer, cached per buffer, and DOES NOT consume the press: it falls
  through to land on the first cue. Harvest resets any prior selection, and
  a harvest that found words converts an informational card into a real one
  — leaving it informational fell through to native completion, the raw
  listing this replaces. (keys.zsh:237–290)
- T4 [domain] When the sole candidate is exactly what is typed, Tab inserts
  it with its declared suffix and descends a level — cycling a one-item
  list does nothing visible and `gh org<Tab>` had no way forward. The same
  named predicate drives the key and the legend; written twice they would
  drift. (keys.zsh:186–193, 296–307)
- T5 [domain] Otherwise Tab cycles the PRIMARY card (tier 1 limit, wrapping
  to 1), engaging the card. (keys.zsh:309–317)
- T6 [domain] Flag position is never delegated, even with nothing to
  advance: `cat -l1<Tab>` had zsh's completion REWRITE the line to
  `cat -A`. Losing what the operator typed is the worst outcome; doing
  nothing agrees with the card that says there are no options. [MEASURED]
  (keys.zsh:320–331)
- T7 [domain] Anything else delegates to the original Tab owner, with the
  deciding condition logged — the conditions are invisible state, and
  "clicue is broken" is indistinguishable from correct delegation without
  them. (keys.zsh:333–339)

## I — insertion (daemon computes, shim applies)

- I1 [domain] Replace the typed word by LENGTH with a guard that the prefix
  is actually a suffix of the buffer; the trailing text is the candidate's
  declared suffix (empty for the recorded `-S ''` case, space otherwise).
  (keys.zsh:346–374) [zsh-hazard, stays: `${LBUFFER%$pfx}` becomes a pattern
  strip under GLOB_SUBST; length arithmetic is correct under both]
- I2 [domain] Ghost acceptance (→ or End) applies only with the cursor at
  the end of the buffer, and clears the selection. (keys.zsh:408–427)

## G — the grid mode

- G1 [domain] The grid is a deliberate mode in the menuselect sense, entered
  by scrolling past tier 1 — focus follows the selection, nothing is
  toggled. That is why it may take all four arrows without violating R1;
  outside it, every arrow delegates untouched. (keys.zsh:376–401;
  render.zsh:524–526)
- G2 [domain] Right tries, in order: grid column move → ghost accept at end
  of line → delegate. End means end-of-LIST only while engaged. (keys.zsh:424–439)
- G3 [domain] Paging keys move by exactly the page the renderer published —
  a PageDown that invents its own number disagrees with the visible page
  and the `page 2/5` counter, and the operator loses their place. Home/End
  are one enormous clamped move, not separate arithmetic that could
  disagree with the clamp. (keys.zsh:110–146)

## W — wiring hazards the shim keeps

- W1 [zsh-hazard, stays] Widget registration lives beside widget definition:
  `zle -N` accepts a missing function and fails only on the keypress. That
  regression happened twice. (keys.zsh:512–534)
- W2 [zsh-hazard, stays] Capture the prior Tab owner at source time, and
  never capture yourself (a re-source must not make clicue its own
  delegate). (keys.zsh:536–538)
- W3 [domain] Wrap order matters: the shim must wrap POSTDISPLAY consumers
  AFTER zsh-autosuggestions has done its own deferred rebinding, i.e.
  register its first-precmd after theirs, or autosuggestions reads
  POSTDISPLAY before the card is stripped. (clicue.zsh:494–505)
