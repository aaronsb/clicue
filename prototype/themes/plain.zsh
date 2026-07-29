#!/usr/bin/env zsh
# plain — ASCII box drawing, no colour assumptions.
#
# For terminals where the font, the TERM entry or a remote session cannot be relied
# on: a serial console, a CI log, `TERM=dumb`, a screen reader, or any font without
# box drawing. Nothing here needs more than 7-bit ASCII.
#
# Colours are kept but pushed toward the terminal's own palette rather than
# hex, so a light-background terminal stays readable. region_highlight accepts
# named colours as well as hex.

CLICUE_THEME+=(
  border  'blue'
  accent  'cyan'
  text    'default'
  gloss   'default'
  selbg   'blue'
  seltext 'white'
  hint    'default'
  ghost   'default'
  badge   'blue'
  badgefg 'white'
)

CLICUE_GLYPH+=(
  tl '+'  tr '+'
  bl '+'  br '+'
  jl '+'  jr '+'
  v  '|'  h  '-'
  sel '>' nosel ' '

  # source gutter, 7-bit only. plain is the reference fallback, so it states every
  # glyph explicitly rather than inheriting from the base — someone reading this file
  # to learn the vocabulary should see all of it.
  k_alias '=' k_function 'f' k_builtin '*' k_system '$'
  k_history 'h' k_flag '-' k_sub '>' k_none ' '
)
