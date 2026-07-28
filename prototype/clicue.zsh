#!/usr/bin/env zsh
# clicue — prototype presentation engine
#
# SCOPE (v1): command-position candidates only. Typing the first word of a line
# shows a cue card of matching commands/aliases/functions with glosses from the
# corpus, ranked by frequency derived from shell history. Subcommand and flag
# completion needs the candidate-source adapter talking to compsys — deliberately
# not in this prototype. See SPEC.md components 3 and 5.
#
# Composability contract (SPEC.md design value 2):
#   - registers via add-zle-hook-widget; never zle -N a hook someone else owns
#   - tags region_highlight entries with memo=clicue
#   - PRESERVES any existing POSTDISPLAY (e.g. zsh-autosuggestions) and appends
#     below it rather than overwriting
#   - never touches :completion:* zstyles
#
# Config:
#   zstyle ':clicue:*' min-input 1      # chars before the card appears
#   zstyle ':clicue:*' max-rows   8
#   zstyle ':clicue:*' enabled    yes

emulate -L zsh
setopt local_options

autoload -Uz add-zle-hook-widget

typeset -g CLICUE_DIR=${0:A:h}
typeset -g CLICUE_CACHE=${XDG_CACHE_HOME:-$HOME/.cache}/clicue/corpus.zsh
typeset -g _clicue_loaded=0
typeset -g _clicue_card=''
typeset -g _clicue_text=''
typeset -g _clicue_g=''
typeset -ga _clicue_spans=()
typeset -g  _clicue_sel=1          # 1-based selection within the candidate list
typeset -g  _clicue_top=1          # first visible row (window start)
typeset -g  _clicue_engaged=0      # has the operator actually used the card?
typeset -g  _clicue_visible=0
typeset -g  _clicue_lastbuf=$'\0'
typeset -ga _clicue_cands=()
typeset -g  _clicue_orig_tab=''
typeset -g  _clicue_mode=cmd       # cmd | arg
typeset -g  _clicue_cmd=''         # in arg mode, the command being argued
typeset -g  _clicue_pfx=''         # the partial word being completed
typeset -g  _clicue_suppressed=0   # dismissed by the operator, stay down
typeset -g  _clicue_info=0         # card is informational, not a candidate list

# ── theme (Aura, from IRIS — see SPEC.md design language) ────────────────────
typeset -gA CLICUE_THEME=(
  border  '#a277ff'
  accent  '#61ffca'
  text    '#edecee'
  gloss   '#9692a8'
  selbg   '#3d375e'
  seltext '#ffffff'
  hint    '#6d6a7f'
)

# ── lazy corpus load: startup pays nothing; first card pays ~8ms once ────────
_clicue_load() {
  (( _clicue_loaded )) && return 0
  _clicue_loaded=1
  [[ -r $CLICUE_CACHE ]] || { typeset -gA CLICUE_GLOSS CLICUE_KIND CLICUE_FREQ; return 1 }
  source $CLICUE_CACHE
  return 0
}

clicue-rebuild() {
  zsh -i -c "source ${CLICUE_DIR}/build-corpus.zsh"
  _clicue_loaded=0
  _clicue_load
}

