#!/usr/bin/env zsh
# clicue — prototype presentation engine
#
# SCOPE: command position and argument position.
#
# Command position: typing the first word shows a card of matching
# commands/aliases/functions with glosses from the corpus, ranked by frequency
# derived from shell history.
#
# Argument position: the candidate-source adapter drives compsys for subcommands
# and flags WITH their real descriptions, and the second box stops browsing
# commands — it enumerates what is already on the line instead.
#
# Composability contract (SPEC.md design value 2):
#   - registers via add-zle-hook-widget; never zle -N a hook someone else owns
#   - tags region_highlight entries with memo=clicue
#   - PRESERVES any existing POSTDISPLAY (e.g. zsh-autosuggestions) and appends
#     below it rather than overwriting
#   - borrows exactly one :completion:* zstyle — list-grouped, for the duration of
#     one capture, restored in an `always` block. Nothing else is touched, and
#     nothing is left changed. (This line previously claimed none at all; the
#     borrow is documented at the capture site and in SPEC.md.)
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

# ── theme layer ──────────────────────────────────────────────────────────────
# Sourced before anything that renders. Colours AND box glyphs live in a theme
# file: a glyph the operator's font cannot draw looks like a malfunction, so the
# glyph set is a correctness concern and belongs where it can be changed.
source ${CLICUE_DIR}/lib/theme.zsh
source ${CLICUE_DIR}/lib/compsys.zsh
source ${CLICUE_DIR}/lib/candidates.zsh
source ${CLICUE_DIR}/lib/render.zsh
source ${CLICUE_DIR}/lib/keys.zsh
source ${CLICUE_DIR}/lib/corpus.zsh
source ${CLICUE_DIR}/lib/stats.zsh
_clicue_theme_init() {
  local want=aura
  zstyle -s ':clicue:*' theme want 2>/dev/null || want=aura
  _clicue_theme_load $want
}
_clicue_theme_init
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
typeset -g  _clicue_standdown=1   # clicue deliberately yielded this position
typeset -g  _clicue_cmdpath=''    # command path the cursor is inside
typeset -g  _clicue_optctx=0      # the line already carries an option token
typeset -g  _clicue_coldflags=0   # option typed, flag set not harvested yet
typeset -g  _clicue_lastbuf=$'\0'
typeset -ga _clicue_cands=()
# Candidate -> what to SHOW for it. The candidate stays the exact token that gets
# inserted; only the label differs, so `-d, --dir` can be one row without making
# the insertion ambiguous.
typeset -gA _clicue_disp=()
typeset -g  _clicue_orig_tab=''
typeset -g  _clicue_mode=cmd       # cmd | arg
typeset -g  _clicue_cmd=''         # in arg mode, the command being argued
typeset -g  _clicue_pfx=''         # the partial word being completed
typeset -g  _clicue_suppressed=0   # dismissed by the operator, this buffer only
typeset -g  _clicue_supbuf=''      # the buffer the dismissal applies to
typeset -g  _clicue_info=0         # card is informational, not a candidate list
typeset -g  _clicue_ghost=''       # stem of the highlighted cue, shown dim

# ── theme (Aura, from IRIS — see SPEC.md design language) ────────────────────


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
typeset -g  _clicue_cs_iprefix=''     # what compsys had already consumed
typeset -gA _clicue_cs_seen=()        # candidates compsys produced
typeset -gA _clicue_cs_sfx=()         # per-match suffix compsys declared


# ── how a match ends, as compsys itself declares it ──────────────────────────
# What follows an inserted match is per-match DATA, handed to us in the compadd
# call, not a decision to be re-derived:
#
#   -S ''      append nothing — the match clusters (tar's -A) or takes an
#              attached value
#   -S <str>   append that string, e.g. `=` for an option taking a value
#   no -S      the ordinary case: a trailing space
#
# Recording and replaying that is design value 5's "show what they decided". It is
# NOT the same as modelling where the current word begins, which is what went wrong
# with IPREFIX.
#
# A second unshadowed completion pass was tried first and rejected on measurement.
# Handing the line back to compsys does fix `--file=`, but placing the candidate
# MOVES THE COMPLETION POSITION: with `-A` on the line, compsys stops offering
# `-A` and starts offering the next cluster letter, so `tar -` inserted `tar -Af`
# and `rm -` inserted `rm -df`. Capturing the suffix at the position where the
# candidate was actually valid has no such failure mode.


typeset -gA _clicue_flag_desc=()     # cmd|flag  -> description
typeset -gA _clicue_flag_alt=()      # cmd|flag  -> the other spelling
typeset -gA _clicue_flag_have=()     # cmd       -> 1 once loaded or harvested

zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/datetime 2>/dev/null

# A plain global, NOT a function invoked through $( ). _clicue_flag_load runs on
# every keystroke in flag position, and a command substitution there is a fork per
# keystroke — the same mistake that once put render latency at 87ms.
typeset -g _clicue_flagdir="${XDG_CACHE_HOME:-$HOME/.cache}/clicue/flags"


# Stamp is the command's own mtime. A rebuilt binary may document new flags; an
# unchanged one cannot, so there is nothing to re-fetch.
# Sets _clicue_fstamp rather than printing: same fork argument as above.
# Bumped whenever the cache LAYOUT changes. The mtime stamp only catches a changed
# binary; it cannot notice that clicue started writing a fourth field.
typeset -g _clicue_flag_fmt=2


