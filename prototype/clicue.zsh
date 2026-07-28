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

# ── gloss lookup ─────────────────────────────────────────────────────────────
_clicue_gloss() {
  local name=$1 kind=$2
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
  local -a reply            # scratch for _clicue_candidates
  _clicue_candidates $pfx
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

  local hint=' ⇧↑↓ scroll · Tab accept · ^C dismiss '
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

  # While zsh's own completion menu owns the display, complist drives redisplay
  # and our region_highlight spans never land — the card would render as
  # colourless text stacked above a duplicate listing. Stand down instead.
  [[ $KEYMAP == menuselect ]] && return 0

  local on=yes
  zstyle -s ':clicue:*' enabled on 2>/dev/null || on=yes
  [[ $on == (no|off|0) ]] && return 0

  local -i mininput=1
  zstyle -s ':clicue:*' min-input mininput 2>/dev/null || mininput=1

  # v1: command position only — bail once there's a word separator
  local buf=$LBUFFER
  [[ $buf == *[[:space:]]* ]] && return 0
  (( ${#buf} < mininput )) && return 0
  [[ $buf == [-./]* ]] && return 0

  # a changed buffer invalidates any selection the operator had made
  [[ $buf != $_clicue_lastbuf ]] && { _clicue_lastbuf=$buf; _clicue_reset_sel }

  _clicue_load

  _clicue_render "$buf" || return 0

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

_clicue_line_finish() { _clicue_clear; _clicue_reset_sel; _clicue_lastbuf=$'\0' }

clicue-off() {
  add-zle-hook-widget -d line-pre-redraw _clicue_pre_redraw
  add-zle-hook-widget -d line-finish     _clicue_line_finish
  bindkey '^I' ${_clicue_orig_tab:-expand-or-complete}
  bindkey -r '^[[1;2B' '^[[1;2A' 2>/dev/null
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

# Tab only hijacks once the operator has actually engaged with the card.
# Untouched Tab behaves exactly as it always did.
_clicue_accept() {
  if (( _clicue_visible && _clicue_engaged )) && (( ${#_clicue_cands} )); then
    LBUFFER="${_clicue_cands[_clicue_sel]} "
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

# remember what Tab did before we wrapped it, so we can delegate
_clicue_orig_tab=${${(z)$(bindkey '^I')}[2]:-expand-or-complete}
[[ $_clicue_orig_tab == _clicue_accept ]] && _clicue_orig_tab=expand-or-complete

bindkey '^[[1;2B' _clicue_scroll_down   # Shift+Down (xterm/CSI)
bindkey '^[[1;2A' _clicue_scroll_up     # Shift+Up
bindkey '^[[b'    _clicue_scroll_down   # some terminals
bindkey '^[[a'    _clicue_scroll_up
bindkey '^I'      _clicue_accept

add-zle-hook-widget line-pre-redraw _clicue_pre_redraw
add-zle-hook-widget line-finish     _clicue_line_finish
