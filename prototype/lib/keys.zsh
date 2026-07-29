#!/usr/bin/env zsh
# clicue — widgets and bindings
#
# Every key is configuration (zstyle ':clicue:keys' <action> <seq>...), and two
# bindings are refused outright with a message on stderr:
#
#   unmodified Up/Down  — those always walk command history. That is the operator's
#                         muscle memory and it predates this tool.
#   any bare printable  — binding `q` as an alternate dismiss would break every
#                         command containing a q, and typing IS how the operator
#                         narrows a card.
#
# Arrows and Enter are taken only WHILE a card is being navigated and delegate to
# whatever owned them otherwise, so nothing is swallowed. Enter, when navigating,
# means "put this on the line" — never "run it". Choosing from a card is composition,
# not execution.
#
# Loaded LAST: bindings read their zstyles at source time, and every widget must
# exist before it is registered.

# ── hook ─────────────────────────────────────────────────────────────────────
_clicue_reset_sel() {
  _clicue_sel=1; _clicue_top1=1; _clicue_top2=0; _clicue_engaged=0
  _clicue_focus=1; _clicue_gridtop=0
}

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
      dismiss     _clicue_dismiss \
      expand      _clicue_expand
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
        expand)      seqs=( '^[e' ) ;;
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

# Open a collapsed explanation. Sticky for the rest of the line: an operator who
# asked for the detail once should not have to keep asking as they keep typing.
_clicue_expand() {
  _clicue_expanded=$(( ! _clicue_expanded ))
  zle -R
  return 0
}

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
  # Did THIS press do the harvesting? If so it must not also advance the
  # selection: the harvest already lands on cue 1, and incrementing on top of that
  # made the first Tab skip the top-ranked cue. Pre-zeroing the selection instead
  # does not work — _clicue_render clamps it back to 1 on the way past.
  local -i just_harvested=0

  # Stood down? Delegate IMMEDIATELY, before any harvest.
  #
  # This is what made `cd pro<Tab>` need a second Tab. _clicue_pre_redraw sets
  # _clicue_mode=arg before it decides whether to show a card, so Tab reached the
  # harvest branch below even for path-like input where clicue has no intention of
  # rendering anything — the first press forked compsys for data that would never
  # be displayed, consumed the keystroke, and left the operator to press Tab
  # again for the completion they asked for the first time. Forking to populate a
  # card that is not on screen is work with no reader.
  if (( _clicue_standdown )); then
    zle ${_clicue_orig_tab:-expand-or-complete}
    return 0
  fi

  # In argument position, Tab is where the expensive engine earns its keep:
  # compsys forks (git branch, docker ps) so it cannot run per keystroke, but on
  # demand it yields the authoritative flag/subcommand set WITH real descriptions.
  # Cached per buffer so repeated Tab presses do not re-fork.
  #
  # The harvest does NOT consume the press. It used to `return 0` here, so the
  # first Tab fetched and the second one moved: one press, no visible effect.
  # Now it falls through into the cycle below, so a single Tab both fetches and
  # lands on the first cue — which is what "Tab cycles the primary card" already
  # promised.
  if [[ $_clicue_mode == arg && $_clicue_cs_for != $LBUFFER ]]; then
    _clicue_cs_for=$LBUFFER
    zle _clicue_capture 2>/dev/null
    _clicue_cs_build_gloss
    # Learn the command's documented flag set too. This is what lets the second
    # box explain `-lat`. It forks at most once per command ever — the result is
    # cached on disk against the binary's mtime.
    # Every ANCESTOR path, not just the current one.
    #
    # The current path is what composition needs; the ancestors are what comprehension
    # needs. `gh org list --limit 10` cannot explain `org` from `gh org list`'s option
    # set — `org` is documented one level up. Harvesting only the deepest path left the
    # earlier tokens permanently unexplained.
    #
    # Costs one fork per level, once per path per binary version, and each is cached.
    # Depth is small in practice: three levels is a lot for a CLI.
    if [[ -n ${_clicue_cmdpath:-$_clicue_cmd} ]]; then
      local -a _hp=( ${(s.:.)${_clicue_cmdpath:-$_clicue_cmd}} )
      local _acc=''
      local _seg
      for _seg in $_hp; do
        _acc=${_acc:+${_acc}:}${_seg}
        _clicue_harvest_flags $_acc
      done
    fi
    if [[ -n $CLICUE_DEBUG ]]; then
      print -r -- "  COMPSYS words=${#_clicue_cs_words} descs=${#_clicue_cs_descs} glossed=${#_clicue_cs_gloss}" >> $CLICUE_DEBUG
      local _dn
      for _dn in ${${(k)_clicue_cs_gloss}[1,3]}; do
        print -r -- "    $_dn -> ${_clicue_cs_gloss[$_dn]}" >> $CLICUE_DEBUG
      done
    fi
    # The harvest changes the candidate set, so any prior selection is stale.
    _clicue_reset_sel
    just_harvested=1
    # A harvest that found something turns an informational card into a real one.
    # Leaving _clicue_info set would skip the cycle branch below and fall through
    # to native completion — which is exactly the raw listing this is replacing.
    (( ${#_clicue_cs_words} )) && _clicue_info=0
    # rebuild the card against the enlarged set before the selection lands on it
    if _clicue_render "$_clicue_pfx" 2>/dev/null; then
      _clicue_visible=1
    fi
  fi

  # A token that is ALREADY the whole answer: accept it and move on, rather than
  # cycling a one-item list.
  #
  # Reported for gh, and it is the shape of every nested CLI. `gh org<Tab>` offers
  # exactly one candidate — `org`, which is what is already typed — so cycling did
  # nothing visible and there was no way forward, even though `gh org ` has
  # subcommands waiting. Same for `gh<Tab>` when gh is the only command by that name.
  # Accepting inserts the token's declared suffix (usually a space), and the next
  # redraw shows the level below. This is what zsh's own completion does with
  # accept-exact, and the operator reasonably expects it.
  if (( _clicue_visible && ! _clicue_info )) && (( ${#_clicue_cands} == 1 )) \
     && [[ -n $_clicue_pfx && ${_clicue_cands[1]} == $_clicue_pfx ]]; then
    _clicue_sel=1
    _clicue_engaged=1
    _clicue_insert
    return 0
  fi

  if (( _clicue_visible && ! _clicue_info )) && (( ${#_clicue_cands} )); then
    _clicue_engaged=1
    local -i lim=${_clicue_t1n:-0}
    (( lim < 1 || lim > ${#_clicue_cands} )) && lim=${#_clicue_cands}
    (( just_harvested )) || (( _clicue_sel++ ))
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
    _clicue_reset_sel
    _clicue_clear

    # What follows the match is compsys's declaration, not our guess.
    local tail=' '
    if (( ${+_clicue_cs_sfx[$pick]} )); then
      tail=${_clicue_cs_sfx[$pick]}
      [[ $tail == $'\0' ]] && tail=''
    fi
    if [[ -n $_clicue_pfx ]]; then
      LBUFFER="${LBUFFER%$_clicue_pfx}${pick}${tail}"
    else
      LBUFFER="${LBUFFER}${pick}${tail}"
    fi
    zle -R
    return 0
  fi
  zle ${_clicue_orig_enter:-.accept-line}
}

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

_clicue_arrow_down()  { _clicue_move  1     || zle ${_clicue_arrow_orig[B]:-.down-line-or-history} }

_clicue_arrow_up()    { _clicue_move -1     || zle ${_clicue_arrow_orig[A]:-.up-line-or-history} }

_clicue_arrow_right() {
  _clicue_grid_move right && return          # inside the grid: jump a column
  _clicue_accept_ghost    && return          # at end of line: take the proposal
  zle ${_clicue_arrow_orig[C]:-.forward-char}
}

_clicue_arrow_left()  { _clicue_grid_move left  || zle ${_clicue_arrow_orig[D]:-.backward-char} }

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

# ── registration ─────────────────────────────────────────────────────────────
# Beside the widgets they name. `zle -N` accepts a name whose function does not
# exist and fails silently at load, surfacing only as `no such shell function` on a
# keypress — that regression happened twice, so the registration and the definition
# stay in one file.
typeset -gA _clicue_arrow_orig=()

zle -N _clicue_insert
zle -N _clicue_scroll_down
zle -N _clicue_scroll_up
zle -N _clicue_accept
zle -N _clicue_dismiss
zle -N _clicue_expand
zle -N _clicue_end_of_line
zle -N _clicue_arrow_down
zle -N _clicue_arrow_up
zle -N _clicue_arrow_right
zle -N _clicue_arrow_left

# Whatever owned Tab before us, so delegation puts it back rather than guessing.
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