# ── candidate generation (command position only, v1) ─────────────────────────
# Sets reply=( name:kind ... ) ranked by frequency then name.
_clicue_candidates() {
  local pfx=$1
  local n
  typeset -gA _clicue_kind=()

  # cheap in-memory sources — no forks. Source precedence: alias > function >
  # builtin > command.
  for n in ${(k)aliases[(I)${pfx}*]};   do _clicue_kind[$n]=alias;   done
  for n in ${(k)functions[(I)${pfx}*]}; do
    [[ $n == [_.]* ]] && continue
    (( ${+_clicue_kind[$n]} )) || _clicue_kind[$n]=function
  done
  for n in ${(k)builtins[(I)${pfx}*]} ${(M)reswords:#${pfx}*}; do
    (( ${+_clicue_kind[$n]} )) || _clicue_kind[$n]=builtin
  done
  for n in ${(k)commands[(I)${pfx}*]}; do
    (( ${+_clicue_kind[$n]} )) || _clicue_kind[$n]=system
  done

  # Partition rather than rank-everything: frequency data covers only the
  # commands actually used (~173 here), so keying/sorting the whole match set
  # is wasted work. Frequent ones sort by count desc; the rest go alphabetical.
  local -a freqd rest
  local -i f
  for n in ${(k)_clicue_kind}; do
    f=${CLICUE_FREQ[$n]:-0}
    if (( f )); then
      freqd+=( "${(l:8::0:)$(( 99999999 - f ))}|$n" )   # zsh padding, no fork
    else
      rest+=( $n )
    fi
  done

  reply=( ${${(o)freqd}#*|} ${(o)rest} )
}

# ── argument candidates: what YOU have actually passed this command ──────────
# Sourced from history, already frequency-ranked at build time. No compsys and
# no forks — compsys would give the authoritative flag set with real
# descriptions, but needs the candidate-source adapter (component 3).
_clicue_arg_candidates() {
  local cmd=$1 pfx=$2
  local -a toks=( ${(s: :)CLICUE_ARGS[$cmd]} )
  (( ${#toks} )) || { reply=(); return 1 }
  if [[ -n $pfx ]]; then
    reply=( ${(M)toks:#${pfx}*} )
  else
    reply=( $toks )
  fi
  (( ${#reply} )) || return 1
  return 0
}

# ── gloss lookup ─────────────────────────────────────────────────────────────
_clicue_gloss() {
  local name=$1 kind=$2
  if [[ $_clicue_mode == arg ]]; then
    if (( _clicue_info )); then
      _clicue_g=${CLICUE_GLOSS[$name]:-'no recorded arguments'}
      return
    fi
    # Honest placeholder. Real flag descriptions need compsys or a --help/man
    # parse in the enrichment pipeline; usage count is at least true.
    local c=${CLICUE_ARGN[${_clicue_cmd}\|${name}]:-}
    _clicue_g=${c:+used ${c}×}
    return
  fi
  case $kind in
    alias)    _clicue_g=${aliases[$name]} ;;
    function) _clicue_g=${CLICUE_GLOSS[$name]:-'shell function'} ;;
    builtin)  _clicue_g=${CLICUE_GLOSS[$name]:-'shell builtin'} ;;
    *)        _clicue_g=${CLICUE_GLOSS[$name]:-''} ;;
  esac
}

# ── the card ─────────────────────────────────────────────────────────────────
# Builds REPLY (card text) and reply (highlight specs, offsets relative to card).
_clicue_render() {
  local pfx=$1
  local -a cands
  local -a reply            # scratch for the candidate generators
  if [[ $_clicue_mode == arg ]] && (( _clicue_info )); then
    reply=( $_clicue_cmd )
  elif [[ $_clicue_mode == arg ]]; then
    _clicue_arg_candidates $_clicue_cmd "$pfx" || { _clicue_info=1; reply=( $_clicue_cmd ) }
  else
    _clicue_candidates $pfx
  fi
  cands=( $reply )
  (( ${#cands} )) || return 1
  _clicue_cands=( $cands )

  local -i maxrows=8
  zstyle -s ':clicue:*' max-rows maxrows 2>/dev/null || maxrows=8

  local -i width=${COLUMNS:-80}
  (( width > 120 )) && width=120
  (( width < 40 ))  && width=40
  local -i inner=$(( width - 2 ))

  # name column: widest shown name, clamped
  local -i namew=0 i=0
  local -i _w0=$_clicue_top _w1=$(( _clicue_top + maxrows - 1 ))
  (( _w1 > ${#cands} )) && _w1=${#cands}
  (( _w0 < 1 )) && _w0=1
  for i in {$_w0..$_w1}; do
    local nm=${cands[i]}
    (( ${#nm} > namew )) && namew=${#nm}
  done
  (( namew > 28 )) && namew=28
  (( namew < 10 )) && namew=10

  local -i glossw=$(( inner - namew - 5 ))
  (( glossw < 10 )) && glossw=10

  # clamp selection, then slide the window to keep it visible
  (( _clicue_sel < 1 )) && _clicue_sel=1
  (( _clicue_sel > ${#cands} )) && _clicue_sel=${#cands}
  (( _clicue_sel < _clicue_top )) && _clicue_top=$_clicue_sel
  (( _clicue_sel > _clicue_top + maxrows - 1 )) && _clicue_top=$(( _clicue_sel - maxrows + 1 ))
  (( _clicue_top < 1 )) && _clicue_top=1

  local -a lines specs
  local total=${#cands}
  local -i last=$(( _clicue_top + maxrows - 1 ))
  (( last > total )) && last=$total
  local label=" ${_clicue_sel}/${total} "
  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  lines+=( "╭${label}${(l:$rule::─:):-}╮" )

  local -i idx=$(( _clicue_top - 1 ))
  local ent name kind g nmcol gcol extra
  local -a wrapped
  local -i issel=0
  for ent in ${cands[$_clicue_top,$last]}; do
    (( idx++ ))
    issel=$(( idx == _clicue_sel ))
    name=$ent; kind=${_clicue_kind[$ent]:-system}
    [[ $_clicue_mode == arg ]] && kind=arg
    _clicue_gloss $name $kind; g=$_clicue_g

    local marker='  '
    (( issel )) && marker=' ▸'

    nmcol=${(r:$namew:)${name[1,$namew]}}

    if (( issel )); then
      # design value 4: density inversely proportional to attention.
      # The focused row gets its full gloss, wrapped rather than truncated.
      wrapped=( ${(f)"$(print -r -- $g | fold -s -w $glossw)"} )
      gcol=${(r:$glossw:)${wrapped[1]}}
      lines+=( "│${marker} ${nmcol}  ${gcol}│" )
      for extra in ${wrapped[2,-1]}; do
        lines+=( "│   ${(r:$namew:)}  ${(r:$glossw:)extra}│" )
      done
    else
      (( ${#g} > glossw )) && g="${g[1,$(( glossw - 1 ))]}…"
      gcol=${(r:$glossw:)g}
      lines+=( "│${marker} ${nmcol}  ${gcol}│" )
    fi
  done

  local hint=' Alt+↑↓ scroll · Tab accept · Esc dismiss '
  (( _clicue_info )) && hint=' Esc dismiss '
  local -i brule=$(( inner - ${#hint} ))
  (( brule < 1 )) && brule=1
  lines+=( "╰${(l:$brule::─:):-}${hint}╯" )

  _clicue_text=$'\n'${(F)lines}

  # ── highlight spans over the assembled card ────────────────────────────────
  specs=()
  local -i pos=1     # leading newline
  local ln
  for ln in $lines; do
    local -i len=${#ln}
    if [[ $ln == ('╭'|'╰')* ]]; then
      specs+=( "$pos $(( pos + len )) fg=${CLICUE_THEME[border]}" )
    else
      specs+=( "$pos $(( pos + 1 )) fg=${CLICUE_THEME[border]}" )
      specs+=( "$(( pos + len - 1 )) $(( pos + len )) fg=${CLICUE_THEME[border]}" )
      specs+=( "$(( pos + 4 )) $(( pos + 4 + namew )) fg=${CLICUE_THEME[accent]},bold" )
      specs+=( "$(( pos + 6 + namew )) $(( pos + len - 1 )) fg=${CLICUE_THEME[gloss]}" )
      [[ $ln == '│ ▸'* ]] && \
        specs+=( "$pos $(( pos + len )) fg=${CLICUE_THEME[seltext]},bg=${CLICUE_THEME[selbg]}" )
    fi
    (( pos += len + 1 ))
  done

  _clicue_spans=( $specs )
  return 0
}

# ── hook ─────────────────────────────────────────────────────────────────────
_clicue_reset_sel() {
  _clicue_sel=1; _clicue_top=1; _clicue_engaged=0
}

_clicue_clear() {
  _clicue_visible=0
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  # only strip OUR card — leave anything else (autosuggestions) intact
  if [[ -n $_clicue_card && $POSTDISPLAY == *"$_clicue_card" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_clicue_card"}
  fi
  _clicue_card=''
}

_clicue_pre_redraw() {
  _clicue_clear

  # dismissed by Esc — stay down until the line is emptied or finished
  (( _clicue_suppressed )) && { [[ -n $LBUFFER ]] && return 0; _clicue_suppressed=0 }

  # While zsh's own completion menu owns the display, complist drives redisplay
  # and our region_highlight spans never land — the card would render as
  # colourless text stacked above a duplicate listing. Stand down instead.
  [[ $KEYMAP == menuselect ]] && return 0

  local on=yes
  zstyle -s ':clicue:*' enabled on 2>/dev/null || on=yes
  [[ $on == (no|off|0) ]] && return 0

  local -i mininput=1
  zstyle -s ':clicue:*' min-input mininput 2>/dev/null || mininput=1

  _clicue_load

  # ── where are we? position is decided PER SEGMENT ──────────────────────────
  # A pipe or separator starts a fresh command position, which is why the
  # buffer is split before anything else is decided.
  local buf=$LBUFFER
  local seg=${buf##*(\||\|\||;|&&)}      # last segment
  seg=${seg##[[:space:]]#}                 # strip leading blanks

  local -a words=( ${(z)seg} )
  local trailing=0
  [[ $seg == *[[:space:]] ]] && trailing=1

  if (( ${#words} == 0 )) || (( ${#words} == 1 && !trailing )); then
    # ── command position ────────────────────────────────────────────────────
    _clicue_mode=cmd
    _clicue_cmd=''
    _clicue_pfx=$seg
    (( ${#seg} < mininput )) && return 0
    [[ $seg == [-./]* ]] && return 0
  else
    # ── argument position ───────────────────────────────────────────────────
    _clicue_mode=arg
    _clicue_cmd=${words[1]}
    if (( trailing )); then
      _clicue_pfx=''
    else
      _clicue_pfx=${words[-1]}
    fi
    # No recorded arguments for this command? Keep the card up as a "you are
    # here" panel rather than vanishing the moment a space is typed. Losing the
    # card on space was the single most jarring thing about the previous build.
    _clicue_info=0
    [[ -z ${CLICUE_ARGS[$_clicue_cmd]} ]] && _clicue_info=1
  fi

  # a changed buffer invalidates any selection the operator had made
  [[ $buf != $_clicue_lastbuf ]] && { _clicue_lastbuf=$buf; _clicue_reset_sel }

  _clicue_render "$_clicue_pfx" || return 0

  local card=$_clicue_text
  local -a specs=( $_clicue_spans )
  _clicue_visible=1

  # compose: append after whatever is already in POSTDISPLAY
  local -i base=$(( ${#BUFFER} + ${#POSTDISPLAY} ))
  POSTDISPLAY="${POSTDISPLAY}${card}"
  _clicue_card=$card

  local s a b style rest
  for s in $specs; do
    a=${s%% *}; rest=${s#* }
    b=${rest%% *}; style=${rest#* }
    region_highlight+=( "$(( base + a )) $(( base + b )) ${style},memo=clicue" )
  done
}

_clicue_line_finish() {
  _clicue_clear; _clicue_reset_sel
  _clicue_suppressed=0; _clicue_info=0
  _clicue_lastbuf=$'\0'
}

clicue-off() {
  add-zle-hook-widget -d line-pre-redraw _clicue_pre_redraw
  add-zle-hook-widget -d line-finish     _clicue_line_finish
  bindkey '^I' ${_clicue_orig_tab:-expand-or-complete}
  bindkey -r '^[[1;3B' '^[[1;3A' '^[^[[B' '^[^[[A' '^[[1;2B' '^[[1;2A' '^[' 2>/dev/null
  _clicue_clear
  print "clicue: unhooked (this shell only)"
}

# ── keys ─────────────────────────────────────────────────────────────────────
# Deliberately additive. Plain Up/Down keep doing whatever they already did
# (history-substring-search here) — they are load-bearing muscle memory and
# stealing them would be exactly the capture this project argues against.
# Scrolling the card lives on Shift+Arrow, which nothing binds by default.

_clicue_scroll_down() {
  (( _clicue_visible )) || return 0
  (( _clicue_sel < ${#_clicue_cands} )) && (( _clicue_sel++ ))
  _clicue_engaged=1
  zle -R
}

_clicue_scroll_up() {
  (( _clicue_visible )) || return 0
  (( _clicue_sel > 1 )) && (( _clicue_sel-- ))
  _clicue_engaged=1
  zle -R
}

# While the card is up it OWNS command-position completion: Tab accepts the
# highlighted cue. Falling through to compsys here produced a second, wider
# listing of the same candidates stacked under the card — the card looked like
# the completion UI without being one.
#
# Outside command position (arguments, paths, flags) the card is not shown and
# Tab delegates untouched, because clicue has no candidate-source adapter yet
# and compsys is authoritative there.
# ^C cannot be used here: the tty driver raises SIGINT before ZLE sees the
# character, and TRAPINT can observe it but not stop ZLE aborting the line
# (both verified). Esc is unbound in this config and is the conventional
# dismiss key for an overlay.
_clicue_dismiss() {
  if (( _clicue_visible )); then
    _clicue_suppressed=1
    _clicue_clear
    zle -R
    return 0
  fi
  return 0
}

_clicue_accept() {
  # an informational card has nothing to accept — hand Tab back to compsys
  if (( _clicue_visible && ! _clicue_info )) && (( ${#_clicue_cands} )); then
    local pick=${_clicue_cands[_clicue_sel]}
    if [[ -n $_clicue_pfx ]]; then
      LBUFFER="${LBUFFER%$_clicue_pfx}${pick} "   # replace just the partial word
    else
      LBUFFER="${LBUFFER}${pick} "
    fi
    _clicue_reset_sel
    _clicue_clear
    zle -R
    return 0
  fi
  zle ${_clicue_orig_tab:-expand-or-complete}
}

zle -N _clicue_scroll_down
zle -N _clicue_scroll_up
zle -N _clicue_accept
zle -N _clicue_dismiss

# remember what Tab did before we wrapped it, so we can delegate
_clicue_orig_tab=${${(z)$(bindkey '^I')}[2]:-expand-or-complete}
[[ $_clicue_orig_tab == _clicue_accept ]] && _clicue_orig_tab=expand-or-complete

# Alt+Arrow is the primary binding. Shift+Arrow was the obvious choice but
# konsole claims it for Scroll Line Up/Down at the terminal level, so those
# keystrokes never reach the shell. Alt+Arrow is unclaimed by both konsole and
# this config. Shift is kept bound anyway — harmless where it does arrive.
bindkey '^[[1;3B' _clicue_scroll_down   # Alt+Down  (CSI modifier 3)
bindkey '^[[1;3A' _clicue_scroll_up     # Alt+Up
bindkey '^[^[[B'  _clicue_scroll_down   # Alt+Down  (ESC-prefixed form)
bindkey '^[^[[A'  _clicue_scroll_up     # Alt+Up
bindkey '^[[1;2B' _clicue_scroll_down   # Shift+Down — eaten by konsole
bindkey '^[[1;2A' _clicue_scroll_up     # Shift+Up   — eaten by konsole
bindkey '^I'      _clicue_accept
bindkey '^['      _clicue_dismiss       # Esc — dismiss until the line is cleared

add-zle-hook-widget line-pre-redraw _clicue_pre_redraw
add-zle-hook-widget line-finish     _clicue_line_finish
