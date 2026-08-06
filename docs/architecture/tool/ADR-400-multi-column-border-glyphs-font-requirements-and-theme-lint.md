---
status: Accepted
date: 2026-08-06
deciders:
  - aaronsb
  - claude
related: []
---

# ADR-400: Multi-column border glyphs, font requirements, and theme lint

## Context

The theme contract (spec/themes.md) pins every box glyph to exactly one
column (T6) and bans emoji outright in shipped themes (T7). Both rules
exist for one reason: a glyph whose rendered width disagrees with the
layout arithmetic skews the card, and misalignment reads as a
malfunction, not a style. But the rules overshoot the reason. Novelty
themes want decorated borders — a jack-o-lantern corner that "greebles"
down through density characters into the rule (`🎃▓▒░`), partial-block
ramps (`█▊▌▎`), powerline caps, PETSCII quadrant frames — and none of
that is unsound as long as every row still tiles to the same column
count.

Experiment 03 (`experiments/03-multichar-corners/`) established
[MEASURED]:

- Corner strings of any column width tile perfectly if the horizontal
  rule absorbs the overhang: `rule = inner − wcols(label) −
  (wcols(l)−1) − (wcols(r)−1)`. Body rows keep their 1-column `v`.
- Filling the rule by cycling a multi-char `h` pattern (each char one
  column) tiles too, and degenerates to today's `repeat` for 1-char h.
- The real hazard is narrower than T6 assumed: codepoints whose width
  unicode-width and the terminal can DISAGREE about — VS16-dependent
  pictographs (🕷 measures 1, renders 2), ZWJ sequences. Fully-
  qualified emoji (🎃 🦇 👻 💀) are consistently two columns.
- PETSCII frames need a different bottom rule (`▄`) than top (`▀`).
- Powerline PUA glyphs tile arithmetically but are tofu without a Nerd
  Font — a FONT requirement, not a width problem.

Separately, theme authors outside the repo have no way to check a theme
file without installing it and eyeballing the result; the validator is
internal to the daemon.

## Decision

**1. Corners and junctions become multi-column strings.** `tl`, `tr`,
`bl`, `br`, `jl`, `jr` accept 1–8 column strings. The border rows
subtract the corner overhang from the rule so every row spans the same
columns; the label budget shrinks by the same amount. `v`, `sel`,
`nosel`, and the gutter glyphs stay exactly one column — `inner` and
the marker arithmetic assume it, and nothing themes want needs them
wider.

**2. The rule is a cycled pattern.** `h` accepts 1–8 chars, each
exactly one column, cycled to fill and truncated column-exact. A new
optional `h-bottom` (default: `h`) serves the bottom edge, closing the
PETSCII case. Junction rows use `h`.

**3. Width-ambiguity is rejected, everywhere, by name.** Every glyph
string rejects variation selectors (U+FE00–FE0F), ZWJ (U+200D), and
pictographs at U+1F000+ that unicode-width measures as narrow — the
exact codepoints where ruler and terminal can disagree. This KEEPS
T6's rationale while retiring its blanket width rule.

**4. Themes declare a font tier: `requires`.** A ladder — `ascii` <
`unicode` < `emoji` < `nerd-font` — declared in the theme file.
Validation infers the minimum tier from the glyphs actually used
(any >0x7F → unicode; emoji-presentation pictographs → emoji; PUA
U+E000–F8FF or legacy-computing U+1FB00+ → nerd-font) and rejects a
declaration below the inferred tier. Absent means: the inferred tier.
`theme list` surfaces tiers above `unicode`, so tofu reads as
"requires a Nerd Font", not breakage. This retires T7's blanket ban:
shipped DEFAULT themes (base, aura, mono, plain) stay at `unicode` or
below; novelty themes may require more, declared and surfaced.

**5. `clicue theme lint <file|name>`.** The same `from_toml` +
`validate` path the loader runs, exposed as a command: parse errors,
validation errors, the inferred tier, nonzero exit on failure. One
validator, two doors — the linter can never drift from the loader.

## Consequences

- The halloween palette (orange/purple, no spooky glyphs) is renamed
  to a synthwave-flavoured theme; a new halloween ships with emoji
  ramp corners under `requires = "emoji"`, and further novelty themes
  (petscii, powerline) demonstrate the other tiers.
- spec/themes.md T6 and T7 are amended to point here; the experiment
  README carries the measurements.
- Swatches for tier-requiring themes show tofu in fonts that lack the
  glyphs — accepted, since the tier label sits next to them.
- The gradient span arithmetic keys on char counts, not columns; with
  multi-char corners the sweep drifts by a few chars at the edges —
  invisible at card widths, noted in code.