# ── the card ─────────────────────────────────────────────────────────────────
# Two groups, one selection. Tier 1 (nearest the prompt) is what this operator
# actually invokes — it has history frequency. Tier 2 is everything else on the
# system. Alt+Down flows out of the bottom of tier 1 straight into tier 2, so
# there is no mode to switch and no second keybinding to learn.
typeset -ga _clicue_lines=()
typeset -ga _clicue_gridrows=()    # indices into _clicue_lines that are grid rows
typeset -ga _clicue_explain_rows=()  # "label\tdescription" for the typed line
typeset -ga _clicue_explainrows=()   # indices into _clicue_lines that are explain rows
# Line index -> how many leading characters of that row's name the operator has typed.
# An ASSOCIATION, not an array: with a plain array a sparse integer index fills the
# gaps with empty strings, so ${+arr[n]} reports true for every index up to the
# highest one set — which would emphasise the prefix on rows that do not match it.
typeset -gA _clicue_matchlen=()
typeset -g  _clicue_footrow=0        # index of the invocation-stats footer, if any
typeset -g  _clicue_expanded=0       # operator asked for the full explanation
typeset -g  _clicue_expcmd=''        # command the expansion applies to
typeset -ga _clicue_words=()         # the current segment, split into words
typeset -g  _clicue_selline=0      # line index holding the selected grid cell
typeset -g  _clicue_selcol=0       # char offset of that cell within the line
typeset -g  _clicue_selw=0         # its width
typeset -g  _clicue_top1=1
typeset -g  _clicue_top2=0
typeset -g  _clicue_focus=1        # 1 = tier 1 list, 2 = tier 2 grid (a MODE)
typeset -g  _clicue_gridtop=0      # first index shown in the grid page
typeset -g  _clicue_grid_rows=1    # rows in the current grid, for 2D nav
typeset -g  _clicue_grid_cols=1


_clicue_pre_redraw() {
  # Set until clicue commits to owning this line, so every early return below
  # leaves it set. Tab consults it: a deliberate yield (a path, a prefix too
  # short, a menuselect keymap) delegates instantly, but merely having no
  # candidates YET must not — that is what dumped zsh's raw listing on screen.
  _clicue_standdown=1
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
  _clicue_words=( $words )
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
    # The command PATH the cursor sits in: `gh org list` is a different place from
    # `gh`, and its options are different. Built from the non-flag tokens BEFORE the
    # one being typed — a flag never changes what the next token means, a subcommand
    # always does.
    _clicue_cmdpath=${words[1]}
    local _pw
    local -i _pi
    for (( _pi = 2; _pi < ${#words} + trailing; _pi++ )); do
      _pw=${words[_pi]}
      [[ -n $_pw && $_pw != -* ]] && _clicue_cmdpath="${_clicue_cmdpath}:${_pw}"
    done
    # is the operator already composing options?
    _clicue_optctx=0
    local _ow
    for _ow in ${words[2,-1]}; do
      [[ $_ow == -* ]] && { _clicue_optctx=1; break }
    done
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
      # A LEADING DASH IS NEVER A FILENAME.
      #
      # This rule used to yield whenever the corpus knew no arguments for the
      # command, which is true of every path-centric command — `rm` is on that
      # denylist precisely so it records no arguments. So `rm -<Tab>` stood down
      # and Tab handed off to zsh, which printed its own listing raw: the card
      # vanished and the flags appeared in a completely different visual language.
      #
      # Options are the one thing this tool exists to explain, and they cannot be
      # confused with a path. Keep them. Yield only when the token could be a
      # filename, which is what the denylist was actually for.
      if [[ $_clicue_pfx != -* ]]; then
        [[ -n $_clicue_pfx ]] && return 0
        # Empty prefix — a space was just typed. If the line ALREADY carries an
        # option, the operator is composing options and the useful move is to
        # offer the rest of them: mixing -p with --some-other-thing is normal, and
        # inserting one long parameter used to dead-end the card here.
        #
        # On a bare `cmd ` with no options yet, they are far more likely to be
        # naming a file, so that still yields to compsys.
        if (( _clicue_optctx )) && _clicue_flag_load $_clicue_cmd 2>/dev/null; then
          :
        else
          _clicue_info=1
        fi
      fi
    fi
  fi

  # a changed buffer invalidates any selection the operator had made
  [[ $buf != $_clicue_lastbuf ]] && { _clicue_lastbuf=$buf; _clicue_reset_sel }
  # a different command means the harvest no longer applies
  [[ $_clicue_mode == cmd ]] && { _clicue_cs_words=(); _clicue_cs_gloss=(); _clicue_cs_for=$'\0' }
  # the expansion is sticky per invocation, not for ever
  [[ $_clicue_cmd != $_clicue_expcmd ]] && { _clicue_expcmd=$_clicue_cmd; _clicue_expanded=0 }

  _clicue_standdown=0
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
  # The rule for WHAT the stem is lives in _clicue_ghost_stem, because the card's
  # legend advertises `→ accept` only when a stem exists. Two copies of the rule
  # would eventually disagree, and then the legend lies about the key.
  local ghost=''
  if _clicue_ghost_stem; then
    ghost=$_clicue_gstem
    POSTDISPLAY=''                      # our cue supersedes the autosuggestion
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

# Corpus maintenance, at the prompt rather than at a keystroke.
#
# Deliberately NOT in _clicue_first_precmd: the corpus loads lazily, so on the first
# prompt of a shell nothing has read it yet and staleness is not yet known. This runs
# on every prompt but returns immediately unless the cache was found stale, and the
# rebuild itself fires at most once per shell.
_clicue_maintenance_precmd() {
  (( _clicue_loaded )) || return 0
  _clicue_corpus_refresh
  return 0
}
add-zsh-hook precmd _clicue_maintenance_precmd
add-zsh-hook precmd _clicue_first_precmd

add-zle-hook-widget line-pre-redraw _clicue_pre_redraw
add-zle-hook-widget line-finish     _clicue_line_finish
