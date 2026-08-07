---
id: 04.001.H
domain: tool
mode: how-to
related: ["[[ADR-400]]"]
aliases: [theme-authoring]
---

# Write your own theme

Every theme is a TOML file in `~/.config/clicue/themes/`. Edits apply
live — the daemon reloads within a second, so keep a card on screen
while you work. This guide goes from a three-line recolor to a full
novelty theme with ramp corners; the contract behind it is
spec/themes.md and [[ADR-400]].

## Start from a copy

```zsh
cd ~/.config/clicue/themes
cp aura.toml mytheme.toml       # any shipped theme is a starting point
clicue theme mytheme            # switch to it; edits now show live
```

A partial file is legal: absent keys fall back to the base theme, so
deleting everything but the keys you change is good style. The
smallest real theme is three lines:

```toml
[palette]
accent = "fg=#ff8800"
```

Deleting a *shipped* theme's file regenerates it pristine — so
experiment freely on copies, and reset a shipped file by removing it.

## Lint as you go

```zsh
clicue theme lint mytheme                # what the loader would serve
clicue theme lint path/to/mytheme.toml   # a file, installed or not
```

The linter runs the exact validation the daemon runs — parse errors,
contract violations, and the inferred font tier. A theme that lints
clean loads clean; a broken file never half-applies (the daemon falls
back whole, naming the problem).

## The two vocabularies

**Palette** — style strings in the highlight syntax: `fg=#a277ff`,
`fg=blue`, `bold`, `fg=white,bg=#444444`. Keys: `border`, `accent`,
`text`, `gloss`, `hint`, `ghost`, `selected`, `match`, plus two
card-scoped extras — `panel` (a `bg=` laid under the whole card) and
`border-gradient` (≥2 `#rrggbb` stops swept along horizontal borders):

```toml
[palette]
panel = "bg=#1c1025"
border-gradient = ["#f97316", "#a78bfa", "#f97316"]
```

**Glyphs** — the box, markers, and source gutter. Set
`glyph-set = "unicode-rounded"` (or omit for ASCII) and override
individual keys:

```toml
glyph-set = "unicode-rounded"

[glyphs]
sel = "»"
```

## Corners can be ramps

Corners and junctions (`tl` `tr` `bl` `br` `jl` `jr`) accept strings
up to 8 columns wide. The idiom is a *ramp*: a big glyph greebling
down through density characters into the border rule, which absorbs
the extra width so every row still tiles:

```toml
[glyphs]
tl = "🎃▓▒░"     # pumpkin, dark→light, into the rule
tr = "░▒▓🎃"     # mirror it on the right
```

The rule itself (`h`) is a repeating pattern of one-column chars, and
`h-bottom` (default: `h`) serves the bottom edge — a PETSCII frame
wants `▀` on top and `▄` below:

```toml
h = "▀"
h-bottom = "▄"
```

Everything else — `v`, `sel`/`nosel`, the `k_*` gutter — stays
exactly one column; the row arithmetic depends on it.

**What the linter rejects, and why:** control characters, variation
selectors, ZWJ, and text-presentation pictographs (🕷 without VS16)
— codepoints whose width the ruler and your terminal can disagree
about. A one-column miss skews every row, and misalignment reads as
a malfunction, not a style. Shipped-safe emoji are the ones that are
two columns everywhere: 🎃 🦇 👻 💀 ⚡.

## Declare what you assume of the font

```toml
requires = "emoji"    # ascii < unicode < emoji < nerd-font
```

The linter infers the minimum tier from your glyphs and rejects a
declaration below it; `clicue theme list` shows tiers above
`unicode`, so a user without the font reads "requires nerd-font"
instead of assuming breakage. Nerd Font PUA glyphs are best written
as `\uXXXX` escapes — they're tofu in most editors:

```toml
tl = "\uE0B6█\uE0B0"    # powerline round cap, block, triangle
```

## Check it end to end

```zsh
clicue theme lint mytheme      # the contract
clicue theme preview mytheme   # a rendered sample card, colours included
clicue theme list              # your swatch among the others
```

If a card ever renders misaligned in *your* terminal while the lint
is clean, run `experiments/03-multichar-corners/probe.zsh` from a
repo checkout — it measures what your terminal actually draws per
glyph and tells you which codepoint disagrees with the ruler.
