# Themes — legibility, not decoration

Extraction of `prototype/lib/theme.zsh` and `prototype/themes/*.zsh`. Themes
are an accessibility surface (SPEC design value 3): different operators need
different visual encodings — contrast, no colour, ASCII-only — and a glyph
the font cannot draw reads as a malfunction, which makes the glyph set a
correctness concern. In the rewrite themes are TOML files owned by the
daemon; `clicue theme` lists, sets, and previews.

- T1 [domain] A theme owns exactly two vocabularies and nothing else: a
  palette (colours in the forms the highlight mechanism accepts — hex or
  terminal-named) and a glyph set (box drawing, selection marker, source
  gutter). (theme.zsh:1–24)
- T1a [domain] Two palette keys are card-scoped rather than element-scoped,
  both optional: `panel` (a bg= style laid as per-row base spans under the
  whole card, its bg merged into any span that lacks one — region_highlight
  replaces the WHOLE attribute set per char, and a bg crossing a newline
  smears to the terminal edge on BCE terminals) and `border-gradient` (≥2
  #rrggbb stops interpolated along horizontal borders in width-scaled
  segments, ~24 per row, equal neighbours coalesced — the shim pays per
  span). Added 2026-08-03; validated like every other key.
- T2 [domain] Themes merge over a base; a partial theme is legal — changing
  only the accent colour is a three-line theme. (theme.zsh:18–21, 95–103)
- T3 [domain] Every key the renderer reads is validated at load. A theme
  missing any key falls back ENTIRELY to the base, with a message naming
  the missing keys — a half-applied theme is worse than the default because
  the operator cannot tell which parts took effect. An empty glyph silently
  collapses the card's borders; an empty colour produces a highlight spec
  the host rejects. (theme.zsh:26–31, 87–93, 130–144)
- T4 [domain] The base is the contract and must render anywhere: ASCII box
  drawing, terminal-palette-safe colours. The prototype violates its own
  claim here — its base palette is byte-identical to Aura's ten hex values
  (review #17). The rewrite makes the base genuinely terminal-default and
  ships aura as an ordinary theme. (theme.zsh:26–42; themes/aura.zsh:11–22)
- T5 [domain] The selection marker and its blank counterpart must be the
  same width, or every unselected row sits one column off the selected one.
  (theme.zsh:117–119; base comment at 44–54)
- T6 [domain] Gutter glyphs are exactly one COLUMN wide — East Asian Wide
  and emoji codepoints are two columns in most terminals and shift the
  whole row. The prototype polices character count by hand; the daemon
  measures columns with unicode-width, which is the actual invariant.
  (theme.zsh:122–127; themes/aura.zsh comments)
- T7 [domain] Default themes use no Nerd Font or emoji glyphs: those are
  present by default nowhere, and a missing glyph renders as a hollow box —
  breakage, not style. An operator who knows their font can opt in
  explicitly. (themes/aura.zsh:1–10)
- T8 [domain] Three shipped encodings, each a distinct accessibility
  posture: aura (colour + Unicode), mono (Unicode, weight and dimming
  instead of hue — for operators for whom colour is not a channel), plain
  (7-bit ASCII, terminal-palette colours — serial console, TERM=dumb,
  screen reader, unreliable font). (themes/{aura,mono,plain}.zsh headers)
- T9 [domain] Themes switch at runtime without restart, and listing what is
  available is one command. (theme.zsh:151–161; rewrite: `clicue theme`
  with stdout preview of a sample card, per ADR-100)
- T10 [domain] Deduplicate what the review found copied: aura's and mono's
  glyph blocks are byte-identical, and plain restates the base's glyphs —
  the rewrite defines glyph SETS (ascii, unicode-rounded) referenced by
  themes, so adding a glyph key touches one place, not five. (review #17;
  themes/*.zsh)
- T11 [domain] Dead vocabulary is dropped, not carried: the badge/badgefg
  palette keys and the k_history gutter glyph are validated and themed but
  never rendered (review #18). They return only if a badge feature lands,
  as spec first.
- T12 [zsh-hazard, dies] The horizontal-rule glyph is mirrored into a plain
  scalar because zsh's pad flags do not expand subscripted parameters —
  only `${(pl:n::$var:)}` works. [MEASURED] The daemon renders; this dies.
  (theme.zsh:70–81)
- T13 [domain] The list swatch is drawn in the theme's FULL ground: a panel
  theme's swatch sits on its panel, a gradient theme's border glyphs sweep,
  exactly as the card will. A black swatch for a solid-blue theme (the
  2026-08-03 report) misinforms the one choice the swatch exists to serve.
  The swatch applies the renderer's own grounding rule — panel bg under
  every style without one, gaps included.
- T14 [domain] Themes are FILES. Resolution order: `<themes>/<name>.toml`
  first, compiled-in builtin second, base last — the file is what the
  operator edits (live, via the S7 reloader), the builtin is the fallback
  and the regeneration template, never a shadow over an edit. A MISSING
  file whose name is a builtin is regenerated from the template on load
  (`load_or_seed`), so the file is always the thing actually read and
  deleting it is the reset-to-default gesture. A BROKEN file is never
  rewritten — mid-edit is its normal cause and live reload its normal
  observer — and falls back to the builtin of the same name (closer to
  intent than base), messages naming the file. `clicue install` seeds
  every builtin's file (idempotent: existing files untouched, re-running
  after an upgrade tops up new themes); uninstall removes only files
  still byte-identical to their template — an edited file is operator
  data, not something install added. Serialization and parsing are pinned
  as inverses by a per-builtin round-trip test: a file that reproduces a
  different theme ships every operator a subtly different default.
