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

# A box label that cannot overflow its border. `rule = inner - ${#label}` clamped at 1
# keeps the RULE positive but says nothing about the label, so a label longer than the
# box produced a line wider than the card — the wrap that mangles the whole display.
# Latent until the grid label started carrying a page counter, which is exactly the
# kind of growth that finds it. Truncation is silent because a clipped label still
# reads, where a wrapped card does not.
_clicue_fit_label() {
  local lbl=$1
  local -i inner=$2 keep
  if (( ${#lbl} > inner - 1 )); then
    keep=$(( inner - 2 ))
    (( keep < 1 )) && keep=1
    lbl="${lbl[1,$keep]} "
  fi
  _clicue_label=$lbl
  return 0
}

_clicue_emit_box() {
  local -i lo=$1 hi=$2 top=$3 maxrows=$5 namew=$6 glossw=$7 inner=$8
  local label=$4
  _clicue_fit_label "$label" $inner; label=$_clicue_label
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
  _clicue_fit_label "$label" $inner; label=$_clicue_label
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
  # Published so the paging keys move by exactly what is on screen rather than by a
  # number of their own. A PageDown that disagrees with the visible page is worse than
  # no PageDown: the operator loses their place instead of advancing it.
  typeset -gi _clicue_grid_page=$page
  typeset -gi _clicue_grid_lo=$lo _clicue_grid_hi=$hi

  local -i shown=$(( hi - _clicue_gridtop + 1 ))
  (( shown > page )) && shown=$page
  # Where am I in the whole list? A grid that pages needs to say so, or the operator
  # cannot tell a full list from the first slice of one. Pages are 1-based and derived
  # from the SAME page size the keys move by, so the counter and the keys cannot
  # disagree.
  local -i npages=$(( (n + page - 1) / page ))
  local -i curpage=$(( (_clicue_gridtop - lo) / page + 1 ))
  local pg=''
  (( npages > 1 )) && pg=" · page ${curpage}/${npages}"

  # Label says what the box actually holds. "on system" is a command-position
  # sentence; in argument position these are the remaining options for one command.
  local label=" all ${n} on system${pg} "
  [[ $_clicue_mode == arg ]] && label=" ${n} more${pg} "

  (( _clicue_focus == 2 )) && label=" browsing $(( _clicue_sel - lo + 1 ))/${n}${pg} "
  _clicue_fit_label "$label" $inner; label=$_clicue_label
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

# ── how big may the card be ──────────────────────────────────────────────────
# Both read the terminal fresh on every render, so a resize takes effect on the next
# keystroke with no hook and no cost: zsh maintains COLUMNS and LINES on SIGWINCH
# itself. Extracted from _clicue_render so the one rule that matters in each — never
# larger than the terminal — is testable by arithmetic. It cannot be tested by
# measuring the rendered card, because the length that mangles the display and the
# length that fits are the SAME NUMBER; only a screen can tell them apart, and the
# assertions do not have one.

# The card's outer width, in columns.
_clicue_layout_width() {
  local -i cols=${1:-${COLUMNS:-80}}
  # COLUMNS **minus one**, never COLUMNS. zsh's redisplay will not write into the last
  # column — it wraps there instead — so a card exactly COLUMNS wide has the closing
  # border of EVERY row pushed onto a line of its own. That is the display mangling the
  # fixed-height design exists to prevent, and it reads as a total malfunction rather
  # than as a cramped card.
  #
  # [MEASURED] in a real 104-column pty the 104-character top border came back as 103
  # characters on one row with the 104th on the next. The off-by-one survived a long
  # time because the max-width cap happened to supply the missing column at the
  # author's usual 121-column terminal: 121 capped to 120 leaves exactly one column of
  # slack. Every width that was NOT capped was broken.
  typeset -gi _clicue_lw=$(( cols - 1 ))
  # A cap, not a target: past about 120 columns a row of text is harder to scan than a
  # narrower one, so the card stops growing rather than following a very wide window.
  local -i maxwidth=120
  zstyle -s ':clicue:*' max-width maxwidth 2>/dev/null || maxwidth=120
  (( _clicue_lw > maxwidth )) && _clicue_lw=$maxwidth
  # No floor above the terminal. A preferred minimum can only ever be honoured by
  # drawing wider than the window, which wraps every line — worse than cramped. 12 is
  # not a preference but the arithmetic limit: below it `inner` goes non-positive.
  (( _clicue_lw < 12 )) && _clicue_lw=12
  return 0
}

# The card's total height, in rows — a ceiling on 1 + r1 + 1 + r2 + hint + gloss +
# close, enforced in _clicue_render rather than merely consulted.
#
# It used to default to 14 and bound only the explanation pane, while the card's real
# height was `tier1-rows + tier2-rows + 5` with tier2 sized to fill the window. So the
# documented total budget was not a budget at all, and no combination of row settings
# was prevented from drawing a card taller than the terminal. Deriving the default from
# the window makes the setting mean what it says and makes the shove structurally
# impossible rather than merely unlikely.
_clicue_layout_height() {
  local -i rows=${1:-${LINES:-24}}
  local cfg=auto
  zstyle -s ':clicue:*' max-lines cfg 2>/dev/null || cfg=auto
  typeset -gi _clicue_lh
  if [[ $cfg == auto || -z $cfg ]]; then
    # The reserve covers the prompt's own rows and the line being typed.
    _clicue_lh=$(( rows - 6 ))
  else
    _clicue_lh=$cfg
  fi
  (( _clicue_lh < 8 )) && _clicue_lh=8
  # Never taller than the window can hold. Same discipline as the width, and the same
  # latent defect: a preferred minimum that exceeds the terminal is not a minimum, it
  # is a card drawn off the bottom of the screen. Applied AFTER the floor — a floor
  # allowed to win last is exactly how the width bug survived. This also caps an
  # explicit max-lines, so a configured 40 in a 24-row window still fits.
  local -i vfit=$(( rows - 6 ))
  (( _clicue_lh > vfit )) && _clicue_lh=$vfit
  # 1 border + one row + hint + gloss + close. Not a preference; the emitter's floor.
  (( _clicue_lh < 5 )) && _clicue_lh=5
  return 0
}

_clicue_render() {
  local pfx=$1
  local -a cands
  local -a reply
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
  # ── comprehension: what does this line SAY ────────────────────────────────
  # Driven by the TOKENS, not by the cursor. That is what makes a pasted command
  # explain itself with no paste detection, no bracketed-paste hook and no new mode:
  # a pasted line is just a line, and this pane reads lines.
  #
  # Walks left to right maintaining the command PATH, because a token's meaning depends
  # on where it sits — `list` means something under `gh org` and nothing under `gh`.
  # Subcommands extend the path; flags do not.
  _clicue_explain_rows=()
  if [[ $_clicue_mode == arg ]] && (( ${#_clicue_words} > 1 )); then
    local epath=${_clicue_words[1]}
    local -a eparts
    local etok ef edesc
    local -A eseen=()
    _clicue_flag_load $epath 2>/dev/null
    local -i ei
    for (( ei = 2; ei <= ${#_clicue_words}; ei++ )); do
      etok=${_clicue_words[ei]}
      [[ -n $etok ]] || continue
      _clicue_fkey $epath $etok
      edesc=${_clicue_flag_desc[$_clicue_fk]}

      if [[ $etok != -* ]]; then
        # A subcommand, if this path documents it. Anything else is a VALUE — a
        # filename, a number, an argument to the flag before it — and clicue has
        # nothing true to say about those, so it says nothing rather than guessing.
        if [[ -n $edesc ]] && (( ! ${+eseen[$etok]} )); then
          eseen[$etok]=1
          _clicue_flag_label $epath $etok
          _clicue_explain_rows+=( "${_clicue_fl}"$'\t'"${edesc}" )
        fi
        # Descend regardless of whether it was documented: an undocumented
        # subcommand still changes what the NEXT token means.
        epath="${epath}:${etok}"
        _clicue_flag_load $epath 2>/dev/null
        continue
      fi

      if [[ -n $edesc ]]; then
        eparts=( $etok )
      elif _clicue_decompose $epath $etok; then
        eparts=( $_clicue_parts )
      else
        continue
      fi
      for ef in $eparts; do
        (( ${+eseen[$ef]} )) && continue
        eseen[$ef]=1
        _clicue_flag_label $epath $ef
        _clicue_fkey $epath $ef
        _clicue_explain_rows+=( "${_clicue_fl}"$'\t'"${_clicue_flag_desc[$_clicue_fk]}" )
      done
    done
  fi

  # ── composition: what can go HERE ─────────────────────────────────────────
  # Driven by the cursor. Restored after being deleted by an edit anchored on a REGION
  # rather than on exact boundaries — the mode dispatch sat between the two anchors and
  # went with them, so every card came back empty. Third time that shape has cost
  # something in this project; the rule is exact strings, never spans.
  if [[ $_clicue_mode == arg ]] && (( _clicue_info )); then
    # The placeholder spends the primary card on the command's OWN NAME, which is not
    # a cue the operator can act on. Now that the explanation can open a card by
    # itself, there is nothing left for it to do.
    if (( ${#_clicue_explain_rows} )); then
      reply=()
    else
      reply=( $_clicue_cmd )
    fi
  elif [[ $_clicue_mode == arg ]]; then
    if ! _clicue_arg_candidates $_clicue_cmd "$pfx"; then
      # Typing an option with no flag data yet. Rendering nothing here is what reads as
      # "this command cannot be completed" — say it instead.
      _clicue_resolve_cmd $_clicue_cmd
      if [[ $pfx == -* ]] && \
         { ! _clicue_flag_load ${_clicue_cmdpath:-$_clicue_cmd} 2>/dev/null || \
           (( ${+_clicue_flag_none[$_clicue_realcmd]} )) }; then
        _clicue_info=1; _clicue_coldflags=1; reply=( $_clicue_cmd )
        cands=( $reply )
        _clicue_cands=( $cands )
      elif (( ${#_clicue_explain_rows} )); then
        # A COMPLETE invocation is exactly the case with nothing left to propose.
        reply=()
      elif [[ -n $pfx ]]; then
        return 1
      else
        _clicue_info=1; reply=( $_clicue_cmd )
      fi
    fi
    # History-derived args lead the list, compsys-derived follow — that ORDER is the
    # whole mechanism (_clicue_arg_candidates builds `$hist ${(o)rest}`). Where the
    # primary card ends is the fixed row count below, not that seam, so a command with
    # 18 remembered args puts 10 on the card and the rest in the grid.
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
  _clicue_layout_height
  local -i maxlines=$_clicue_lh
  local -i total=${#cands}
  # primary card holds a fixed number of cues; the overflow becomes the grid
  local -i t1rows=10
  zstyle -s ':clicue:*' tier1-rows t1rows 2>/dev/null || t1rows=10
  (( t1rows < 1 )) && t1rows=1
  # ── the grid is CLAMPED, not filled ────────────────────────────────────────
  # It used to take everything the terminal could spare (`LINES - t1rows - 10`), which
  # sounds generous and is not: typing `s` offers 460-odd commands, the grid grew to 68
  # rows in an 88-row window, and the resulting 83-line card shoved the scrollback off
  # the screen — including the output of the command the operator had just run. A
  # guidance surface that destroys the context it is meant to support has inverted its
  # own purpose.
  #
  # A THIRD of the window, floored at 10 rows so it stays useful in a small one, and
  # still bounded by what the window can spare because the terminal always wins. The
  # rest of the list is reachable by paging, which the grid already did — what was
  # missing was a way to page deliberately and a counter saying there was more.
  local t2cfg=auto
  zstyle -s ':clicue:*' tier2-rows t2cfg 2>/dev/null || t2cfg=auto
  local -i spare=$(( ${LINES:-24} - t1rows - 10 ))
  local -i t2rows
  typeset -gi _clicue_canmax=0
  if [[ $t2cfg == auto ]]; then
    local -i clamped=$(( ${LINES:-24} / 3 ))
    (( clamped < 10 )) && clamped=10
    (( clamped > spare )) && clamped=$spare
    # Would maximising actually add rows? In a small window the clamp and the spare
    # meet, and Alt+M cannot do anything — so the legend must not offer it. Same rule
    # as everywhere else in the legend: advertise the gesture only where it is real.
    _clicue_canmax=$(( spare > clamped ))
    # When maximised the shove is the operator's own explicit choice, which is a
    # different thing from a surprise. It is also still bounded by the budget below.
    if (( _clicue_maxed )); then t2rows=$spare; else t2rows=$clamped; fi
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

  _clicue_layout_width
  local -i width=$_clicue_lw
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

  # ── the budget is enforced, not assumed ────────────────────────────────────
  # Whatever the row preferences add up to, the card fits the window. Without this the
  # total was simply `tier1-rows + tier2-rows + 5` and nothing stopped it exceeding
  # LINES — which is how a 68-row grid in an 88-row terminal became an 83-line card.
  #
  # The grid gives up rows FIRST: it is the browsable overflow and it pages, so a row
  # taken from it costs a scroll, while a row taken from tier 1 removes a history-ranked
  # cue from the place the operator looks first.
  local -i over=$(( r1 + r2 + 5 - maxlines ))
  if (( over > 0 )); then
    local -i cut=$over
    (( cut > r2 )) && cut=$r2
    (( r2 -= cut )); (( over -= cut ))
    (( over > 0 )) && (( r1 -= over ))
    (( r1 < 1 )) && r1=1
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
  # Derived from live state, every render: which gestures are real depends on what
  # the card is currently showing. The selection has already been clamped above, so
  # _clicue_sel and _clicue_cands agree by the time this reads them.
  _clicue_hint_segments
  local hint=" ${(j: · :)_clicue_hintparts} "

  # tier 1 first — nearest the prompt
  if (( t1n > 0 )); then
    # When the typed option prefix matched nothing, the card is showing the command's
    # WHOLE option set — useful, but it must not imply these are matches. Saying so is
    # what makes offering them honest rather than confusing.
    local t1label=" ${_clicue_sel}/${total} "
    (( _clicue_argnomatch )) && t1label=" ${_clicue_sel}/${total} · nothing matches ${_clicue_pfx} "
    _clicue_emit_box 1 $t1n $_clicue_top1 "$t1label" \
                     $r1 $namew $glossw $inner
  fi
  # In argument position the second box explains the line instead of browsing
  # commands. The grid stays for command position, where "what else is named like
  # this" is still the live question.
  # BOTH, when both apply. These used to be alternatives, and the explanation won —
  # so `ffmpeg -i potato.file -ab` showed 10 of 185 options and no browser at all,
  # even though the 1/185 counter said plainly that there were 175 more. The two boxes
  # answer different questions ("what else could go here" and "what have I already
  # said"), and having one silently displace the other loses the answer the operator
  # was reaching for.
  #
  # The explanation is BOUNDED and small — one row per flag already typed — so it is
  # allocated first and the grid takes whatever remains. Order on screen puts the grid
  # directly under tier 1, because the selection flows continuously from one into the
  # other; the explanation sits below both, as context rather than as a picker.
  local -i er=0
  if (( ${#_clicue_explain_rows} )); then
    er=${#_clicue_explain_rows}
    # Budgeted against the rows tier 1 will ACTUALLY draw, not against its
    # allocation: with no overflow r1 absorbs the grid's whole share, which starved
    # the explanation down to a single row and hid the rest of what was typed.
    local -i ecap=$(( maxlines - t1n - 5 ))
    (( ecap < 1 )) && ecap=1
    (( er > ecap )) && er=$ecap
  fi

  local -i gr=$(( r2 - er ))
  (( er > 0 )) && (( gr-- ))          # the explanation's own border
  (( gr < 0 )) && gr=0

  if (( total > t1n && gr > 0 )); then
    _clicue_emit_grid $(( t1n + 1 )) $total $gr $inner
  fi
  if (( er > 0 )); then
    _clicue_invocation_note
    _clicue_emit_explain $er $namew $inner "$_clicue_invnote"
  fi

  # Left-justified: it reads as a label on the box rather than as a right-aligned
  # afterthought, and it is the end that gets dropped when space runs out, so the
  # segments that survive stay in a stable position instead of sliding.
  _clicue_fit_hint $inner
  hint=$_clicue_hintfit
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
  local -a mv
  zstyle -a ':clicue:keys' maximize mv || mv=( '^[m' )
  _clicue_keylabel ${av[1]}; typeset -g _clicue_key_accept=$REPLY
  _clicue_keylabel ${dv[1]}; typeset -g _clicue_key_dismiss=$REPLY
  _clicue_keylabel ${mv[1]}; typeset -g _clicue_key_maximize=$REPLY
  # A sane full-width default, so anything that renders before the first
  # _clicue_hint_segments still has a legend.
  typeset -ga _clicue_hintparts=(
    "${_clicue_key_accept} cycle"
    "↑↓ browse"
    "→ accept"
    "⏎ insert"
    "${_clicue_key_dismiss} dismiss"
  )
}

# ── the legend, derived from what the keys will actually do right now ─────────
# Not a fixed string. A legend that lists gestures which do nothing is worse than a
# shorter one: the operator tries the gesture, nothing happens, and they stop
# trusting the card. That is design value 1 — no fallback may damage confidence —
# applied to the legend itself.
#
# Tab still has ONE rule: it advances your position in the candidate space. But that
# advance is a MOVE when there is somewhere to move and an INSERT when the highlighted
# cue is already the whole answer, and which of the two applies is knowable here. So
# the legend names it, which turns invisible state into a label rather than leaving
# the operator to infer it from a counter.
#
# One caveat, stated rather than hidden: the FIRST Tab in argument position also
# fetches from compsys, and fetching can change the answer. The legend describes the
# next press given what is known now, which is the most any legend can promise.
_clicue_hint_segments() {
  local acc=${_clicue_key_accept:-Tab}
  local dis=${_clicue_key_dismiss:-Esc}

  # Nothing to navigate: an informational card, or a card that is pure explanation
  # (a COMPLETE invocation is exactly the case with no candidate left to propose).
  # Both are worth reading and neither answers to an arrow.
  if (( ! ${#_clicue_cands} )) || \
     { (( _clicue_info )) && (( ! ${#_clicue_explain_rows} )) }; then
    _clicue_hintparts=( "${dis} dismiss" )
    return 0
  fi

  # Inside the grid the legend is a DIFFERENT legend, because the keys mean different
  # things there. `→ accept` was plainly wrong: _clicue_arrow_right tries the grid move
  # first, so in the grid Right navigates and never touches the ghost. All four arrows
  # navigate, and this is where paging earns its keys — the grid is clamped, so a long
  # list is pages deep and the operator needs to be told how to cross it.
  if (( _clicue_focus == 2 )); then
    local -a mxseg=()
    if (( _clicue_canmax || _clicue_maxed )); then
      local mxv=taller
      (( _clicue_maxed )) && mxv=shorter
      mxseg=( "${_clicue_key_maximize:-Alt+M} ${mxv}" )
    fi
    local -a pgseg=()
    # A single-page grid has no pages to turn, so it does not claim otherwise.
    (( _clicue_grid_page > 0 && ${#_clicue_cands} - _clicue_grid_lo + 1 > _clicue_grid_page )) \
      && pgseg=( "PgUp/PgDn page" )
    _clicue_hintparts=(
      "←→↑↓ navigate" $pgseg "Home/End ends" $mxseg "⏎ insert" "${dis} dismiss"
    )
    return 0
  fi

  # ── two gestures that do NOT work until the card is engaged ────────────────
  # The arrows and Enter both require _clicue_engaged, which only Tab sets. Before the
  # first Tab, ↑↓ reach command history and Enter RUNS THE LINE — both correct, and
  # both the opposite of what the legend was claiming.
  #
  # `⏎ insert` is the one that mattered enough to find this: advertising it on a card
  # the operator has not engaged invites them to press Enter expecting text to be
  # placed on the line, and execute the command instead. A legend that is merely inert
  # costs confidence; one that names the wrong outcome for a destructive key costs more
  # than that. Gated on the state the keys themselves test.
  local -a engaged_only=()
  (( _clicue_engaged )) && engaged_only=( "⏎ insert" )

  if _clicue_tab_inserts; then
    # The cue IS what is typed: nothing to cycle, nothing to browse, and no ghost to
    # accept. Tab and Enter do the same single thing here, and saying so beats
    # advertising four gestures of which three are inert.
    _clicue_hintparts=( "${acc} insert" $engaged_only "${dis} dismiss" )
    return 0
  fi

  _clicue_hintparts=( "${acc} cycle" )
  (( _clicue_engaged )) && (( ${#_clicue_cands} > 1 )) && _clicue_hintparts+=( "↑↓ browse" )
  _clicue_ghost_stem && _clicue_hintparts+=( "→ accept" )
  _clicue_hintparts+=( $engaged_only "${dis} dismiss" )
  return 0
}

# The stem the highlighted CUE would add to the line. Sets _clicue_cstem.
_clicue_cue_stem() {
  typeset -g _clicue_cstem=''
  (( ${#_clicue_cands} )) || return 1
  (( _clicue_info )) && return 1
  local pick=${_clicue_cands[_clicue_sel]}
  if [[ -n $_clicue_pfx && $pick == ${_clicue_pfx}* ]]; then
    _clicue_cstem=${pick#$_clicue_pfx}
  elif [[ -z $_clicue_pfx ]]; then
    _clicue_cstem=$pick
  fi
  [[ -n $_clicue_cstem ]]
}

# The rest of the most recent command line that starts with what is typed.
#
# This is the proposal zsh-autosuggestions used to make. clicue took the ghost away from
# it — correctly, by design value 0, since two writers for one purpose will fight — but
# took over only HALF of the job: it proposed the next token and never the rest of a
# remembered line. So "type a few characters, see the whole command from last time,
# press →" stopped working, and it was reported as a regression because it is one.
#
# Read from the in-memory `$history`, NOT from the corpus. The corpus is built from
# HISTFILE and is a snapshot; `$history` has the line run a minute ago in this very
# session. zsh orders `$history` most-recent-first, so the FIRST match is the newest —
# no scan and no sort.
#
# (b) quotes the buffer, or a line containing a glob character would turn the lookup
# into a pattern match against every other line in history.
_clicue_history_stem() {
  typeset -g _clicue_hstem=''
  [[ -n $LBUFFER ]] || return 1
  local m=${history[(r)${(b)LBUFFER}*]}
  [[ -n $m && $m != $LBUFFER ]] || return 1
  _clicue_hstem=${m#$LBUFFER}
  [[ -n $_clicue_hstem ]]
}

# What the ghost proposes, from whichever source has the best claim.
#
# ONE definition, two callers: clicue.zsh draws it, and the legend advertises `→ accept`
# only when there is something to accept. Duplicating the rule would let the legend
# disagree with the key.
#
# Precedence, and the reasoning for each:
#   1. A cue the operator is actively navigating. They are choosing it right now, so
#      nothing may override it — this is why the check is on _clicue_engaged.
#   2. The most recent matching history line. This is the muscle memory, and it is
#      usually more useful than one token: for `gi` it proposes `t status`, not `t`.
#   3. The top-ranked cue, when history has nothing. Keeps the ghost useful on a command
#      never run before.
_clicue_ghost_stem() {
  typeset -g _clicue_gstem=''
  if (( _clicue_engaged )) && _clicue_cue_stem; then
    _clicue_gstem=$_clicue_cstem; return 0
  fi
  if _clicue_history_stem; then
    _clicue_gstem=$_clicue_hstem; return 0
  fi
  if _clicue_cue_stem; then
    _clicue_gstem=$_clicue_cstem; return 0
  fi
  return 1
}

# Fit as many segments as the width allows. Always yields something: at absurd widths
# it falls back to the first segment truncated, never to an overflowing line.
#
# Segments are dropped from the MIDDLE, not simply from the right: the last one is
# always `dismiss`, and the escape hatch has to survive every width or a narrow
# terminal leaves the operator with a card and no advertised way out. So the first
# segment (the primary gesture) and the last (the way out) are the two that stay.
_clicue_fit_hint() {
  local -i avail=$1
  local try
  local -i n=${#_clicue_hintparts}
  local -i last=$n
  try=" ${(j: · :)_clicue_hintparts} "
  (( ${#try} <= avail )) && { _clicue_hintfit=$try; return 0 }
  # Assembled into a real array first. `${(j:x:)${a[1,n]} ${a[last]}}` is a bad
  # substitution — a join flag takes ONE parameter, not a list of words — and zsh
  # reports it at render time, i.e. as a card that fails to draw. [MEASURED]
  local -a keep
  for (( n = last - 1; n >= 1; n-- )); do
    keep=( "${(@)_clicue_hintparts[1,n]}" "${_clicue_hintparts[last]}" )
    try=" ${(j: · :)keep} "
    (( ${#try} <= avail )) && { _clicue_hintfit=$try; return 0 }
  done
  # Only the escape hatch fits, or not even that.
  try=" ${_clicue_hintparts[last]} "
  (( ${#try} <= avail )) && { _clicue_hintfit=$try; return 0 }
  _clicue_hintfit=" ${_clicue_hintparts[last][1,$(( avail > 2 ? avail - 2 : 1 ))]} "
  return 0
}
