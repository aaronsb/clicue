# Card layout — extracted from prototype/lib/render.zsh

Scope: how a candidate list, an explanation, and live key state become lines of
text plus highlight spans. Target component: the daemon's layout engine
(ADR-100). Provenance is `render.zsh:<line>` unless stated; `test.zsh:<line>`
where the suite asserts a behaviour the comments do not. Tags per
`spec/README.md`: **[domain]** survives the rewrite, **[zsh-hazard]** is a
zsh-language defense; **[MEASURED]** marks facts the prototype verified against
a real terminal.

One global note for the rewrite: every width in the prototype is measured in
**characters** (`${#str}`), which is wrong for East Asian Wide glyphs and is
policed by hand at the theme layer. The daemon must measure **columns**
(`unicode-width`); every "width" below means columns. [zsh-hazard, dies]

## W — outer width

- W1 [domain][MEASURED] The card's outer width is at most `COLUMNS − 1`. zsh's
  redisplay wraps rather than writes in the last column; a card exactly
  `COLUMNS` wide pushes every row's closing border onto its own line. Verified
  in a 104-column pty; the bug hid because the max-width cap happened to leave
  one column of slack at the author's 121-column terminal. (render.zsh:297-310;
  property-tested across widths, test.zsh:994-1016)
- W2 [domain] Width is capped at 120 by default (a cap, not a target — long
  rows scan poorly), configurable (`max-width`). (313-315; test.zsh:1029-1040)
- W3 [domain] There is no minimum width above the terminal: a "preferred
  minimum" that exceeds the window draws off-screen, which is worse than
  cramped. The only floor is 12, the arithmetic limit below which the inner
  width goes non-positive. A 20-column terminal gets a 19-column card.
  (316-319; test.zsh:1020-1025)
- W4 [domain] Width and height are re-read from the terminal on every render;
  a resize takes effect on the next keystroke with no hook. (287-291)

## H — height budget

- H1 [domain] Total card height is a hard budget: `1 border + r1 + 1 border +
  r2 + hint + gloss + close` = `r1 + r2 + 5` lines with both boxes, `r1 + 4`
  with one. The budget is **enforced**, not assumed: whatever the row
  preferences sum to, the card fits the window. (474-480, 534-557)
- H2 [domain] Default budget is `LINES − 6` (prompt rows + the line being
  typed), floor 8; an explicit `max-lines` is honoured but still capped at
  `LINES − 6`. The window cap is applied **after** the floor — a floor allowed
  to win last is exactly how the width bug survived. Absolute floor 5 (the
  emitter's arithmetic minimum). (332-353; test.zsh:1044-1074)
- H3 [domain] When over budget, the grid gives up rows **first** (it pages, so
  a lost row costs a scroll); tier 1 shrinks only if the grid is exhausted,
  floor 1. (542-557)
- H4 [domain] Tier 1 holds a fixed cue count (`tier1-rows`, default 10). The
  tier boundary is a renderer count, not a data property — otherwise the
  primary card's size swings with how much history matches. (485-487;
  candidates.zsh:106-112)
- H5 [domain] The grid is **clamped, not filled**: `LINES / 3`, floor 10,
  bounded by `spare = LINES − tier1 − 10`. Rationale: a 460-candidate grid
  once grew to 68 rows and shoved the operator's scrollback (including the
  output they were reacting to) off the screen — a guidance surface must not
  destroy the context it supports. (488-519; test.zsh:1395)
- H6 [domain] Maximize (`Alt+M`) trades the clamp for `spare`, per line, and is
  advertised only when it would actually add rows (`canmax = spare >
  clamped`). An operator's explicit shove is different from a surprise.
  (500-518, 829-836)
- H7 [domain, open question] The constant-height rationale: ZLE paints a
  taller POSTDISPLAY over a shorter one rather than reflowing, so height
  changes mid-typing mangle the display. The gloss bar renders
  **unconditionally** for exactly this reason (679-694). But `_clicue_emit_box`
  deliberately does NOT pad to its allocation, as a live re-test of that
  never-isolated inference (102-108, 283). The spec resolution for the daemon:
  treat constant height per buffer as the invariant (it is the safe side and
  the stated design); variable height remains an experiment the differential
  harness can run deliberately.

## S — two boxes, one selection

- S1 [domain] Tier 1 (nearest the prompt) is history-ranked; tier 2 is either
  the overflow grid (command position) or the explanation of the typed line
  (argument position). One selection flows off the bottom of tier 1 into the
  grid: no mode, no second keybinding. (8-13, 182-186 in clicue.zsh)
- S2 [domain] Focus is derived, not toggled: `sel > tier1-count` means the
  grid has focus. (524-526)
