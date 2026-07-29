#!/usr/bin/env zsh
# clicue — the card
#
# Turns a candidate list into lines of text plus region_highlight spans. Reads the
# theme; never contains a literal box glyph, because the glyph set has to be
# swappable for terminals whose font cannot draw it.
#
# Two boxes, one selection. Tier 1 (nearest the prompt) is what this operator
# actually invokes — it has history behind it. Tier 2 is either the overflow of the
# candidate list as a column grid, or, in argument position, an explanation of what
# is already on the line. The selection flows out of the bottom of tier 1 straight
# into the grid, so there is no mode to switch and no second keybinding to learn.
#
# Height is a fixed budget both boxes pad into. ZLE paints a taller POSTDISPLAY over
# a shorter one rather than reflowing, so a card that changed height while typing
# would mangle itself.

# $1 lo  $2 hi  $3 window-top  $4 label  $5 maxrows  $6 namew  $7 glossw  $8 inner
# Which gutter glyph names this cue's origin.
#
# Only kinds that can be determined RELIABLY get a glyph. Guessing here would be
# worse than a blank column: a wrong source marker is a confident lie about where a
# suggestion came from, and the operator has no way to check it.
_clicue_kind_glyph() {
  local ent=$1 kind=$2
  if [[ $kind == arg ]]; then
    # in argument position the useful distinction is option vs subcommand
    if [[ $ent == -* ]]; then _clicue_kg=${CLICUE_GLYPH[k_flag]}
    else                     _clicue_kg=${CLICUE_GLYPH[k_sub]}
    fi
    return
  fi
  case $kind in
    (alias)    _clicue_kg=${CLICUE_GLYPH[k_alias]} ;;
    (function) _clicue_kg=${CLICUE_GLYPH[k_function]} ;;
    (builtin)  _clicue_kg=${CLICUE_GLYPH[k_builtin]} ;;
    (system)   _clicue_kg=${CLICUE_GLYPH[k_system]} ;;
    (*)        _clicue_kg=${CLICUE_GLYPH[k_none]} ;;
  esac
}

