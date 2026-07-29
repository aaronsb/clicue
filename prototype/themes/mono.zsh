#!/usr/bin/env zsh
# mono — Unicode box drawing, weight and dimming instead of hue.
#
# For operators for whom colour is not a usable channel, and for anyone who wants
# the card to disappear into their existing prompt. Legibility here comes from the
# selection bar and from dimming the descriptions, not from distinguishing sources
# by colour — which means source identity has to be carried by the badge text, so
# do not pair this theme with badges turned off.

CLICUE_THEME+=(
  border  'default'
  accent  'default'
  text    'default'
  gloss   '#808080'
  selbg   '#444444'
  seltext 'white'
  hint    '#808080'
  ghost   '#808080'
  badge   '#444444'
  badgefg 'white'
)

CLICUE_GLYPH+=(
  tl '╭'  tr '╮'
  bl '╰'  br '╯'
  jl '├'  jr '┤'
  v  '│'  h  '─'
  sel '▸' nosel ' '

  # source gutter — one column each, from ranges present in ordinary terminal fonts
  k_alias '≈'  k_function 'ƒ'  k_builtin '◆'  k_system '▪'  k_history '↺'  k_flag '·'  k_sub '›'  k_none ' '
)
