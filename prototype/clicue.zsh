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
# Debugging:
#   CLICUE_DEBUG=/path/to/log zsh -i
# logs one block per line-pre-redraw: buffer, POSTDISPLAY length, our card
# length, and any early return. Written because a display bug turned out to be
# invisible in the state — the state was right on every keystroke while the
# screen was wrong on alternating ones.
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
typeset -g  _clicue_suppressed=0   # dismissed by the operator, this buffer only
typeset -g  _clicue_supbuf=''      # the buffer the dismissal applies to
typeset -g  _clicue_info=0         # card is informational, not a candidate list
typeset -g  _clicue_ghost=''       # stem of the highlighted cue, shown dim

# ── theme (Aura, from IRIS — see SPEC.md design language) ────────────────────
typeset -gA CLICUE_THEME=(
  border  '#a277ff'
  accent  '#61ffca'
  text    '#edecee'
  gloss   '#9692a8'
  selbg   '#3d375e'
  seltext '#ffffff'
  hint    '#6d6a7f'
  ghost   '#6d6a7f'
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

  # Ranked list: what this operator actually invokes first, then everything else
  # alphabetically. The tier boundary is a COUNT applied by the renderer (the
  # primary card holds a fixed number of cues), not a property of the data —
  # otherwise the primary card's size swings with how much history happens to
  # match, which is exactly the height instability POSTDISPLAY cannot tolerate.
  reply=( ${${(o)freqd}#*|} ${(o)rest} )
}

# ── argument candidates: what YOU have actually passed this command ──────────
# Sourced from history, already frequency-ranked at build time. No compsys and
# no forks — compsys would give the authoritative flag set with real
# descriptions, but needs the candidate-source adapter (component 3).
_clicue_arg_candidates() {
  local cmd=$1 pfx=$2
  local -a toks=( ${(s: :)CLICUE_ARGS[$cmd]} )
  local -a hist=() rest=()
  if [[ -n $pfx ]]; then
    hist=( ${(M)toks:#${pfx}*} )
  else
    hist=( $toks )
  fi
  # compsys results, if Tab has fetched them for this buffer — these carry the
  # authoritative descriptions and cover flags never yet used
  local -A seen=()
  local n
  for n in $hist; do seen[$n]=1; done
  for n in $_clicue_cs_words; do
    (( ${+seen[$n]} )) && continue
    [[ -n $pfx && $n != ${pfx}* ]] && continue
    seen[$n]=1; rest+=( $n )
  done
  typeset -g _clicue_arg_t1=${#hist}
  reply=( $hist ${(o)rest} )
  (( ${#reply} )) || return 1
  return 0
}

# ── candidate source adapter (SPEC component 3) ───────────────────────────────
# Drives zsh's own completion system for DATA and renders it ourselves.
#
# Unlike zsh-autosuggestions, compsys AGREES to be driven — every mechanism here
# is documented in zshcompwid(1):
#   zle -C <w> list-choices <fn>   create a completion widget (its stated purpose)
#   compstate[insert]=''           "the command line is not to be changed"
#   compstate[list]=''             draw nothing
#   compadd -O array               matches go to an array, not the match set
#   compadd -D array               prunes a parallel array in lockstep, which is
#                                  what keeps -d descriptions index-aligned
#
# compadd is shadowed only to APPEND those two options and hand everything else
# to the builtin. Note what this deliberately does NOT do: zsh-autocomplete
# rebuilt compadd by round-tripping its body through $functions[compadd] as text,
# which failed to re-parse on '#' comments and broke every completion. Appending
# options costs none of that fragility.
typeset -ga _clicue_cs_words=()
typeset -ga _clicue_cs_descs=()
typeset -gA _clicue_cs_gloss=()
typeset -g  _clicue_cs_for=$'\0'      # buffer the last harvest was for

_clicue_capture_fn() {
  compstate[insert]=''
  compstate[list]=''
  _clicue_cs_words=(); _clicue_cs_descs=()

  compadd() {
    local -a w dsp
    local -i i
    # find the -d array (given by name or as a literal list) so it can be pruned
    # alongside the words and stay aligned
    for (( i = 1; i <= $#; i++ )); do
      if [[ ${@[i]} == -d ]]; then
        local dv=${@[i+1]}
        if [[ -n ${(P)dv+x} ]]; then dsp=( ${(P)dv} ); else dsp=( ${=dv} ); fi
        break
      fi
    done
    builtin compadd -O w -D dsp "$@" 2>/dev/null
    (( ${#w} )) || return 1
    _clicue_cs_words+=( $w )
    if (( ${#dsp} == ${#w} )); then
      _clicue_cs_descs+=( $dsp )
    else
      _clicue_cs_descs+=( ${(s: :)${(l:${#w}::@:):-}} )   # placeholders
    fi
    return 0
  }

  _main_complete
  unfunction compadd 2>/dev/null
  return 0
}

zle -C _clicue_capture list-choices _clicue_capture_fn

# ── gloss lookup ─────────────────────────────────────────────────────────────
_clicue_gloss() {
  local name=$1 kind=$2
  if [[ $_clicue_mode == arg ]]; then
    if (( _clicue_info )); then
      _clicue_g=${CLICUE_GLOSS[$name]:-'no recorded arguments'}
      return
    fi
    # compsys's own description when we have it (Tab fetches these), else the
    # usage count as an honest fallback
    if [[ -n ${_clicue_cs_gloss[$name]} ]]; then
      _clicue_g=${_clicue_cs_gloss[$name]}
      return
    fi
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
# Two groups, one selection. Tier 1 (nearest the prompt) is what this operator
# actually invokes — it has history frequency. Tier 2 is everything else on the
# system. Alt+Down flows out of the bottom of tier 1 straight into tier 2, so
# there is no mode to switch and no second keybinding to learn.
typeset -ga _clicue_lines=()
typeset -ga _clicue_gridrows=()    # indices into _clicue_lines that are grid rows
typeset -g  _clicue_selline=0      # line index holding the selected grid cell
typeset -g  _clicue_selcol=0       # char offset of that cell within the line
typeset -g  _clicue_selw=0         # its width
typeset -g  _clicue_top1=1
typeset -g  _clicue_top2=0
typeset -g  _clicue_focus=1        # 1 = tier 1 list, 2 = tier 2 grid (a MODE)
typeset -g  _clicue_gridtop=0      # first index shown in the grid page
typeset -g  _clicue_grid_rows=1    # rows in the current grid, for 2D nav
typeset -g  _clicue_grid_cols=1

# $1 lo  $2 hi  $3 window-top  $4 label  $5 maxrows  $6 namew  $7 glossw  $8 inner
_clicue_emit_box() {
  local -i lo=$1 hi=$2 top=$3 maxrows=$5 namew=$6 glossw=$7 inner=$8
  local label=$4
  (( top < lo )) && top=$lo
  local -i bot=$(( top + maxrows - 1 ))
  (( bot > hi )) && bot=$hi
  (( top > bot )) && return 1

  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  _clicue_lines+=( "╭${label}${(l:$rule::─:):-}╮" )

  local -i emitted=0
  local -i i
  local ent name kind g nmcol gcol marker
  for (( i = top; i <= bot; i++ )); do
    (( emitted++ ))
    ent=${_clicue_cands[i]}
    name=$ent
    kind=${_clicue_kind[$ent]:-system}
    [[ $_clicue_mode == arg ]] && kind=arg
    _clicue_gloss $name $kind; g=$_clicue_g
    marker='  '
    (( i == _clicue_sel )) && marker=' ▸'
    nmcol=${(r:$namew:)${name[1,$namew]}}
    (( ${#g} > glossw )) && g="${g[1,$(( glossw - 1 ))]}…"
    gcol=${(r:$glossw:)g}
    _clicue_lines+=( "│${marker} ${nmcol}  ${gcol}│" )
  done
  # Deliberately NOT padded to the allocation. The card shows as many cues as
  # exist and no blank filler. This makes the card's height vary with the
  # candidate count, which re-tests an earlier inference (that ZLE paints a
  # taller POSTDISPLAY over a shorter one rather than reflowing) — that was
  # never isolated, only worked around. If display mangling returns while
  # typing, the inference was right and padding must come back.
  return 0
}

# Tier 2 as a column grid (column-major, like zsh's own listing) plus a
# one-line gloss bar for whatever is highlighted. Hundreds of candidates in a
# single scrolling column is poor UX; a grid shows an order of magnitude more at
# a glance and the gloss bar keeps the description without stealing a column.
#   $1 lo  $2 hi  $3 maxrows  $4 inner
_clicue_emit_grid() {
  local -i lo=$1 hi=$2 maxrows=$3 inner=$4
  local -i n=$(( hi - lo + 1 ))
  (( n > 0 )) || return 1

  local -i i w=0
  for (( i = lo; i <= hi; i++ )); do
    (( ${#_clicue_cands[i]} > w )) && w=${#_clicue_cands[i]}
  done
  (( w > 28 )) && w=28
  local -i colw=$(( w + 2 ))
  # tier 1 rows put names 3 columns in (│ + 2-char marker + space); match it so
  # the grid's first column lines up with the primary card's names
  local -i gutter=3
  local -i avail=$(( inner - gutter ))
  (( avail < colw )) && avail=$colw
  local -i ncols=$(( avail / colw ))
  (( ncols < 1 )) && ncols=1
  # LAYOUT rows come from the content (so few items spread across columns rather
  # than stacking in one); the box is then PADDED to the full allocation so the
  # card's total height stays invariant. Two different numbers.
  local -i rows=$(( (n + ncols - 1) / ncols ))
  (( rows > maxrows )) && rows=$maxrows
  (( rows < 1 )) && rows=1
  local -i page=$(( rows * ncols ))

  # keep the selection on the visible page
  (( _clicue_gridtop < lo )) && _clicue_gridtop=$lo
  if (( _clicue_sel >= lo && _clicue_sel <= hi )); then
    while (( _clicue_sel >= _clicue_gridtop + page )); do (( _clicue_gridtop += page )); done
    while (( _clicue_sel < _clicue_gridtop )); do (( _clicue_gridtop -= page )); done
    (( _clicue_gridtop < lo )) && _clicue_gridtop=$lo
  fi
  _clicue_grid_rows=$rows
  _clicue_grid_cols=$ncols

  local -i shown=$(( hi - _clicue_gridtop + 1 ))
  (( shown > page )) && shown=$page
  local label=" all ${n} on system "
  (( _clicue_focus == 2 )) && label=" browsing ${n} — $(( _clicue_sel - lo + 1 ))/${n} "
  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  _clicue_lines+=( "╭${label}${(l:$rule::─:):-}╮" )

  local -i r c idx off
  local row nm cell
  for (( r = 0; r < rows; r++ )); do
    row=''
    off=0
    for (( c = 0; c < ncols; c++ )); do
      idx=$(( _clicue_gridtop + c * rows + r ))
      if (( idx > hi )) || (( idx - _clicue_gridtop >= page )); then
        row+=${(r:$colw:)}
        continue
      fi
      nm=${_clicue_cands[idx]}
      cell=${(r:$colw:)${nm[1,$w]}}
      if (( idx == _clicue_sel )); then
        cell="▸${${(r:$(( colw - 1 )):)${nm[1,$w]}}}"
        # remember exactly where this cell lands so only IT gets the selection
        # highlight — colouring the whole row would imply the row is the unit
        _clicue_selline=$(( ${#_clicue_lines} + 1 ))
        _clicue_selcol=$(( 1 + gutter + off ))
        _clicue_selw=$colw
      fi
      row+=$cell
      (( off += colw ))
    done
    _clicue_lines+=( "│${(r:$gutter:)}${${(r:$avail:)row}}│" )
    _clicue_gridrows+=( ${#_clicue_lines} )
  done
  # not padded either — see the note in _clicue_emit_box
  return 0
}

_clicue_render() {
  local pfx=$1
  local -a cands
  local -a reply
  typeset -g _clicue_tier1_n=0

  if [[ $_clicue_mode == arg ]] && (( _clicue_info )); then
    reply=( $_clicue_cmd ); _clicue_tier1_n=1
  elif [[ $_clicue_mode == arg ]]; then
    if ! _clicue_arg_candidates $_clicue_cmd "$pfx"; then
      [[ -n $pfx ]] && return 1
      _clicue_info=1; reply=( $_clicue_cmd )
    fi
    # history-derived args are tier 1; compsys-derived fill the grid
    _clicue_tier1_n=${_clicue_arg_t1:-${#reply}}
  else
    _clicue_candidates $pfx
  fi
  cands=( $reply )
  (( ${#cands} )) || return 1
  _clicue_cands=( $cands )

  # ── height budget ──────────────────────────────────────────────────────────
  # The card is a FIXED number of lines, always. ZLE paints a taller POSTDISPLAY
  # over a shorter one rather than reflowing, so any variation as the operator
  # types mangles the display. Both boxes divide one budget and pad into it.
  #
  # both tiers:  1 border + r1 + 1 border + r2 + hint + gloss + close = r1+r2+5
  # tier 1 only: 1 border + r1 + hint + gloss + close                 = r1+4
  local -i maxlines=14
  zstyle -s ':clicue:*' max-lines maxlines 2>/dev/null || maxlines=14
  (( maxlines < 8 )) && maxlines=8
  local -i total=${#cands}
  # primary card holds a fixed number of cues; the overflow becomes the grid
  local -i t1rows=10
  zstyle -s ':clicue:*' tier1-rows t1rows 2>/dev/null || t1rows=10
  (( t1rows < 1 )) && t1rows=1
  # The grid expands to whatever the terminal can spare — a fixed row count
  # wasted most of a tall window. Overhead: 3 borders + hint + gloss + the
  # prompt's own lines, kept generous so the card never pushes the prompt off.
  local t2cfg=auto
  zstyle -s ':clicue:*' tier2-rows t2cfg 2>/dev/null || t2cfg=auto
  local -i t2rows
  if [[ $t2cfg == auto ]]; then
    t2rows=$(( ${LINES:-24} - t1rows - 10 ))
  else
    t2rows=$t2cfg
  fi
  (( t2rows < 2 )) && t2rows=2

  local -i t1n=$t1rows
  (( t1n > total )) && t1n=$total
  typeset -g _clicue_t1n=$t1n
  # Focus follows the selection rather than a toggle: scroll past the end of
  # tier 1 and you are in the grid. Nothing to enter, nothing to remember.
  if (( _clicue_sel > t1n )); then _clicue_focus=2; else _clicue_focus=1; fi

  local -i width=${COLUMNS:-80}
  (( width > 120 )) && width=120
  (( width < 40 ))  && width=40
  local -i inner=$(( width - 2 ))

  # Total = 1 + r1 + 1 + r2 + hint + gloss + close. With no overflow the grid
  # box vanishes and tier 1 absorbs its border AND its rows, so the line count
  # is identical either way.
  local -i r1 r2
  if (( total > t1n )); then
    r1=$t1rows; r2=$t2rows
  else
    r1=$(( t1rows + t2rows + 1 )); r2=0
  fi

  # clamp selection across the whole list, then slide whichever window holds it
  (( _clicue_sel < 1 )) && _clicue_sel=1
  (( _clicue_sel > total )) && _clicue_sel=$total
  if (( _clicue_sel <= t1n )); then
    (( _clicue_sel < _clicue_top1 )) && _clicue_top1=$_clicue_sel
    (( _clicue_sel > _clicue_top1 + r1 - 1 )) && _clicue_top1=$(( _clicue_sel - r1 + 1 ))
    (( _clicue_top1 < 1 )) && _clicue_top1=1
  else
    (( _clicue_top2 < t1n + 1 )) && _clicue_top2=$(( t1n + 1 ))
    (( _clicue_sel < _clicue_top2 )) && _clicue_top2=$_clicue_sel
    (( _clicue_sel > _clicue_top2 + r2 - 1 )) && _clicue_top2=$(( _clicue_sel - r2 + 1 ))
  fi

  # name column sized over both visible windows
  local -i namew=0 i
  local -a vis=()
  (( t1n > 0 )) && for (( i = _clicue_top1; i <= t1n && i < _clicue_top1 + r1; i++ )) vis+=( ${cands[i]} )
  if (( total > t1n )); then
    local -i t2=$_clicue_top2
    (( t2 < t1n + 1 )) && t2=$(( t1n + 1 ))
    for (( i = t2; i <= total && i < t2 + r2; i++ )) vis+=( ${cands[i]} )
  fi
  for i in {1..${#vis}}; do (( ${#vis[i]} > namew )) && namew=${#vis[i]}; done
  (( namew > 28 )) && namew=28
  (( namew < 10 )) && namew=10
  local -i glossw=$(( inner - namew - 5 ))
  (( glossw < 10 )) && glossw=10

  _clicue_lines=()
  _clicue_gridrows=(); _clicue_selline=0
  local hint=${_clicue_hint:-' Tab accept · Esc dismiss '}
  (( _clicue_info )) && { local REPLY; local -a dv
    zstyle -a ':clicue:keys' dismiss dv || dv=( '^[' )
    _clicue_keylabel ${dv[1]}; hint=" ${REPLY} dismiss " }

  # tier 1 first — nearest the prompt
  if (( t1n > 0 )); then
    _clicue_emit_box 1 $t1n $_clicue_top1 " ${_clicue_sel}/${total} " \
                     $r1 $namew $glossw $inner
  fi
  if (( total > t1n )); then
    _clicue_emit_grid $(( t1n + 1 )) $total $r2 $inner
  fi

  local -i brule=$(( inner - ${#hint} ))
  (( brule < 1 )) && brule=1
  _clicue_lines+=( "╰${(l:$brule::─:):-}${hint}╯" )

  # Gloss bar: the highlighted cue's description on its own line, so the grid
  # can stay dense without dropping descriptions.
  #
  # Rendered UNCONDITIONALLY, even when the selection sits in tier 1 and the
  # description is already visible there. It was previously gated on the
  # selection being in the grid, which meant Alt+Down grew the card by two lines
  # mid-redraw — and ZLE mishandles a POSTDISPLAY that changes height, drawing
  # the taller card over the shorter one instead of below it. Constant height is
  # the fix.
  if (( ${#_clicue_cands} )); then
    local gname=${_clicue_cands[_clicue_sel]}
    local gkind=${_clicue_kind[$gname]:-system}
    [[ $_clicue_mode == arg ]] && gkind=arg
    _clicue_gloss $gname $gkind
    local -i gw=$(( inner - namew - 5 ))
    (( gw < 10 )) && gw=10
    local gg=$_clicue_g
    (( ${#gg} > gw )) && gg="${gg[1,$(( gw - 1 ))]}…"
    _clicue_lines+=( "│   ${(r:$namew:)${gname[1,$namew]}}  ${(r:$gw:)gg}│" )
    _clicue_lines+=( "╰${(l:$inner::─:):-}╯" )
  fi

  _clicue_text=$'\n'${(F)_clicue_lines}

  # highlight spans over the assembled card
  local -a specs=()
  local -i pos=1 len i=0
  local ln
  local -A isgrid=()
  for i in ${_clicue_gridrows}; do isgrid[$i]=1; done
  i=0
  for ln in $_clicue_lines; do
    (( i++ ))
    len=${#ln}
    if [[ $ln == ('╭'|'╰')* ]]; then
      specs+=( "$pos $(( pos + len )) fg=${CLICUE_THEME[border]}" )
    elif (( ${+isgrid[$i]} )); then
      # A grid row is N cells of the SAME kind — every column is a command name.
      # Applying the list layout's name/gloss spans here was tinting columns 2+
      # with the description colour, as though they were descriptions.
      specs+=( "$pos $(( pos + 1 )) fg=${CLICUE_THEME[border]}" )
      specs+=( "$(( pos + len - 1 )) $(( pos + len )) fg=${CLICUE_THEME[border]}" )
      specs+=( "$(( pos + 1 )) $(( pos + len - 1 )) fg=${CLICUE_THEME[accent]}" )
      if (( _clicue_selline == i )); then
        specs+=( "$(( pos + _clicue_selcol )) $(( pos + _clicue_selcol + _clicue_selw )) fg=${CLICUE_THEME[seltext]},bg=${CLICUE_THEME[selbg]},bold" )
      fi
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
  _clicue_sel=1; _clicue_top1=1; _clicue_top2=0; _clicue_engaged=0
  _clicue_focus=1; _clicue_gridtop=0
}

# Strip only the CARD, deliberately leaving our ghost stem in place. The yield
# wrappers use this: zsh-autosuggestions then accepts whatever precedes the
# card, which is our stem — so Right Arrow accepts the highlighted cue.
_clicue_clear_card() {
  _clicue_visible=0
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  if [[ -n $_clicue_card && $POSTDISPLAY == *"$_clicue_card" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_clicue_card"}
  fi
  _clicue_card=''
}

# Strip card AND ghost — used before re-rendering, so stems do not accumulate.
_clicue_clear() {
  _clicue_clear_card
  if [[ -n $_clicue_ghost && $POSTDISPLAY == *"$_clicue_ghost" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_clicue_ghost"}
  fi
  _clicue_ghost=''
}

_clicue_pre_redraw() {
  [[ -n $CLICUE_DEBUG ]] && print -r -- "ENTER buf=[$LBUFFER] pd=${#POSTDISPLAY} card=${#_clicue_card} ghost=[$_clicue_ghost] sup=$_clicue_suppressed vis=$_clicue_visible" >> $CLICUE_DEBUG
  _clicue_clear
  [[ -n $CLICUE_DEBUG ]] && print -r -- "  AFTERCLEAR pd=${#POSTDISPLAY}" >> $CLICUE_DEBUG

  # Dismissed by Esc — but ONLY until the buffer next changes.
  #
  # This used to persist until the line was emptied, which meant one Esc press
  # silently disabled the tool for the rest of the line with no indicator. That is
  # indistinguishable from a malfunction, and it was in fact reported as one.
  #
  # A fallback that silently changes behaviour is worse than no fallback: the
  # operator cannot tell working from broken, so confidence in the whole UI drops.
  # Esc now hides the card for the current buffer only; typing brings it straight
  # back. Predictable, and no invisible state to be surprised by.
  if (( _clicue_suppressed )); then
    if [[ $LBUFFER == $_clicue_supbuf ]]; then
      [[ -n $CLICUE_DEBUG ]] && print -r -- "  BAIL dismissed (this buffer only)" >> $CLICUE_DEBUG
      return 0
    fi
    _clicue_suppressed=0
  fi

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
    # Unambiguously filesystem — compsys owns this, stand down entirely so its
    # coloured path picker works untouched.
    [[ ${words[-1]} == */* || ${words[-1]} == '~'* ]] && return 0
    if (( trailing )); then
      _clicue_pfx=''
    else
      _clicue_pfx=${words[-1]}
    fi
    # No recorded arguments for this command? Keep the card up as a "you are
    # here" panel rather than vanishing the moment a space is typed. Losing the
    # card on space was the single most jarring thing about the previous build.
    _clicue_info=0
    if [[ -z ${CLICUE_ARGS[$_clicue_cmd]} ]]; then
      # Mid-word with nothing to offer: get out of the way entirely so compsys
      # can do path/file completion. An informational card here would swallow
      # Tab and block `cd proj<Tab>`.
      [[ -n $_clicue_pfx ]] && return 0
      _clicue_info=1
    fi
  fi

  # a changed buffer invalidates any selection the operator had made
  [[ $buf != $_clicue_lastbuf ]] && { _clicue_lastbuf=$buf; _clicue_reset_sel }
  # a different command means the harvest no longer applies
  [[ $_clicue_mode == cmd ]] && { _clicue_cs_words=(); _clicue_cs_gloss=(); _clicue_cs_for=$'\0' }

  if ! _clicue_render "$_clicue_pfx"; then
    [[ -n $CLICUE_DEBUG ]] && print -r -- "  BAIL render-failed mode=$_clicue_mode pfx=[$_clicue_pfx] info=$_clicue_info" >> $CLICUE_DEBUG
    return 0
  fi

  local card=$_clicue_text
  local -a specs=( $_clicue_spans )
  _clicue_visible=1

  # Once the operator scrolls the card, the highlighted cue owns the ghost text:
  # the typed prefix stays real, the STEM renders dim — the same convention
  # zsh-autosuggestions uses, so the command line updates live from the card.
  # Shown unprompted, not only after Tab: clicue is now the ONLY ghost-text
  # engine. zsh-autosuggestions was writing the same string for the same purpose,
  # and whichever landed last won — visible as the ghost turning grey and the
  # card's rendering breaking.
  local ghost=''
  if (( ${#_clicue_cands} )) && (( ! _clicue_info )); then
    local pick=${_clicue_cands[_clicue_sel]}
    if [[ -n $_clicue_pfx && $pick == ${_clicue_pfx}* ]]; then
      ghost=${pick#$_clicue_pfx}
    elif [[ -z $_clicue_pfx ]]; then
      ghost=$pick
    fi
    (( ${#ghost} )) && POSTDISPLAY=''   # our cue supersedes the autosuggestion
  fi

  local -i gbase=$(( ${#BUFFER} + ${#POSTDISPLAY} ))
  local -i base=$(( gbase + ${#ghost} ))
  POSTDISPLAY="${POSTDISPLAY}${ghost}${card}"
  _clicue_ghost=$ghost
  _clicue_card=$card

  (( ${#ghost} )) && region_highlight+=(
    "$gbase $(( gbase + ${#ghost} )) fg=${CLICUE_THEME[ghost]},memo=clicue" )
  [[ -n $CLICUE_DEBUG ]] && print -r -- "  DREW card=${#card} pd=${#POSTDISPLAY} lines=${#_clicue_lines}" >> $CLICUE_DEBUG

  local s a b style rest
  for s in $specs; do
    a=${s%% *}; rest=${s#* }
    b=${rest%% *}; style=${rest#* }
    region_highlight+=( "$(( base + a )) $(( base + b )) ${style},memo=clicue" )
  done
}

_clicue_line_finish() {
  _clicue_clear; _clicue_reset_sel; _clicue_ghost=''
  _clicue_suppressed=0; _clicue_info=0
  _clicue_lastbuf=$'\0'
}

clicue-off() {
  add-zle-hook-widget -d line-pre-redraw _clicue_pre_redraw
  add-zle-hook-widget -d line-finish     _clicue_line_finish
  bindkey '^I' ${_clicue_orig_tab:-expand-or-complete}
  (( ${#_clicue_bound} )) && bindkey -r ${_clicue_bound[@]} 2>/dev/null
  _clicue_clear
  print "clicue: unhooked (this shell only)"
}

# ── keys ─────────────────────────────────────────────────────────────────────
# Every binding is configuration. Set these BEFORE sourcing this file:
#
#   zstyle ':clicue:keys' scroll-down '^[[1;2B' '^[[1;3B'
#   zstyle ':clicue:keys' scroll-up   '^[[1;2A' '^[[1;3A'
#   zstyle ':clicue:keys' accept      '^I'
#   zstyle ':clicue:keys' dismiss     '^['
#   zstyle ':clicue:keys' scroll-label 'Shift+↑↓'   # optional; auto-derived
#
# Multiple sequences per action are fine — terminals disagree. Discover what a
# key actually sends with `cat -v`, then press it.
#
# Plain Up/Down are deliberately never bound. They are load-bearing muscle
# memory (history-substring-search here) and taking them would be exactly the
# capture this project argues against.

typeset -ga _clicue_bound=()

# human-readable label for a key sequence, for the hint line
_clicue_keylabel() {
  case $1 in
    '^[[1;2A'|'^[[1;2B') REPLY='Shift' ;;
    '^[[1;3A'|'^[[1;3B'|'^[^[[A'|'^[^[[B') REPLY='Alt' ;;
    '^[[1;5A'|'^[[1;5B') REPLY='Ctrl' ;;
    '^I') REPLY='Tab' ;;
    '^[') REPLY='Esc' ;;
    '^G') REPLY='^G' ;;
    *)    REPLY=$1 ;;
  esac
}

_clicue_bindall() {
  local -a seqs
  local k action widget

  for action widget in \
      scroll-down _clicue_scroll_down \
      scroll-up   _clicue_scroll_up \
      accept      _clicue_accept \
      dismiss     _clicue_dismiss
  do
    seqs=()
    zstyle -a ':clicue:keys' $action seqs
    if (( ! ${#seqs} )); then
      case $action in
        # Shift is listed first and is the preferred ergonomics, but konsole
        # claims Shift+Up/Down for Scroll Line Up/Down at the terminal level,
        # so those keystrokes never reach the shell until that shortcut is
        # cleared in Settings -> Configure Keyboard Shortcuts. Alt is bound
        # alongside it so the card is usable either way.
        scroll-down) seqs=( '^[[1;2B' '^[[1;3B' '^[^[[B' ) ;;
        scroll-up)   seqs=( '^[[1;2A' '^[[1;3A' '^[^[[A' ) ;;
        accept)      seqs=( '^I' ) ;;
        dismiss)     seqs=( '^[' ) ;;
      esac
    fi
    for k in $seqs; do
      # INVARIANT: clicue never binds an unmodified arrow. Up/Down always move
      # through command history — that is the operator's muscle memory and it
      # predates this tool. Enforced here rather than merely intended, because
      # a stray config line is all it would take to break it silently.
      case $k in
        '^[[A'|'^[[B'|'^[OA'|'^[OB'|$'\e[A'|$'\e[B')
          print -u2 "clicue: refusing to bind ${k} — plain arrows belong to history"
          continue ;;
        [[:print:]])
          # A bare printable character is literally what the operator types.
          # Binding 'q' as an alternate dismiss would break every command
          # containing a q. Never do this, however convenient it looks.
          print -u2 "clicue: refusing to bind '${k}' — bare printable characters are typing"
          continue ;;
      esac
      bindkey $k $widget
      _clicue_bound+=( $k )
    done
  done
}

# Build the hint line once, from what is actually bound. Bindings vary by
# terminal, so advertising the real ones is load-bearing rather than decorative.
_clicue_build_hint() {
  local REPLY lbl
  local -a av dv
  zstyle -a ':clicue:keys' accept  av || av=( '^I' )
  zstyle -a ':clicue:keys' dismiss dv || dv=( '^[' )
  _clicue_keylabel ${av[1]}; local cyc=$REPLY
  _clicue_keylabel ${dv[1]}; local dis=$REPLY
  typeset -g _clicue_hint=" ${cyc} cycle · ↑↓ browse · → accept · ⏎ insert · ${dis} dismiss "
}

# ── movement primitive ───────────────────────────────────────────────────────
# Tier 1 and the grid are ONE selection, so walking off the end of tier 1 simply
# lands in the grid. Returns non-zero when the card is not being navigated, which
# is how every arrow delegates to whatever owned it.
_clicue_move() {
  (( _clicue_visible && _clicue_engaged )) || return 1
  (( ${#_clicue_cands} )) || return 1
  (( _clicue_sel += $1 ))
  (( _clicue_sel < 1 )) && _clicue_sel=1
  (( _clicue_sel > ${#_clicue_cands} )) && _clicue_sel=${#_clicue_cands}
  zle -R
  return 0
}

_clicue_scroll_down() { _clicue_move 1;  return 0 }
_clicue_scroll_up()   { _clicue_move -1; return 0 }

# ^C cannot be used for dismiss: the tty driver raises SIGINT before ZLE sees the
# character, and TRAPINT can observe it but not stop ZLE aborting the line.
_clicue_dismiss() {
  if (( _clicue_visible )); then
    _clicue_suppressed=1
    _clicue_supbuf=$LBUFFER
    _clicue_clear
    zle -R
  fi
  return 0
}

# Tab CYCLES within the primary card. That card is history-ranked, so the cue the
# operator wants is usually one or two presses away — the ordering is learned
# rather than deterministic, and stabilises statistically as history accumulates.
# Nothing is inserted; the proposal shows as ghost text.
_clicue_accept() {
  # In argument position, Tab is where the expensive engine earns its keep:
  # compsys forks (git branch, docker ps) so it cannot run per keystroke, but on
  # demand it yields the authoritative flag/subcommand set WITH real descriptions.
  # Cached per buffer so repeated Tab presses do not re-fork.
  if [[ $_clicue_mode == arg && $_clicue_cs_for != $LBUFFER ]]; then
    _clicue_cs_for=$LBUFFER
    zle _clicue_capture 2>/dev/null
    _clicue_cs_gloss=()
    local -i i
    for (( i = 1; i <= ${#_clicue_cs_words}; i++ )); do
      [[ ${_clicue_cs_descs[i]} == '@' ]] && continue
      _clicue_cs_gloss[${_clicue_cs_words[i]}]=${_clicue_cs_descs[i]}
    done
    [[ -n $CLICUE_DEBUG ]] && print -r -- "  COMPSYS n=${#_clicue_cs_words} first=[${_clicue_cs_words[1]}] desc=[${_clicue_cs_descs[1]}]" >> $CLICUE_DEBUG
    _clicue_reset_sel
    zle -R
    return 0
  fi
  if (( _clicue_visible && ! _clicue_info )) && (( ${#_clicue_cands} )); then
    _clicue_engaged=1
    local -i lim=${_clicue_t1n:-0}
    (( lim < 1 || lim > ${#_clicue_cands} )) && lim=${#_clicue_cands}
    (( _clicue_sel++ ))
    (( _clicue_sel > lim )) && _clicue_sel=1
    zle -R
    return 0
  fi
  zle ${_clicue_orig_tab:-expand-or-complete}
}

# Enter, while navigating a card, means "put this on the command line" — NOT
# "run it". Choosing from a card is composition, not execution; the operator
# still decides when to run. Untouched (not navigating), Enter delegates and
# behaves exactly as it always did.
_clicue_insert() {
  if (( _clicue_visible && _clicue_engaged && ! _clicue_info )) && (( ${#_clicue_cands} )); then
    local pick=${_clicue_cands[_clicue_sel]}
    if [[ -n $_clicue_pfx ]]; then
      LBUFFER="${LBUFFER%$_clicue_pfx}${pick} "
    else
      LBUFFER="${LBUFFER}${pick} "
    fi
    _clicue_reset_sel
    _clicue_clear
    zle -R
    return 0
  fi
  zle ${_clicue_orig_enter:-.accept-line}
}

zle -N _clicue_insert
zle -N _clicue_scroll_down
zle -N _clicue_scroll_up
zle -N _clicue_accept
zle -N _clicue_dismiss

_clicue_orig_tab=${${(z)$(bindkey '^I')}[2]:-expand-or-complete}
[[ $_clicue_orig_tab == _clicue_accept ]] && _clicue_orig_tab=expand-or-complete

# konsole consumes Shift+Arrow (Scroll Line Up/Down) before any hosted process
# sees it, so the hint must not advertise a key that cannot arrive. Detect via
# the env marker konsole exports — cheaper and far more reliable than walking
# the process tree. Override with CLICUE_TERM_EATS_SHIFT=0 after clearing the
# shortcut in Settings -> Configure Keyboard Shortcuts.
if [[ -z $CLICUE_TERM_EATS_SHIFT ]]; then
  if [[ -n $KONSOLE_DBUS_SESSION ]]; then
    typeset -g CLICUE_TERM_EATS_SHIFT=1
  else
    typeset -g CLICUE_TERM_EATS_SHIFT=0
  fi
fi

_clicue_bindall
_clicue_build_hint

# ── POSTDISPLAY is single-tenant; yield it before anyone reads it ────────────
# zsh-autosuggestions does, literally:      BUFFER="$BUFFER$POSTDISPLAY"
# It assumes the whole of POSTDISPLAY is its suggestion. With our card appended
# there, pressing Right Arrow shovelled the entire multi-line card into the
# command buffer.
#
# Unlike ZLE hooks (add-zle-hook-widget) and highlights (memo=), POSTDISPLAY has
# no multi-tenancy protocol at all — it is a bare string with no ownership
# convention. So we cooperate manually: wrap every widget known to consume it,
# strip OUR card first (leaving the other tenant's content untouched), then
# delegate to whatever was there before.
typeset -ga _clicue_yield_widgets=(
  forward-char end-of-line vi-forward-char vi-end-of-line vi-add-eol
  forward-word emacs-forward-word vi-forward-word vi-forward-word-end
  vi-forward-blank-word vi-forward-blank-word-end
)

# ── grid browse: arrows navigate tier 2 ──────────────────────────────────────
# While the selection is inside the grid, arrows move within it. That is a MODE
# in the same sense as zsh's own menuselect — entered deliberately by scrolling
# past tier 1 — which is why it may take the arrows without violating the
# plain-arrow invariant. Outside the grid every arrow delegates untouched.
_clicue_grid_move() {
  _clicue_in_grid || return 1
  local dir=$1
  local -i r=${_clicue_grid_rows:-1}
  case $dir in
    down)  (( _clicue_sel++ )) ;;
    up)    (( _clicue_sel-- )) ;;
    right) (( _clicue_sel += r )) ;;
    left)  (( _clicue_sel -= r )) ;;
  esac
  (( _clicue_sel < _clicue_t1n + 1 )) && _clicue_sel=$(( _clicue_t1n + 1 ))
  (( _clicue_sel > ${#_clicue_cands} )) && _clicue_sel=${#_clicue_cands}
  zle -R
  return 0
}

_clicue_in_grid() {
  (( _clicue_visible && _clicue_engaged )) || return 1
  (( _clicue_focus == 2 )) || return 1
  return 0
}

# Up/Down walk the whole selection — tier 1 then straight on into the grid.
# Left/Right jump a grid column and are meaningful ONLY in the grid, so Right
# keeps working as autosuggestions' accept everywhere else.
# Each delegates to whatever owned the key when the card is not being navigated.
# Accept the proposal. Previously this rode on zsh-autosuggestions' widgets;
# clicue owns the ghost now, so it owns the accept gesture too. Same keys as
# before — Right Arrow at end of line, and End — so nothing is relearned.
_clicue_accept_ghost() {
  (( _clicue_visible )) || return 1
  [[ -n $_clicue_ghost ]] || return 1
  (( CURSOR == ${#BUFFER} )) || return 1
  LBUFFER="${LBUFFER}${_clicue_ghost}"
  _clicue_reset_sel
  _clicue_clear
  zle -R
  return 0
}

_clicue_end_of_line() { _clicue_accept_ghost || zle ${_clicue_orig_eol:-.end-of-line} }
zle -N _clicue_end_of_line

_clicue_arrow_down()  { _clicue_move  1     || zle ${_clicue_arrow_orig[B]:-.down-line-or-history} }
_clicue_arrow_up()    { _clicue_move -1     || zle ${_clicue_arrow_orig[A]:-.up-line-or-history} }
_clicue_arrow_right() {
  _clicue_grid_move right && return          # inside the grid: jump a column
  _clicue_accept_ghost    && return          # at end of line: take the proposal
  zle ${_clicue_arrow_orig[C]:-.forward-char}
}
_clicue_arrow_left()  { _clicue_grid_move left  || zle ${_clicue_arrow_orig[D]:-.backward-char} }

zle -N _clicue_arrow_down
zle -N _clicue_arrow_up
zle -N _clicue_arrow_right
zle -N _clicue_arrow_left

typeset -gA _clicue_arrow_orig=()

# zsh-autosuggestions computes suggestions ASYNCHRONOUSLY by default — it sets
# ZSH_AUTOSUGGEST_USE_ASYNC to the empty string and then tests only for the
# parameter's EXISTENCE, so async is on even though the value looks falsy.
#
# The result arrives through a `zle -F` fd handler at an arbitrary moment, often
# AFTER our line-pre-redraw has already appended the card, and writing
# POSTDISPLAY there destroys it. Whether the card survived depended on which
# landed last — which is exactly why it vanished on roughly alternate keystrokes.
#
# Forcing synchronous mode would fix it by putting a history search on every
# keystroke. Cheaper to re-append after the async writer runs.
_clicue_wrap_async() {
  (( ${+functions[_zsh_autosuggest_async_response]} )) || return 0
  (( ${+functions[_clicue_async_orig]} )) && return 0
  functions[_clicue_async_orig]=$functions[_zsh_autosuggest_async_response]
  _zsh_autosuggest_async_response() {
    _clicue_async_orig "$@"
    _clicue_pre_redraw
  }
  return 0
}

_clicue_install_arrows() {
  local -A want=( A up B down C right D left )
  local k w
  for k in A B C D; do
    w=${${(z)$(bindkey "^[[$k")}[2]}
    [[ -z $w || $w == _clicue_arrow_* ]] && continue
    _clicue_arrow_orig[$k]=$w
    bindkey "^[[$k" _clicue_arrow_${want[$k]}
  done
  # Enter: insert the highlighted cue rather than executing, but only while a
  # card is being navigated. Capture what owned it so everything else is intact.
  w=${${(z)$(bindkey '^M')}[2]}
  [[ -n $w && $w != _clicue_insert ]] && typeset -g _clicue_orig_enter=$w
  bindkey '^M' _clicue_insert

  # End also accepts the proposal, matching the gesture autosuggestions used
  local e
  for e in '^[[F' '^[[4~' '^[OF' '^E'; do
    w=${${(z)$(bindkey $e)}[2]}
    [[ -z $w || $w == _clicue_end_of_line ]] && continue
    [[ -z $_clicue_orig_eol ]] && typeset -g _clicue_orig_eol=$w
    bindkey $e _clicue_end_of_line
  done
}

_clicue_install_yields() {
  local w impl fn
  for w in $_clicue_yield_widgets; do
    impl=${widgets[$w]}
    [[ -z $impl ]] && continue
    fn=_clicue_yield_${w//-/_}
    [[ $impl == user:${fn} ]] && continue        # already wrapped
    case $impl in
      user:*)       eval "${fn}_orig() { ${impl#user:} \"\$@\" }" ;;
      completion:*) continue ;;
      *)            eval "${fn}_orig() { zle .$w -- \"\$@\" }" ;;
    esac
    eval "$fn() { _clicue_clear_card; ${fn}_orig \"\$@\" }"
    zle -N $w $fn
  done
}

# Must run AFTER zsh-autosuggestions has done its own widget rebinding, which it
# defers to its first precmd. Wrapping earlier captures the bare builtin and
# leaves autosuggestions wrapping US — it would then read POSTDISPLAY before we
# ever get to clear it. Registering our precmd after theirs makes us outermost.
autoload -Uz add-zsh-hook
_clicue_first_precmd() {
  _clicue_install_yields
  _clicue_install_arrows
  _clicue_wrap_async
  add-zsh-hook -d precmd _clicue_first_precmd
  unfunction _clicue_first_precmd
}
add-zsh-hook precmd _clicue_first_precmd

add-zle-hook-widget line-pre-redraw _clicue_pre_redraw
add-zle-hook-widget line-finish     _clicue_line_finish
