# 03 — multi-column corner ramps and patterned rules

Evidence for relaxing T6 so corners (`tl`/`tr`/`bl`/`br`, and the
junctions `jl`/`jr`) can be multi-character, multi-column strings —
including "character ramps" where a big glyph greebles down through
density characters into the rule (`🎃▓▒░`) — and so the horizontal
rule `h` can be a repeating UTF pattern (`─┄`, `░▒`) instead of one
char. Body rows keep their 1-column `v`. Wanted for novelty themes
(halloween with actual pumpkins) without breaking the box-alignment
invariant that makes T6 a correctness rule.

## Method

`main.rs` (cargo, unicode-width pinned `=0.2.2` — the validator's own
ruler) answers the two questions a program can:

1. what unicode-width claims for candidate glyphs, including the VS16
   presentation-selector variants;
2. whether the proposed arithmetic — the corner's overhang beyond one
   column eats the horizontal RULE, `inner` untouched — tiles top,
   body, and bottom rows to the same column count.

`probe.zsh` answers the question it can't: whether the actual terminal
agrees with unicode-width, by printing each glyph and reading the
cursor position back (CPR). Run it per terminal you care about.

```
cargo run --quiet
./probe.zsh        # in a real terminal
```

## Results (2026-08-06, unicode-width 0.2.2) [MEASURED]

- probe.zsh on the operator's terminal (TERM=xterm-256color,
  2026-08-06): agreement with unicode-width on every shipped glyph —
  🎃 🦇 👻 💀 ⚡ all 2 columns, ╭ 1, `🎃─` 3, `🦇🦇` 4. The VS16 pairs
  also matched there (🕷 bare 1 / +VS16 2), which is exactly the
  terminal-dependent behaviour that keeps them banned: this emulator
  agrees, others don't.

- Fully-qualified emoji — 🎃 U+1F383, 🦇 U+1F987, 👻 U+1F47B,
  💀 U+1F480, ⚡ U+26A1 — are 2 columns, and terminals broadly agree:
  these are emoji-presentation-by-default codepoints.
- VS16-dependent codepoints are a trapdoor both ways: 🕷 U+1F577 bare
  measures 1 column (text presentation) but most terminal fonts draw
  it 2 — the spike's third render shows the bottom border skewed one
  column by exactly this. With VS16 appended unicode-width says 2 but
  emulators disagree with each other. Same for 🕸 U+1F578.
- The rule-absorbs-overhang arithmetic tiles at every tried shape:
  single 2-col emoji corners, 4-col `💀💀💀` triples, 5-col ramps
  (`🎃▓▒░`), 6-col ramps (`🦇━╍╌┄`) — `[46, 46, 46]` against `lw=46`
  throughout.
- Cycling h's chars (each 1 column) to fill the rule tiles too, and
  degenerates to today's behaviour for a 1-char h. Pattern phase is
  per-row (always starts at the pattern's first char), which reads
  fine; right-side ramps mirror the pattern seam invisibly.
- The shade blocks ░▒▓ (U+2591–3) are East Asian AMBIGUOUS width —
  but so are ─ │ ╭ and every box-drawing char the themes already
  use, so ramps add no new exposure on ambiguous-wide terminals.
  Same for the partial blocks ▏…█, which make a clean density ramp
  (`█▊▌▎` — the heavy-metal render) out of universally-present chars.
- Powerline/oh-my-posh PUA glyphs (U+E0B0–E0B7) measure 1 column and
  tile, but render as tofu without a Nerd Font — the motivating case
  for a `requires` directive (below). Legacy-computing wedges
  (U+1FB00+) are the same story with even spottier font support.
- PETSCII-style quadrant frames (`▛▀▜`) tile, but the BOTTOM edge
  needs a different rule char (`▄`) than the top (`▀`) — one h key
  cannot say that. An optional `h-bottom` (falling back to `h`)
  closes it; bottom corners are already separate keys.

## Verdict — GO, with two guards

The layout change is contained: `border_row` subtracts
`(wcols(l)−1) + (wcols(r)−1)` from the rule (and the label budget),
and the rule fills by cycling h's chars; everything else stands. The
guards belong in `validate()`, which is also what a `theme lint`
command exposes:

1. **Width-ambiguous codepoints are rejected in every glyph**: VS16
   (U+FE0F, and the whole variation-selector block), ZWJ (U+200D),
   and pictographs ≥ U+1F000 that unicode-width calls NARROW (the
   exact disagreement case 🕷 measured). unicode-width and the
   terminal must have no room to disagree, or the misalignment reads
   as a malfunction (the T6 rationale, kept).
2. **Corner column width is capped** (≤8 per corner, ramps included)
   so the rule keeps ≥1 column at minimum card width and a corner
   can never swallow the label.
3. **h's chars are each exactly 1 column** (≤8 chars), so truncating
   the cycle at any rule length stays column-exact.

`v`, `sel`/`nosel`, and the gutter glyphs stay exactly one column:
`inner` and the marker arithmetic assume it, and nothing novelty
themes want needs them wider.

Additionally a theme declares what its glyphs assume of the font, as
a ladder: `requires = "ascii" | "unicode" | "emoji" | "nerd-font"`.
The linter infers the minimum tier from the glyphs actually used
(>0x7F → unicode; emoji-presentation pictographs → emoji; PUA or
legacy-computing → nerd-font) and rejects a declaration below it;
`theme list` can surface the tier so tofu reads as "requires a Nerd
Font", not breakage. This retires T7's blanket emoji ban in favour
of declared, lintable requirements — shipped DEFAULTS still stay at
`unicode` or below.