- S3 [domain] The selection is clamped to `[1, total]`, then whichever window
  holds it slides to keep it visible (tier-1 window and grid window
  separately). (560-570)
- S4 [domain] In argument position both tier-2 boxes can apply, and **neither
  displaces the other**: the grid ("what else could go here") sits under
  tier 1 because the selection flows into it; the explanation ("what have I
  already said") sits below as context. They once were alternatives and the
  explanation won — hiding 175 browsable options behind a counter that
  admitted they existed. (628-640)
- S5 [domain] The explanation is bounded and small, so it is budgeted first
  (`ecap = maxlines − t1n − 5`, floor 1, computed against the rows tier 1
  will actually draw, not its allocation); the grid takes the remainder minus
  one for the explanation's border. (641-654)
- S6 [domain] An explanation alone justifies the card: a complete invocation
  (`ls -lat`) matches no candidate and is exactly the case worth explaining.
  (364-370, 470-471)

## G — grid geometry

- G1 [domain] Column-major, like zsh's own listing. Cell width = longest
  visible candidate, capped 28, + 2 padding. (193-203)
- G2 [domain] A 3-column gutter aligns the grid's first column with tier 1's
  names. (204-207)
- G3 [domain] Layout rows derive from content (`ceil(n / ncols)`, capped at
  the allocation, floor 1) so few items spread across columns; the *page* is
  `rows × ncols`. (210-217)
- G4 [domain] The grid window (`gridtop`) advances in whole pages until the
  selection is on the visible page. (220-225)
- G5 [domain] The renderer **publishes** page size and bounds; the paging keys
  move by exactly the visible page, and the `page k/n` counter derives from
  the same number, so keys and counter cannot disagree. A PageDown that moves
  by its own number loses the operator's place. (226-243; keys.zsh:110-137)
- G6 [domain] The grid label states what the box holds: command position
  `all N on system`, argument position `N more`, while browsing
  `browsing i/N`, with `· page k/n` only when pages exceed one. (245-250)
- G7 [domain] Only the selected **cell** gets the selection highlight —
  colouring the row would imply the row is the unit. (269-276)

## C — column arithmetic

- C1 [domain] The name column is sized over the **display labels** of both
  visible windows plus the explain labels — sizing on raw tokens truncated
  `-f, --force` to its short form's width; sizing without explain labels
  clipped every explanation on candidate-less cards. (573-588)
- C2 [domain] Name width: cap 28, and capped against what is actually left
  (`inner − 7 − 10`, floor 6); floor 10 only when the remainder allows.
  Names truncate rather than overflow: a clipped name is legible, a wrapped
  card is not. (589-597)
- C3 [domain] Row overhead, written out because an off-by-one pushed the right
  border a column past the top one: `border(1) + marker(2) + space + gutter(1)
  + space + name(namew) + 2 spaces` = `namew + 8`, closing border one more;
  gloss width = `inner − namew − 7`, floor 10. (598-605)
- C4 [domain] Gloss text longer than its column ellipsises (`…` replaces the
  last kept character); names truncate hard. (87-89, 172-176, 688-692)
- C5 [domain] Box labels that outgrow the box are silently truncated to
  `inner − 1` (a clipped label reads; a wrapped card does not). All three
  emitters route labels through this fit. (42-58; test.zsh:1459-1476)

## E — the explain box

- E1 [domain] Rows are `label ⇥ description`, one per property already typed;
  **not selectable** — the box explains the line, the selection stays where it
  composes. (111-124)
- E2 [domain] Its top border joins the box above (`├ ┤`) when one exists,
  opens the card (`╭ ╮`) when the card is pure explanation. (143-148)
- E3 [domain] Familiarity collapse: an invocation in the operator's top
  percentile collapses to the evidence line plus the *named* expand key — a
  reduced view, never a silently different one; a collapsed box must not be
  mistakable for a broken one. Off unless `familiar-percentile` is set.
  (130-160; stats.zsh:44-54)
- E4 [domain] The left column matches tier 1's name width so the boxes align;
  description width `inner − lw − 5`, floor 10. (165-176)
- E5 [domain] An optional footer (the invocation note: `run N× · top P% ·
  age`) right-pads into the box. (179-184; stats.zsh:18-40)

## L — legend (hint line)

- L1 [domain] The legend is **derived from live state on every render** and
  advertises only gestures that will do something right now. An inert gesture
  costs trust; naming the wrong outcome for a destructive key costs more.
  (610-615, 797-811)
- L2 [domain] Key names come from the actual bindings (zstyle), not
  constants; the labels are built once from what was bound. (769-795)
- L3 [domain] Informational cards and pure-explanation cards offer only
  `Esc dismiss` — nothing answers to an arrow there. (817-822)
- L4 [domain] Grid focus swaps to the grid legend: `←→↑↓ navigate`,
  `PgUp/PgDn page` only when more than one page exists, `Home/End ends`,
  maximize only when it would change anything (H6), `⏎ insert`, dismiss.
  (824-845)
- L5 [domain] `↑↓ browse` and `⏎ insert` appear only once the card is
  **engaged** (Tab pressed): before that, arrows reach history and Enter runs
  the line — advertising `⏎ insert` on an unengaged card invites executing a
  command while expecting composition. (847-871; test.zsh:1535-1547)
- L6 [domain] The insert-vs-cycle wording (`Tab insert` when the sole cue is
  already what is typed) reads the **same predicate the key dispatch reads**
  (`_clicue_tab_inserts`); two copies of the condition would let the legend
  lie. (853-865; keys.zsh:180-193; test.zsh:1523-1533)
- L7 [domain] `→ accept` appears only when a ghost stem exists — same
  single-definition rule. (870, 917-921)
- L8 [domain] When the width cannot hold every segment, segments drop from the
  **middle**: the first (primary gesture) and last (`dismiss`, the escape
  hatch) survive any width; at absurd widths the last segment is truncated
  rather than the line overflowing. (946-972; test.zsh:1645-1671)
- L9 [zsh-hazard, dies] The segment-join fallback exists because
  `${(j:·:)a[1,n] b}` is a bad substitution reported at render time.
  (958-963)

## GH — ghost text

- GH1 [domain] Precedence: (1) the cue being actively navigated (engaged —
  nothing may override a choice in progress), (2) the most recent matching
  history line (muscle memory beats one token: `gi` proposes `t status`),
  (3) the top-ranked cue. One definition, two consumers — the drawer and the
  legend. (917-942)
- GH2 [domain] The cue stem is the highlighted candidate minus the typed
  prefix; empty prefix proposes the whole cue; informational cards propose
  nothing. (876-891)
- GH3 [domain][known-defect] The history stem must read from the **bounded
  recent-history window**, newest-first, first match wins. The prototype reads
  the full `$history` here — the one caller that missed the window
  optimisation (candidates.zsh:184-204 measured the cost this incurs per
  keystroke). The daemon owns history and does this uniformly. (894-915)
- GH4 [zsh-hazard, shim] The ghost precedes the card in POSTDISPLAY; clearing
  the card must leave the ghost so the co-tenant's accept gesture consumes the
  stem, and clearing for re-render must strip both so stems do not accumulate.
  (746-765)

## K — kind gutter

- K1 [domain] One glyph names a cue's origin, and only **reliably known**
  kinds get one — a wrong source marker is a confident lie the operator
  cannot check. Command position: alias/function/builtin/system, else blank.
  Argument position: flag vs subcommand by leading dash. (19-40)

## SP — spans

- SP1 [domain] The card is one text block (leading `\n`, lines joined); spans
  are `(start, end, style)` offsets **relative to the card text**, shipped
  beside it. The shim adds the base offset (buffer + existing POSTDISPLAY +
  ghost) and tags every entry `memo=clicue`. (395-410 in clicue.zsh, 696-742)
- SP2 [domain] Border rows are styled whole; list rows style border columns,
  the dimmed kind gutter, the name column, the gloss column; the typed prefix
  within a matching **displayed** name is emphasised (`matchlen` per row,
  recorded only when the display label starts with the prefix — a grouped
  label reached via its long spelling must not bold the wrong characters).
  (93-99, 723-736)
- SP3 [domain] The selected tier-1 row is highlighted whole; the selected grid
  cell alone is highlighted (G7). (720-722, 737-738)
- SP4 [zsh-hazard, dies] The prototype's span pass re-identifies row types by
  matching rendered glyphs — self-described as fragile and the reason theme
  glyphs are validated at load. The daemon knows each line's type at emission
  and must carry it structurally, not re-derive it from text. (705-711)
- SP5 [zsh-hazard, dies] `matchlen` is an association, not an array, because a
  sparse zsh array reports `${+arr[n]}` true for every gap. (clicue.zsh:191-195)

## Test-suite behaviours the comments understate

- T1 The width property (W1) is asserted for **every** width 12..200, not
  spot-checked. (test.zsh:1005-1016)
- T2 The render body must **ask** for the layout budget
  (`_clicue_layout_width/height`) rather than recompute it inline — the
  budget rules are single-owner. (test.zsh:1094-1103)
- T3 All three box emitters must route their labels through the single fit
  function (C5). (test.zsh:1469-1476)
