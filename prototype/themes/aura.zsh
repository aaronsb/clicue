#!/usr/bin/env zsh
# aura — the default. Rounded Unicode box drawing, Aura-derived palette.
#
# Requires a font with U+2500 box drawing, which is near-universal — including in
# the default terminal fonts on Linux, macOS and Windows. It deliberately does NOT
# use Nerd Font or emoji glyphs: those are not present by default anywhere, and a
# missing glyph renders as a hollow box, which reads as breakage rather than style.
# A theme that wants them can set them; that is an explicit opt-in by an operator
# who knows their font.

CLICUE_THEME+=(
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

CLICUE_GLYPH+=(
  tl '╭'  tr '╮'
  bl '╰'  br '╯'
  jl '├'  jr '┤'
  v  '│'  h  '─'
  sel '▸' nosel ' '
)
