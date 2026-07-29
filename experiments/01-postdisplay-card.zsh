#!/usr/bin/env zsh
# EXPERIMENT 01 — throwaway. Delete when it has answered its questions.
#
# Q1. Can a rich multi-line cue card be drawn in POSTDISPLAY at all?
# Q2. What is the real styling ceiling of region_highlight? (italic? inverse?)
# Q3. Does an OSC 8 hyperlink escape corrupt ZLE's width accounting?
# Q4. Does the terminal auto-linkify plain-text paths/URLs inside the card?
# Q5. Can all of that be done while CAPTURING NOTHING — coexisting with
#     zsh-syntax-highlighting and oh-my-posh in the same live shell?
#
# Usage (in a scratch shell, NOT your login shell):
#   source /path/to/clicue/experiments/01-postdisplay-card.zsh
# then just type. Ctrl-C to clear. `clicue-exp-off` to unhook.

emulate -L zsh
setopt local_options

autoload -Uz add-zle-hook-widget

# ── palette (Aura, from IRIS) ─────────────────────────────────────────────────
typeset -gA _cx=(
  border   '#a277ff'
  accent   '#61ffca'
  text     '#edecee'
  gloss    '#9692a8'
  selbg    '#3d375e'
  seltext  '#ffffff'
)

# ── fake candidates: name / gloss / source ────────────────────────────────────
# Deliberately includes a path and a URL to test Q4.
typeset -ga _cx_rows=(
  'commit|record changes to the repository|builtin'
  'checkout|switch branches or restore working tree files|builtin'
  'cherry|find commits not merged upstream|builtin'
  'cherry-pick|apply changes introduced by some existing commits|builtin'
  '/etc/zsh/zshrc|a plain-text PATH — is it clickable?|path'
  'https://zsh.org|a plain-text URL — is it clickable?|url'
)

# Q3 toggle: set to 1 to embed a real OSC 8 hyperlink and see what breaks.
: ${CLICUE_TEST_OSC8:=0}

# ── card renderer ─────────────────────────────────────────────────────────────
# Returns the card text in REPLY, and the highlight spans in reply[].
# Offsets are relative to the start of POSTDISPLAY; caller adds the base.
_cx_render_card() {
  local buf=$1
  local -a lines specs
  local w=64 name gloss src row
  local -i off=0 lineno=0

  # top border with an inline counter, like IRIS's `1/100`
  local n=0
  for row in $_cx_rows; do [[ ${row%%|*} == ${buf}* ]] && (( n++ )); done
  (( n == 0 )) && { REPLY=''; reply=(); return 1 }

  local label=" ${n}/${#_cx_rows} "
  local top="╭─${label}$(printf '─%.0s' {1..$(( w - ${#label} - 2 ))})╮"
  lines+=( '' "$top" )

  local -i sel=1 idx=0
  for row in $_cx_rows; do
    name=${row%%|*}; row=${row#*|}
    gloss=${row%%|*}; src=${row##*|}
    [[ $name == ${buf}* ]] || continue
    (( idx++ ))

    local marker='  ' pad
    (( idx == sel )) && marker=' ▸'

    # column layout: marker + name(22) + gloss(rest)
    local namecol=${(r:22:)name}
    local glosscol=${(r:$(( w - 26 )):)gloss}
    local body="│${marker} ${namecol}${glosscol}│"
    lines+=( "$body" )
  done

  lines+=( "╰$(printf '─%.0s' {1..$(( w - 22 ))}) <Tab> accept · <^R> mode ─╯" )

  REPLY=${(F)lines}

  # ── highlight spans, computed over the assembled string ────────────────────
  # We locate each line by scanning, so spans stay correct regardless of widths.
  specs=()
  local -i pos=0 i
  local ln
  for (( i = 1; i <= ${#lines}; i++ )); do
    ln=${lines[i]}
    if [[ $ln == '╭'* || $ln == '╰'* ]]; then
      specs+=( "$pos $(( pos + ${#ln} )) fg=${_cx[border]}" )
    elif [[ $ln == '│'* ]]; then
      # border glyphs
      specs+=( "$pos $(( pos + 1 )) fg=${_cx[border]}" )
      specs+=( "$(( pos + ${#ln} - 1 )) $(( pos + ${#ln} )) fg=${_cx[border]}" )
      # name column (after '│' + 2-char marker + 1 space = 4)
      specs+=( "$(( pos + 4 )) $(( pos + 26 )) fg=${_cx[accent]},bold" )
      # gloss column — TEST: does `italic` do anything? (expected: no)
      specs+=( "$(( pos + 26 )) $(( pos + ${#ln} - 1 )) fg=${_cx[gloss]},italic" )
      # selected row gets a full-width inverse bar — TEST: standout
      if [[ $ln == '│ ▸'* ]]; then
        specs+=( "$pos $(( pos + ${#ln} )) fg=${_cx[seltext]},bg=${_cx[selbg]}" )
      fi
    fi
    (( pos += ${#ln} + 1 ))   # +1 for the newline
  done

  reply=( $specs )
  return 0
}

# ── the hook: draws the card, captures nothing ────────────────────────────────
_cx_pre_redraw() {
  # never fight for the array — drop only OUR memo-tagged spans
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  POSTDISPLAY=''

  local buf=$BUFFER
  [[ -z $buf ]] && return 0

  local REPLY; local -a reply
  _cx_render_card "$buf" || return 0

  local card=$REPLY
  local -a specs=( $reply )

  # Q3: optionally splice in a real OSC 8 hyperlink and see if widths break
  if (( CLICUE_TEST_OSC8 )); then
    local osc=$'\e]8;;https://zsh.org\e\\LINK\e]8;;\e\\'
    card="${card}"$'\n'"  ${osc}"
  fi

  local -i base=${#BUFFER}
  POSTDISPLAY=$card

  local s
  for s in $specs; do
    local a=${s%% *}; local rest=${s#* }
    local b=${rest%% *}; local style=${rest#* }
    region_highlight+=( "$(( base + a )) $(( base + b )) ${style},memo=clicue" )
  done
}

_cx_line_finish() {
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  POSTDISPLAY=''
}

clicue-exp-off() {
  add-zle-hook-widget -d line-pre-redraw _cx_pre_redraw
  add-zle-hook-widget -d line-finish     _cx_line_finish
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  POSTDISPLAY=''
  print "clicue experiment unhooked."
}

add-zle-hook-widget line-pre-redraw _cx_pre_redraw
add-zle-hook-widget line-finish     _cx_line_finish

print -r -- "clicue experiment 01 loaded."
print -r -- "  type 'c' / 'ch' / 'commit' to see the card narrow"
print -r -- "  CLICUE_TEST_OSC8=1 then retype, to test Q3 (hyperlink vs width math)"
print -r -- "  clicue-exp-off   to unhook"
