#!/usr/bin/env zsh
# clicue — theme layer
#
# A theme owns two vocabularies and nothing else:
#
#   CLICUE_THEME   colours, as region_highlight accepts them
#   CLICUE_GLYPH   box drawing and markers
#
# Themes are legibility, not decoration (SPEC design value 3). The reason this is a
# separate loadable file rather than a palette constant is that different operators
# need different visual encodings — contrast, density, colour-blind-safe hues, or no
# colour at all — and a glyph set the terminal's font cannot render looks like a
# malfunction rather than a style. That makes the glyph set a correctness concern,
# so it has to be configurable with a safe default, not detected.
#
#   zstyle ':clicue:*' theme aura     # the default
#   zstyle ':clicue:*' theme plain    # ASCII box drawing, no colour assumptions
#
# A theme file assigns into the two associations. It does not need to define every
# key: _clicue_theme_load starts from the built-in defaults below, so a theme that
# only wants to change the accent colour is three lines long.

typeset -gA CLICUE_THEME=()
typeset -gA CLICUE_GLYPH=()

# ── the fallback theme, which is also the contract ───────────────────────────
# Deliberately ASCII and colour-light. This is what a theme is merged ON TOP OF, so
# a missing key degrades to something that renders in any terminal rather than to
# an empty string — an empty glyph would silently collapse the card's borders, and
# an empty colour would produce a region_highlight spec zsh rejects.
typeset -gA _clicue_theme_base=(
  border  '#a277ff'
  accent  '#61ffca'
  text    '#edecee'
  gloss   '#9692a8'
  selbg   '#3d375e'
  seltext '#ffffff'
  hint    '#6d6a7f'
  ghost   '#6d6a7f'
  badge   '#3d375e'
  badgefg '#61ffca'
)

typeset -gA _clicue_glyph_base=(
  tl      '+'      # top-left corner
  tr      '+'      # top-right
  bl      '+'      # bottom-left
  br      '+'      # bottom-right
  jl      '+'      # left join, where one box meets the next
  jr      '+'      # right join
  v       '|'      # vertical edge
  h       '-'      # horizontal rule
  sel     '>'      # selection marker
  nosel   ' '      # its width must match `sel`, or every row shifts
)

typeset -g _clicue_theme_name=''

# The horizontal rule glyph, as a PLAIN scalar, padded with the (p) flag.
#
# Two separate traps here, both of which emit their own source text into the border
# instead of drawing a line. `${(l:n::pad:)}` does not expand a SUBSCRIPTED
# parameter in the pad argument, so ${CLICUE_GLYPH[h]} fails; and it does not expand
# a plain parameter either, so $_clicue_hg fails too. Only `${(pl:n::$var:)}` works
# — (p) is what makes flag arguments subject to expansion. [MEASURED]
#
# Kept in sync by _clicue_theme_load, the only thing that may write CLICUE_GLYPH.
typeset -g _clicue_hg='-'

# Every key the renderer reads. Listed explicitly so a theme that forgets one is
# caught here rather than by a broken card: a missing colour makes zsh reject the
# whole region_highlight spec, and the operator sees an uncoloured card with no
# indication why.
typeset -ga _clicue_theme_keys=(
  border accent text gloss selbg seltext hint ghost badge badgefg
)
typeset -ga _clicue_glyph_keys=( tl tr bl br jl jr v h sel nosel )

# Load a theme by name, merged over the base. Returns non-zero and leaves the base
# in place if the file is missing or incomplete — a half-applied theme is worse
# than the default, because the operator cannot tell which parts took effect.
_clicue_theme_load() {
  local name=${1:-aura}
  local dir=${2:-${CLICUE_DIR}/themes}

  CLICUE_THEME=( "${(@kv)_clicue_theme_base}" )
  CLICUE_GLYPH=( "${(@kv)_clicue_glyph_base}" )
  _clicue_theme_name='base'

  local f=$dir/${name}.zsh
  if [[ ! -r $f ]]; then
    print -u2 "clicue: theme '${name}' not found at ${f} — using the built-in default"
    _clicue_hg=${CLICUE_GLYPH[h]}
    return 1
  fi

  source $f

  # width of the selection marker and its blank counterpart must agree, or the
  # unselected rows sit one column off the selected one
  if (( ${#CLICUE_GLYPH[sel]} != ${#CLICUE_GLYPH[nosel]} )); then
    print -u2 "clicue: theme '${name}': sel and nosel differ in width — rows will not align"
  fi

  local k
  local -a missing=()
  for k in $_clicue_theme_keys; do
    [[ -n ${CLICUE_THEME[$k]} ]] || missing+=( "THEME[$k]" )
  done
  for k in $_clicue_glyph_keys; do
    (( ${+CLICUE_GLYPH[$k]} )) || missing+=( "GLYPH[$k]" )
  done
  if (( ${#missing} )); then
    print -u2 "clicue: theme '${name}' is missing ${(j:, :)missing} — using the built-in default"
    CLICUE_THEME=( "${(@kv)_clicue_theme_base}" )
    CLICUE_GLYPH=( "${(@kv)_clicue_glyph_base}" )
    _clicue_hg=${CLICUE_GLYPH[h]}
    return 1
  fi

  _clicue_theme_name=$name
  _clicue_hg=${CLICUE_GLYPH[h]}
  return 0
}

# Convenience for trying a theme without restarting the shell.
clicue-theme() {
  if (( ! $# )); then
    print -r -- "theme: ${_clicue_theme_name}"
    print -r -- "available: ${${(f)"$(print -rl -- ${CLICUE_DIR}/themes/*.zsh(N:t:r))"}}"
    return 0
  fi
  _clicue_theme_load $1 || return 1
  print -r -- "clicue: theme is now ${_clicue_theme_name}"
  return 0
}