_clicue_emit_box() {
  local -i lo=$1 hi=$2 top=$3 maxrows=$5 namew=$6 glossw=$7 inner=$8
  local label=$4
  (( top < lo )) && top=$lo
  local -i bot=$(( top + maxrows - 1 ))
  (( bot > hi )) && bot=$hi
  (( top > bot )) && return 1

  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  _clicue_lines+=( "${CLICUE_GLYPH[tl]}${label}${(pl:$rule::$_clicue_hg:):-}${CLICUE_GLYPH[tr]}" )

  local -i emitted=0
  local -i i
  local ent name kind g nmcol gcol marker
  for (( i = top; i <= bot; i++ )); do
    (( emitted++ ))
    ent=${_clicue_cands[i]}
    name=${_clicue_disp[$ent]:-$ent}
    kind=${_clicue_kind[$ent]:-system}
    [[ $_clicue_mode == arg ]] && kind=arg
    # $ent, NOT $name: the description is keyed on the real token. Looking it up
    # by the display label silently returned nothing for every paired row.
    _clicue_gloss $ent $kind; g=$_clicue_g
    marker=" ${CLICUE_GLYPH[nosel]}"
    (( i == _clicue_sel )) && marker=" ${CLICUE_GLYPH[sel]}"
    nmcol=${(r:$namew:)${name[1,$namew]}}
    (( ${#g} > glossw )) && g="${g[1,$(( glossw - 1 ))]}…"
    gcol=${(r:$glossw:)g}
    _clicue_kind_glyph $ent $kind
    # How much of this name the operator has already typed. Recorded per LINE, the
    # same way grid rows are, because the span pass walks rendered lines and has no
    # other way back to the candidate. Only when the DISPLAYED name starts with the
    # prefix: a grouped label reached by its long spelling (`-d, --dir` matched via
    # `--d`) does not begin with what was typed, and bolding the first two characters
    # there would emphasise the wrong thing.
    if [[ -n $_clicue_pfx && $name == ${_clicue_pfx}* ]]; then
      _clicue_matchlen[$(( ${#_clicue_lines} + 1 ))]=${#_clicue_pfx}
    fi
    _clicue_lines+=( "${CLICUE_GLYPH[v]}${marker} ${_clicue_kg} ${nmcol}  ${gcol}${CLICUE_GLYPH[v]}" )
  done
  # Deliberately NOT padded to the allocation. The card shows as many cues as
  # exist and no blank filler. This makes the card's height vary with the
  # candidate count, which re-tests an earlier inference (that ZLE paints a
  # taller POSTDISPLAY over a shorter one rather than reflowing) — that was
  # never isolated, only worked around. If display mangling returns while
  # typing, the inference was right and padding must come back.
  return 0
}

# Tier 2 in argument position: what the operator has ALREADY typed, enumerated.
#
# Once the invocation is past the command name there is no reason to keep hunting
# for similarly-named commands — that question is answered. The useful question is
# what the thing on the line actually does, so the same real estate becomes one
# row per property:
#
#   -l, --long        Display extended file metadata as a table
#   -a, --all         Do not ignore entries starting with .
#   -t, --timesort    Sort by time modified
#
# Rows are `label<TAB>description`. Not selectable: this box is an explanation of
# the line, not a picker. The selection stays in tier 1 where it composes.
#   $1 maxrows  $2 namew  $3 inner  $4 footer
_clicue_emit_explain() {
  local -i maxrows=$1 namew=$2 inner=$3
  local footer=$4
  (( ${#_clicue_explain_rows} )) || return 1

  # An invocation in the top percentile of the operator's own history is one they
  # know. Collapse to the evidence line and say how to open it — a REDUCED view,
  # never a silently different one, and the expand key is named on the row so a
  # collapsed box cannot be mistaken for a broken one.
  local -i collapsed=0
  if (( ! _clicue_expanded )) && _clicue_is_familiar; then collapsed=1; fi

  local label=' typed '
  (( collapsed )) && label=' typed · collapsed '
  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  # ├ joins the box above; ╭ opens one. With a complete invocation there are no
  # candidates and therefore no box above, and the card was drawn with no top edge.
  if (( ${#_clicue_lines} )); then
    _clicue_lines+=( "${CLICUE_GLYPH[jl]}${label}${(pl:$rule::$_clicue_hg:):-}${CLICUE_GLYPH[jr]}" )
  else
    _clicue_lines+=( "${CLICUE_GLYPH[tl]}${label}${(pl:$rule::$_clicue_hg:):-}${CLICUE_GLYPH[tr]}" )
  fi

  if (( collapsed )); then
    local REPLY ekey
    local -a ev
    zstyle -a ':clicue:keys' expand ev || ev=( '^[e' )
    _clicue_keylabel ${ev[1]}; ekey=$REPLY
    local note=${footer:-"${#_clicue_explain_rows} properties"}
    local line="${note}  ·  ${ekey} to expand"
    local -i crule=$(( inner - ${#line} - 3 ))
    (( crule < 1 )) && crule=1
    _clicue_lines+=( "${CLICUE_GLYPH[v]}   ${line}${(l:$crule:: :):-}${CLICUE_GLYPH[v]}" )
    _clicue_footrow=${#_clicue_lines}
    return 0
  fi

  # left column matches tier 1's width so the two boxes line up
  local -i lw=$namew
  local row nm ds
  local -i i=0 dw
  for row in $_clicue_explain_rows; do
    (( ++i > maxrows )) && break
    nm=${row%%$'\t'*}
    ds=${row#*$'\t'}
    (( ${#nm} > lw )) && nm="${nm[1,$lw]}"
    dw=$(( inner - lw - 5 ))
    (( dw < 10 )) && dw=10
    (( ${#ds} > dw )) && ds="${ds[1,$(( dw - 1 ))]}…"
    _clicue_lines+=( "${CLICUE_GLYPH[v]}   ${(r:$lw:)nm}  ${(r:$dw:)ds}${CLICUE_GLYPH[v]}" )
    _clicue_explainrows+=( ${#_clicue_lines} )
  done
  if [[ -n $footer ]]; then
    local -i frule=$(( inner - ${#footer} - 3 ))
    (( frule < 1 )) && frule=1
    _clicue_lines+=( "${CLICUE_GLYPH[v]}   ${footer}${(l:$frule:: :):-}${CLICUE_GLYPH[v]}" )
    _clicue_footrow=${#_clicue_lines}
  fi
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
  # Label says what the box actually holds. "on system" is a command-position
  # sentence; in argument position these are the remaining options for one command.
  local label=" all ${n} on system "
  [[ $_clicue_mode == arg ]] && label=" ${n} more "

  (( _clicue_focus == 2 )) && label=" browsing ${n} — $(( _clicue_sel - lo + 1 ))/${n} "
  local -i rule=$(( inner - ${#label} ))
  (( rule < 1 )) && rule=1
  _clicue_lines+=( "${CLICUE_GLYPH[tl]}${label}${(pl:$rule::$_clicue_hg:):-}${CLICUE_GLYPH[tr]}" )

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
        cell="${CLICUE_GLYPH[sel]}${${(r:$(( colw - 1 )):)${nm[1,$w]}}}"
        # remember exactly where this cell lands so only IT gets the selection
        # highlight — colouring the whole row would imply the row is the unit
        _clicue_selline=$(( ${#_clicue_lines} + 1 ))
        _clicue_selcol=$(( 1 + gutter + off ))
        _clicue_selw=$colw
      fi
      row+=$cell
      (( off += colw ))
    done
    _clicue_lines+=( "${CLICUE_GLYPH[v]}${(r:$gutter:)}${${(r:$avail:)row}}${CLICUE_GLYPH[v]}" )
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
  # cleared per render, or a label from the previous command would outlive it
  _clicue_disp=()
  _clicue_coldflags=0

  # ── what is already on the line, explained ────────────────────────────────
  # Built before the empty-candidate bail, because a COMPLETE invocation is
  # exactly the case with nothing left to propose. `ls -lat` matches no further
  # candidate, so the card used to vanish at the moment the operator had typed
  # something worth explaining.
  #
  # Only populated once the command's flag set is known — that needs a compsys
  # fork, so it arrives on the first Tab and from the on-disk cache thereafter.
  _clicue_explain_rows=()
  if [[ $_clicue_mode == arg ]] && (( ${#_clicue_words} > 1 )); then
    # cheap: reads the cache file at most once per command per shell
    _clicue_flag_load $_clicue_cmd 2>/dev/null
    local -a eparts
    local etok ef
    local -A eseen=()
    for etok in ${_clicue_words[2,-1]}; do
      [[ $etok == -* ]] || continue
      _clicue_fkey $_clicue_cmd $etok
      if [[ -n ${_clicue_flag_desc[$_clicue_fk]} ]]; then
        eparts=( $etok )
      elif _clicue_decompose $_clicue_cmd $etok; then
        eparts=( $_clicue_parts )
      else
        continue
      fi
      for ef in $eparts; do
        (( ${+eseen[$ef]} )) && continue
        eseen[$ef]=1
        _clicue_flag_label $_clicue_cmd $ef
        _clicue_fkey $_clicue_cmd $ef
        _clicue_explain_rows+=( "${_clicue_fl}"$'\t'"${_clicue_flag_desc[$_clicue_fk]}" )
      done
    done
  fi

  if [[ $_clicue_mode == arg ]] && (( _clicue_info )); then
    # The placeholder spends the primary card on the command's OWN NAME, which is not
    # a cue the operator can act on. It existed because a card with no rows at all
    # would have rendered as an empty box; now that the explanation can open a card by
    # itself, there is nothing left for it to do.
    if (( ${#_clicue_explain_rows} )); then
      reply=(); _clicue_tier1_n=0
    else
      reply=( $_clicue_cmd ); _clicue_tier1_n=1
    fi
  elif [[ $_clicue_mode == arg ]]; then
    if ! _clicue_arg_candidates $_clicue_cmd "$pfx"; then
      # Typing an option with no flag data yet. Rendering nothing here is what
      # reads as "this command cannot be completed" — the operator has no way to
      # know one Tab would fill the card. Say it instead.
      # Also taken when a harvest already happened and found NOTHING — an alias
      # resolving to a shell function lands there. Without the second test the cache
      # file exists, the load succeeds, and the operator gets no card at all rather
      # than being told there is nothing to show.
      _clicue_resolve_cmd $_clicue_cmd
      if [[ $pfx == -* ]] && \
         { ! _clicue_flag_load $_clicue_cmd 2>/dev/null || \
           (( ${+_clicue_flag_none[$_clicue_realcmd]} )) }; then
        _clicue_info=1; _clicue_coldflags=1; reply=( $_clicue_cmd )
        _clicue_tier1_n=1
        cands=( $reply )
        _clicue_cands=( $cands )
      elif (( ${#_clicue_explain_rows} )); then
        # A COMPLETE invocation is exactly the case with nothing left to propose.
        # `rm -rf` matches no further candidate, so the card used to vanish at the
        # moment the operator had typed something worth explaining.
        reply=()
      elif [[ -n $pfx ]]; then
        return 1
      else
        _clicue_info=1; reply=( $_clicue_cmd )
      fi
    fi
    # history-derived args are tier 1; compsys-derived fill the grid
    _clicue_tier1_n=${_clicue_arg_t1:-${#reply}}
  else
    _clicue_candidates $pfx
  fi
  cands=( $reply )

  # An explanation alone is enough to justify the card.
  (( ${#cands} || ${#_clicue_explain_rows} )) || return 1
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

  # Read fresh on every render, so a resize takes effect on the next keystroke with
  # no hook and no cost: zsh maintains COLUMNS on SIGWINCH itself.
  #
  # 80 is the width the layout is DESIGNED for and the one the assertions cover.
  # Narrower still renders — it narrows the gloss column and drops hint segments
  # rather than overflowing — but below about 50 there is not much left to show.
  local -i width=${COLUMNS:-80}
  (( width > 120 )) && width=120
  # A floor must never exceed the real terminal: drawing a 30-column card in a
  # 24-column window wraps every line, which is worse than a cramped card. So the
  # floor is a preference, and COLUMNS is the hard limit.
  (( width < 30 )) && width=${COLUMNS:-30}
  (( width < 12 )) && width=12
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
  # Measured over DISPLAY labels, not raw tokens: a paired row shows `-f, --force`
  # and sizing on `-f` truncated it to `-f, --forc`.
  (( t1n > 0 )) && for (( i = _clicue_top1; i <= t1n && i < _clicue_top1 + r1; i++ )) vis+=( ${_clicue_disp[${cands[i]}]:-${cands[i]}} )
  if (( total > t1n )); then
    local -i t2=$_clicue_top2
    (( t2 < t1n + 1 )) && t2=$(( t1n + 1 ))
    for (( i = t2; i <= total && i < t2 + r2; i++ )) vis+=( ${_clicue_disp[${cands[i]}]:-${cands[i]}} )
  fi
  # The explain box shares this column so the two boxes line up, so its labels
  # have to be measured too — otherwise a card with no candidates at all sizes to
  # the 10-column minimum and clips every explanation.
  local erow
  for erow in $_clicue_explain_rows; do vis+=( ${erow%%$'\t'*} ); done
  for i in {1..${#vis}}; do (( ${#vis[i]} > namew )) && namew=${#vis[i]}; done
  (( namew > 28 )) && namew=28
  # Capped against what is actually LEFT, not only against a constant. The name column
  # and the gloss column both had floors, and at 32 columns their floors plus the
  # overhead exceeded the terminal — so a row ran 6 columns past the border and
  # wrapped. Names truncate instead; a clipped name is legible, a wrapped card is not.
  local -i namemax=$(( inner - 7 - 10 ))
  (( namemax < 6 )) && namemax=6
  (( namew > namemax )) && namew=$namemax
  (( namew < 10 && namew < namemax )) && namew=10
  # A list row is:
  #   border | marker(2) | space | gutter(1) | space | name(namew) | 2 spaces | gloss
  # so the non-gloss overhead is 1 + 2 + 1 + 1 + 1 + namew + 2 = namew + 8, and the
  # closing border takes one more. Written out because getting this wrong by one
  # pushed the right border a column past the top border — visible immediately, but
  # only if you look at the rendered card rather than at the state.
  local -i glossw=$(( inner - namew - 7 ))
  (( glossw < 10 )) && glossw=10

  _clicue_lines=()
  _clicue_gridrows=(); _clicue_selline=0
  _clicue_explainrows=(); _clicue_footrow=0
  _clicue_matchlen=()
  local hint=${_clicue_hint:-' Tab accept · Esc dismiss '}
  # The reduced hint is for a card with nothing to navigate. Gated on that being
  # TRUE, not on info mode: an informational card that carries an explanation is
  # navigable, and advertising only `dismiss` there actively misleads about what Tab
  # and the arrows will do.
  if (( _clicue_info )) && (( ! ${#_clicue_explain_rows} )); then
    local REPLY; local -a dv
    zstyle -a ':clicue:keys' dismiss dv || dv=( '^[' )
    _clicue_keylabel ${dv[1]}; hint=" ${REPLY} dismiss "
  fi

  # tier 1 first — nearest the prompt
  if (( t1n > 0 )); then
    _clicue_emit_box 1 $t1n $_clicue_top1 " ${_clicue_sel}/${total} " \
                     $r1 $namew $glossw $inner
  fi
  # In argument position the second box explains the line instead of browsing
  # commands. The grid stays for command position, where "what else is named like
  # this" is still the live question.
  if (( ${#_clicue_explain_rows} )); then
    # Its own allocation. r2 is the CANDIDATE overflow, which is zero when a
    # complete invocation leaves nothing further to propose — and a zero
    # allocation drew the box header with no rows under it.
    local -i er=${#_clicue_explain_rows}
    (( er > r2 )) && (( r2 > 0 )) && er=$r2
    (( er > maxlines - 6 )) && er=$(( maxlines - 6 ))
    (( er < 1 )) && er=1
    _clicue_invocation_note
    _clicue_emit_explain $er $namew $inner "$_clicue_invnote"
  elif (( total > t1n )); then
    _clicue_emit_grid $(( t1n + 1 )) $total $r2 $inner
  fi

  # Left-justified: it reads as a label on the box rather than as a right-aligned
  # afterthought, and it is the end that gets dropped when space runs out, so the
  # segments that survive stay in a stable position instead of sliding.
  if (( ${#_clicue_hintparts} )) && [[ $hint == " ${(j: · :)_clicue_hintparts} " ]]; then
    _clicue_fit_hint $inner
    hint=$_clicue_hintfit
  elif (( ${#hint} > inner )); then
    # a caller-supplied hint (the info card's `Esc dismiss`) still must not overflow
    hint=" ${hint[2,$(( inner - 1 ))]} "
  fi
  local -i brule=$(( inner - ${#hint} ))
  (( brule < 0 )) && brule=0
  _clicue_lines+=( "${CLICUE_GLYPH[bl]}${hint}${(pl:$brule::$_clicue_hg:):-}${CLICUE_GLYPH[br]}" )

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
    local gdisp=${_clicue_disp[$gname]:-$gname}
    local gkind=${_clicue_kind[$gname]:-system}
    [[ $_clicue_mode == arg ]] && gkind=arg
    _clicue_gloss $gname $gkind
    local -i gw=$(( inner - namew - 5 ))
    (( gw < 10 )) && gw=10
    local gg=$_clicue_g
    (( ${#gg} > gw )) && gg="${gg[1,$(( gw - 1 ))]}…"
    _clicue_lines+=( "${CLICUE_GLYPH[v]}   ${(r:$namew:)${gdisp[1,$namew]}}  ${(r:$gw:)gg}${CLICUE_GLYPH[v]}" )
    _clicue_lines+=( "${CLICUE_GLYPH[bl]}${(pl:$inner::$_clicue_hg:):-}${CLICUE_GLYPH[br]}" )
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
    # NOTE: this pass identifies a row by matching the RENDERED line, so it has to
    # be told the themed glyphs too. Fragile, and known to be — it is why the glyph
    # set is validated at load rather than trusted.
    if [[ $ln == (${CLICUE_GLYPH[tl]}|${CLICUE_GLYPH[bl]}|${CLICUE_GLYPH[jl]})* ]]; then
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
      # the gutter glyph sits between marker and name, dimmed: it is orientation,
      # not content, and should not compete with the cue itself
      specs+=( "$(( pos + 4 )) $(( pos + 5 )) fg=${CLICUE_THEME[hint]}" )
      # The part already typed is emphasised and the remainder is ordinary text, so
      # the eye lands on what is NEW about each candidate rather than re-reading the
      # prefix it just typed on every row.
      specs+=( "$(( pos + 6 )) $(( pos + 6 + namew )) fg=${CLICUE_THEME[text]}" )
      if (( ${+_clicue_matchlen[$i]} )); then
        specs+=( "$(( pos + 6 )) $(( pos + 6 + _clicue_matchlen[$i] )) fg=${CLICUE_THEME[accent]},bold" )
      fi
      specs+=( "$(( pos + 8 + namew )) $(( pos + len - 1 )) fg=${CLICUE_THEME[gloss]}" )
      [[ $ln == "${CLICUE_GLYPH[v]} ${CLICUE_GLYPH[sel]}"* ]] && \
        specs+=( "$pos $(( pos + len )) fg=${CLICUE_THEME[seltext]},bg=${CLICUE_THEME[selbg]}" )
    fi
    (( pos += len + 1 ))
  done
  _clicue_spans=( $specs )
  return 0
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

# Build the hint line once, from what is actually bound. Bindings vary by
# terminal, so advertising the real ones is load-bearing rather than decorative.
# The hint as SEGMENTS rather than one string, so a narrow terminal can drop the
# least important from the right instead of overflowing the box. At 60 columns the
# single-string version ran 2 columns past the border and wrapped, which mangles the
# card — the one failure mode the whole fixed-height design exists to avoid.
#
# Ordered most-essential FIRST: dismiss is the escape hatch and must survive any
# width, cycle is the primary gesture, the rest are discoverable by trying them.
_clicue_build_hint() {
  local REPLY
  local -a av dv
  zstyle -a ':clicue:keys' accept  av || av=( '^I' )
  zstyle -a ':clicue:keys' dismiss dv || dv=( '^[' )
  _clicue_keylabel ${av[1]}; local cyc=$REPLY
  _clicue_keylabel ${dv[1]}; local dis=$REPLY
  typeset -ga _clicue_hintparts=(
    "${cyc} cycle"
    "↑↓ browse"
    "→ accept"
    "⏎ insert"
    "${dis} dismiss"
  )
  typeset -g _clicue_hint=" ${(j: · :)_clicue_hintparts} "
}

# Fit as many segments as the width allows. Always yields something: at absurd widths
# it falls back to the first segment truncated, never to an overflowing line.
_clicue_fit_hint() {
  local -i avail=$1
  local try
  local -i n=${#_clicue_hintparts}
  while (( n > 0 )); do
    try=" ${(j: · :)_clicue_hintparts[1,n]} "
    (( ${#try} <= avail )) && { _clicue_hintfit=$try; return 0 }
    (( n-- ))
  done
  _clicue_hintfit=" ${_clicue_hintparts[1][1,$(( avail > 2 ? avail - 2 : 1 ))]} "
  return 0
}
