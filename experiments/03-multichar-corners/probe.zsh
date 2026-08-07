#!/usr/bin/env zsh
# The half the spike binary cannot answer: does THIS terminal render each
# glyph at the width unicode-width claims? Prints the glyph, asks the
# terminal where the cursor landed (CPR, ESC[6n), and compares. Run it in
# every terminal you care about — kitty, alacritty, foot, gnome-terminal
# disagree exactly where this matters (VS16 sequences).
# Needs a real tty: the CPR reply comes from the emulator, not the pty.
set -u
zmodload zsh/system

[[ -t 0 && -t 1 ]] || { print -u2 "probe.zsh needs a real terminal (interactive tty)"; exit 1; }

measure() {
  local g=$1 reply='' ch row col
  # park at column 1, print, ask
  print -n -- $'\r'"$g"$'\e[6n'
  # CPR: ESC [ row ; col R
  while sysread -t 2 -c 1 ch 2>/dev/null; do
    reply+=$ch
    [[ $ch == R ]] && break
  done
  print -n $'\r\e[K'
  col=${${reply##*\[*;}%R}
  print -r -- "$(( col - 1 ))  ${(q)g}"
}

# raw mode so the CPR reply is readable byte-by-byte
old_stty=$(stty -g)
stty -echo -icanon min 0 time 0
{
  print "cols  glyph   (terminal: $TERM)"
  for g in "╭" "🎃" "🦇" "👻" "💀" "🕷" $'\U1F577️' "🕸" $'\U1F578️' "⚡" "🎃─" "🦇🦇"; do
    measure "$g"
  done
} always {
  stty "$old_stty"
}
