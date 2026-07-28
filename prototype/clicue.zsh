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
  # Declared unconditionally, BEFORE the cache is read. A corpus built by an
  # older version simply will not define the newer maps, and an undefined
  # association read with a subscript is an error, not an empty string — so the
  # card would break on a stale cache rather than degrade.
  typeset -gA CLICUE_GLOSS CLICUE_KIND CLICUE_FREQ CLICUE_ARGS CLICUE_ARGN \
              CLICUE_INVOKE CLICUE_INVOKE_PCT CLICUE_INVOKE_LAST
  [[ -r $CLICUE_CACHE ]] || return 1
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
  # NOTE: the grouped flag set is resolved BEFORE the raw compsys words below.
  # Order matters. A fresh harvest fills both, and whichever runs first claims the
  # row — with compsys first, `man -` showed 74 ungrouped rows on the first Tab and
  # 39 grouped ones in every later shell, for identical input. Same data, two
  # different cards, decided by cache warmth.

  # The flag set, when the operator is typing an option. This is what lets
  # the card have content in flag position WITHOUT a fork: reading the cache is
  # cheap enough for a keystroke, and the first Tab for a command is what fills it.
  # Without this the card would be empty until Tab, and an empty card is how
  # zsh's raw listing got on screen in the first place.
  if [[ $pfx == -* ]] || (( _clicue_optctx )); then
    _clicue_flag_load $cmd 2>/dev/null
    # ALL declared here, outside the loop. Re-declaring a set `local` inside a loop
    # body prints its value — `sp=--help` and friends leaked straight onto the
    # terminal. Third time this exact gotcha has bitten this file.
    local fk alt canon sp
    # Sorted so the SHORT spelling of a pair is met first and becomes the row.
    for fk in ${(ko)_clicue_flag_desc}; do
      [[ $fk == ${cmd}\|* ]] || continue
      n=${fk#*\|}
      (( ${+seen[$n]} )) && continue
      # One row per FLAG, not per spelling. `-d` and `--dir` describing the same
      # thing were two rows saying the same sentence twice, which is what the
      # description-pairing was for in the first place. The short form is the
      # candidate — it is what the operator is typing — and the long form rides
      # along in the label.
      [[ -n $pfx && $n != ${pfx}* ]] && continue
      _clicue_fkey $cmd $n
      alt=${_clicue_flag_alt[$_clicue_fk]}
      if [[ -z $alt ]]; then
        seen[$n]=1; rest+=( $n ); continue
      fi
      # One row for the whole group. The row is keyed on the spelling that gets
      # inserted, and every other spelling is marked seen so it cannot also appear
      # on its own row.
      _clicue_flag_canon $cmd $n
      canon=$_clicue_fc
      # when a prefix is being typed, honour it over the canonical short form —
      # typing `--rec` must not silently insert `-r`
      [[ -n $pfx && $canon != ${pfx}* ]] && canon=$n
      (( ${+seen[$canon]} )) && continue
      seen[$n]=1; seen[$canon]=1
      for sp in ${=alt}; do seen[$sp]=1; done
      _clicue_flag_label $cmd $n
      _clicue_disp[$canon]=$_clicue_fl
      rest+=( $canon )
    done
  fi

  # Everything else compsys offered: subcommands, values, anything that is not a
  # documented option and therefore has no spellings to group.
  #
  # Filtered against the prefix COMPSYS was matching, not the operator's whole
  # token. compadd -O already stores only matches, so this filter exists purely to
  # catch a harvest that has gone stale as the operator keeps typing — and it must
  # subtract whatever compsys consumed, or a dash-consuming completer loses every
  # candidate it offered.
  local rel=$pfx
  if [[ -n $_clicue_cs_iprefix && $pfx == ${_clicue_cs_iprefix}* ]]; then
    rel=${pfx#$_clicue_cs_iprefix}
  fi
  for n in $_clicue_cs_words; do
    # filter on what compsys matched, THEN normalise
    [[ -n $rel && $n != ${rel}* ]] && continue
    [[ $n != -* && $_clicue_cs_iprefix == -* ]] && n="${_clicue_cs_iprefix}${n}"
    (( ${+seen[$n]} )) && continue
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
typeset -g  _clicue_cs_iprefix=''     # what compsys had already consumed
typeset -gA _clicue_cs_seen=()        # candidates compsys produced
typeset -gA _clicue_cs_sfx=()         # per-match suffix compsys declared

_clicue_capture_fn() {
  compstate[insert]=''
  compstate[list]=''
  _clicue_cs_words=(); _clicue_cs_descs=(); _clicue_cs_seen=(); _clicue_cs_sfx=()

  compadd() {
    # What compsys treats as ALREADY on the line. Candidates are relative to this:
    # `_tar` consumes the leading dash into IPREFIX and completes bare letters
    # (`A`, `c`, `x`), while `_man` leaves the dash in PREFIX and completes whole
    # tokens (`-a`, `--all`). Without recording it, tar's 14 candidates were all
    # discarded for not starting with a dash — and Tab fell through to zsh, which
    # inserted `A` and opened its own menu. [MEASURED]
    _clicue_cs_iprefix=$IPREFIX
    local -a w dsp
    local -i i
    local a dv probe='' sfx='' hassfx=''
    # Scan the options for two things: the -d display array, and whether the
    # CALLER already supplied -O/-A of its own.
    for (( i = 1; i <= $#; i++ )); do
      a=${@[i]}
      # words follow the separator; stop before a candidate that merely LOOKS
      # like an option (completing `-ld` would otherwise read as `-d`)
      [[ $a == - || $a == -- ]] && break
      [[ $a == -?* && $a != --* ]] || continue
      case ${a[-1]} in
        # -d takes the next word as its argument, so it is necessarily last in
        # its cluster. It arrives clustered in practice: compdescribe emits
        # `-ld`, which an exact `== -d` test silently never matches. [MEASURED]
        (d) if [[ -z $dv ]]; then
              dv=${@[i+1]}
              if [[ -n ${(P)dv+x} ]]; then
                dsp=( "${(@P)dv}" )
              else
                dsp=( ${=${${dv#\(}%\)}} )   # literal (a b c) form
              fi
            fi ;;
        # A caller-supplied -O/-A means this call is the completer talking to
        # ITSELF — a "does anything match / how wide is the longest" probe, not
        # a presentation. Two -O arrays do not both fill: the FIRST wins
        # [MEASURED], so passing ours would silently steal theirs. _git computes
        # its description column width from exactly such an array, so stealing
        # it corrupts the layout of the descriptions we are trying to read.
        # Leave the call untouched and harvest nothing; the same words come back
        # described in the grouped calls that follow.
        (O|A) probe=1 ;;
        # -S takes an argument, so it is last in its cluster; it may also arrive
        # with the value attached, as -S=
        (S) hassfx=1; sfx=${@[i+1]} ;;
      esac
      [[ $a == -[A-Za-z]#S?* && $a != --* ]] && { hassfx=1; sfx=${a#*S} }
    done

    if [[ -n $probe ]]; then
      [[ -n $CLICUE_DEBUG ]] && print -r -- "    compadd PROBE (caller -O/-A) skipped" >> $CLICUE_DEBUG
      builtin compadd "$@" 2>/dev/null
      return $?
    fi

    local -i pre=${#dsp}
    builtin compadd -O w -D dsp "$@" 2>/dev/null
    # Per-call, because a description gap is only ever visible HERE: by the time
    # the card renders, an unaligned group is indistinguishable from one the
    # completer simply never described.
    [[ -n $CLICUE_DEBUG ]] && \
      print -r -- "    compadd d=${dv:-none} dsp:${pre}->${#dsp} words=${#w}" >> $CLICUE_DEBUG
    (( ${#w} )) || return 1
    _clicue_cs_words+=( $w )
    for a in $w; do
      _clicue_cs_seen[$a]=1
      # \0 records "compsys gave -S with an empty value" — distinct from "no -S at
      # all", which is the ordinary trailing-space case. An empty string cannot
      # carry that distinction in an association.
      (( hassfx )) && _clicue_cs_sfx[$a]=${sfx:-$'\0'}
      # also under the normalised spelling, since that is what the card offers
      if [[ $a != -* && $_clicue_cs_iprefix == -* ]]; then
        _clicue_cs_seen[${_clicue_cs_iprefix}${a}]=1
        (( hassfx )) && _clicue_cs_sfx[${_clicue_cs_iprefix}${a}]=${sfx:-$'\0'}
      fi
    done
    if (( ${#dsp} == ${#w} )); then
      _clicue_cs_descs+=( $dsp )
    else
      # one placeholder PER WORD. Padding to width N yields a single N-char
      # string, so this must split on the empty separator, not on spaces —
      # splitting on spaces returned one blob and misaligned every group after
      # an undescribed one. [MEASURED]
      _clicue_cs_descs+=( ${(s::)${(l:${#w}::@:):-}} )
    fi
    return 0
  }

  # list-grouped is what decides whether a description survives to compadd.
  #
  # With it ON (compsys's default), `_describe -O option` routes long options
  # through compdescribe's grouped path: each option becomes its own single-match
  # group, its description moves out of the -d display array, and every option is
  # emitted TWICE — once bare in the pre-pass, once per group. `curl -` measured
  # 664 words and ZERO descriptions that way. With it off: 332 words, 331
  # described. `docker ` goes from 120 words / 60 described to 60 / 60.
  # [MEASURED]
  #
  # Set for the duration of THIS call only and restored in an `always` block, so
  # a completer that errors out cannot leave the operator's normal Tab menu
  # quietly regrouped — an invisible change to a live surface is exactly what
  # design value 1 forbids. zstyle is compsys's own configuration API, so this
  # is configuring a willing mechanism, not reaching into one.
  #
  # It cannot be scoped by context instead: during capture curcontext is
  # `:complete:<cmd>:<tag>` — the widget field is empty, so there is no pattern
  # that selects clicue's call and not the operator's. [MEASURED]
  local -a _clicue_lg
  local -i _clicue_lg_had=0
  zstyle -g _clicue_lg ':completion:*' list-grouped 2>/dev/null && _clicue_lg_had=1
  zstyle ':completion:*' list-grouped false
  {
    _main_complete
  } always {
    if (( _clicue_lg_had )); then
      zstyle ':completion:*' list-grouped "${_clicue_lg[@]}"
    else
      zstyle -d ':completion:*' list-grouped
    fi
  }
  unfunction compadd 2>/dev/null
  return 0
}

zle -C _clicue_capture list-choices _clicue_capture_fn

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

# Strip compdescribe's packed display prefix. It formats each display string as
# "<word><padding>-- <description>" so the list lines up in COMPSYS's single
# column; clicue renders name and gloss as separate columns, so the prefix has to
# come off or every row shows its name twice.
_clicue_unpack_desc() {
  setopt localoptions extended_glob
  local w=$1 d=$2 sep
  zstyle -s ':completion:*:*' list-separator sep || sep='--'
  if [[ $d == ${w}* ]]; then
    d=${d#$w}
    d=${d##[[:space:]]#}
    [[ $d == ${sep}(|[[:space:]]*) ]] && d=${d#$sep}
    d=${d##[[:space:]]#}
  fi
  _clicue_ud=${d%%[[:space:]]#}
}

# ── flag intelligence ────────────────────────────────────────────────────────
# What a flag MEANS is more useful than how often it was used. The count is still
# shown, but it trails the description rather than replacing it.
#
# Two facts make this constructible from compsys alone:
#
#   1. Driving `<cmd> -` yields the documented flag set with descriptions.
#   2. A short flag and its long spelling carry the IDENTICAL description, so
#      they can be paired by grouping on description text. [MEASURED]
#        rm -   17 words, 17 described, 4 descriptions shared -> `-f, --force`
#        ps -   62/62, 17 shared -> `-V, --version`
#        ls -   98 words, 81 described, 57 distinct, 24 shared
#
# Harvesting forks, so it cannot run per keystroke. It runs on demand and the
# result is cached on disk: a command's documented flag set does not change until
# the binary does, which is what the stamp check covers.
# Composite keys are built in a VARIABLE, never written inline as
# assoc[${cmd}|${flag}]. An unescaped `|` in a subscript does not store under the
# key it appears to — the write lands somewhere the read never looks, silently,
# and the map simply stays empty. That cost a debugging pass here; the corpus code
# escapes it as \| for the same reason.
_clicue_fkey() { _clicue_fk="${1}|${2}" }

typeset -gA _clicue_flag_desc=()     # cmd|flag  -> description
typeset -gA _clicue_flag_alt=()      # cmd|flag  -> the other spelling
typeset -gA _clicue_flag_have=()     # cmd       -> 1 once loaded or harvested

zmodload -F zsh/stat b:zstat 2>/dev/null
zmodload zsh/datetime 2>/dev/null

# A plain global, NOT a function invoked through $( ). _clicue_flag_load runs on
# every keystroke in flag position, and a command substitution there is a fork per
# keystroke — the same mistake that once put render latency at 87ms.
typeset -g _clicue_flagdir="${XDG_CACHE_HOME:-$HOME/.cache}/clicue/flags"

# How often the operator has actually run THIS invocation, and how recently.
# Their own habits are the one thing no manual page knows, and it is the input
# the familiarity gate needs.
# Sets _clicue_invnote. Called from render, so it must not fork.
_clicue_invocation_note() {
  local key="${(j: :)_clicue_words}"
  _clicue_invnote=''
  local n=${CLICUE_INVOKE[$key]:-}
  [[ -z $n ]] && return 0
  local out="run ${n}×"
  local pct=${CLICUE_INVOKE_PCT[$key]:-}
  [[ -n $pct ]] && out+="  ·  top ${pct}% of your invocations"
  local last=${CLICUE_INVOKE_LAST[$key]:-}
  if [[ -n $last && $last != 0 && -n $EPOCHSECONDS ]]; then
    local -i days=$(( (EPOCHSECONDS - last) / 86400 ))
    if (( days <= 0 )); then out+="  ·  today"
    elif (( days == 1 )); then out+="  ·  yesterday"
    else out+="  ·  ${days}d ago"
    fi
  fi
  _clicue_invnote=$out
}

# Is this invocation one the operator demonstrably knows by heart?
# Off by default: a verbosity change the operator did not ask for is precisely the
# invisible behaviour shift design value 1 forbids.
_clicue_is_familiar() {
  local -i thresh=0
  zstyle -s ':clicue:*' familiar-percentile thresh 2>/dev/null || thresh=0
  (( thresh > 0 )) || return 1
  local key="${(j: :)_clicue_words}"
  local pct=${CLICUE_INVOKE_PCT[$key]:-}
  [[ -n $pct ]] || return 1
  (( pct <= thresh ))
}

# Stamp is the command's own mtime. A rebuilt binary may document new flags; an
# unchanged one cannot, so there is nothing to re-fetch.
# Sets _clicue_fstamp rather than printing: same fork argument as above.
# Bumped whenever the cache LAYOUT changes. The mtime stamp only catches a changed
# binary; it cannot notice that clicue started writing a fourth field.
typeset -g _clicue_flag_fmt=2

_clicue_flag_stamp() {
  local p=${commands[$1]}
  local -a st
  if [[ -n $p && -e $p ]]; then
    if zstat -A st +mtime $p 2>/dev/null; then
      _clicue_fstamp=${st[1]}
    else
      _clicue_fstamp=0
    fi
  else
    _clicue_fstamp='builtin'
  fi
  _clicue_fstamp="v${_clicue_flag_fmt}:${_clicue_fstamp}"
}

_clicue_flag_load() {
  local cmd=$1
  (( ${+_clicue_flag_have[$cmd]} )) && return 0
  local f=$_clicue_flagdir/${cmd}.zsh
  [[ -r $f ]] || return 1
  local -a lines=( ${(f)"$(<$f)"} )
  # line 1 is the stamp; a mismatch means the binary moved on
  _clicue_flag_stamp $cmd
  [[ ${lines[1]} == $_clicue_fstamp ]] || return 1
  local l flag alt desc sfx
  for l in ${lines[2,-1]}; do
    flag=${l%%$'\t'*}; l=${l#*$'\t'}
    alt=${l%%$'\t'*}; l=${l#*$'\t'}
    sfx=${l%%$'\t'*}; desc=${l#*$'\t'}
    [[ -z $flag ]] && continue
    _clicue_fkey $cmd $flag
    _clicue_flag_desc[$_clicue_fk]=$desc
    [[ -n $alt ]] && _clicue_flag_alt[$_clicue_fk]=$alt
    # `-` means "no -S was given"; `_` means "-S with an empty value". Both have to
    # survive the round trip, because they mean opposite things at insertion.
    case $sfx in
      (-) ;;
      (_) _clicue_cs_sfx[$flag]=$'\0' ;;
      (*) _clicue_cs_sfx[$flag]=$sfx ;;
    esac
  done
  _clicue_flag_have[$cmd]=1
  return 0
}

_clicue_flag_save() {
  local cmd=$1
  mkdir -p $_clicue_flagdir 2>/dev/null || return 1
  local f=$_clicue_flagdir/${cmd}.zsh
  _clicue_flag_stamp $cmd
  {
    print -r -- "$_clicue_fstamp"
    local k flag sfx
    for k in ${(k)_clicue_flag_desc}; do
      [[ $k == ${cmd}\|* ]] || continue
      flag=${k#*\|}
      # REAL tabs, via $'\t'. `print -r` does not expand escapes, so writing "\t"
      # here stored the two characters backslash-t; the loader splits on an actual
      # tab, so every field came back merged. A cache that reloads as garbage is
      # worse than no cache — it would put wrong descriptions on right flags.
      if (( ${+_clicue_cs_sfx[$flag]} )); then
        sfx=${_clicue_cs_sfx[$flag]}
        [[ $sfx == $'\0' ]] && sfx='_'
      else
        sfx='-'
      fi
      print -r -- "${flag}"$'\t'"${_clicue_flag_alt[$k]}"$'\t'"${sfx}"$'\t'"${_clicue_flag_desc[$k]}"
    done
  } >! $f.$$ 2>/dev/null && mv -f $f.$$ $f 2>/dev/null
  return 0
}

# Harvest `<cmd> -` by synthesising that line, then putting the operator's line
# back. No redraw happens in between — zle -R is not called — so the substitution
# is never visible. Deliberate and on demand: the alternative is guessing what a
# flag means, and a wrong gloss is worse than none.
_clicue_harvest_flags() {
  local cmd=$1
  (( ${+_clicue_flag_have[$cmd]} )) && return 0
  _clicue_flag_load $cmd && return 0
  _clicue_flag_have[$cmd]=1        # set first: one attempt per command per shell

  local sbuf=$BUFFER
  local -i scur=$CURSOR
  local -a swords=( $_clicue_cs_words ) sdescs=( $_clicue_cs_descs )
  local sfor=$_clicue_cs_for

  BUFFER="$cmd -"; CURSOR=${#BUFFER}
  {
    zle _clicue_capture 2>/dev/null
  } always {
    BUFFER=$sbuf; CURSOR=$scur
  }

  local -A byd=()
  local -i i
  local w d raw
  for (( i = 1; i <= ${#_clicue_cs_words}; i++ )); do
    raw=${_clicue_cs_words[i]}
    w=$raw
    # Put back whatever compsys consumed, so a bare `A` from `tar -` is stored as
    # the flag it actually is. Without this, tar's cache stayed permanently empty
    # and the card never got past "press Tab to load".
    [[ $w != -* && $_clicue_cs_iprefix == -* ]] && w="${_clicue_cs_iprefix}${w}"
    [[ $w == -* ]] || continue
    # unpacked against the ORIGINAL word: compdescribe packed the display string
    # around `A`, not around `-A`, so stripping by the normalised name left the
    # whole `A  -- append to an archive` sitting in the gloss column
    _clicue_unpack_desc $raw "${_clicue_cs_descs[i]}"
    d=$_clicue_ud
    [[ -z $d || $d == '@' ]] && continue
    _clicue_fkey $cmd $w
    _clicue_flag_desc[$_clicue_fk]=$d
    byd[$d]+="$w "
  done

  # Spellings sharing a description are the same option. Not restricted to pairs:
  # `-r`, `-R` and `--recursive` all mean one thing in rm, and showing three rows
  # of the same sentence is worse than showing one row naming all three. Options
  # are not consistent across commands, so take whatever spellings exist.
  #
  # Capped at three, which is the difference between "variant spellings" and "a
  # generic description". `display help information` is shared by unrelated flags
  # in some completers, and grouping those WOULD be a guess.
  local -a names
  for d in ${(k)byd}; do
    names=( ${=byd[$d]} )
    (( ${#names} >= 2 && ${#names} <= 3 )) || continue
    for n in $names; do
      _clicue_fkey $cmd $n
      _clicue_flag_alt[$_clicue_fk]=${(j: :)${names:#$n}}
    done
  done

  _clicue_cs_words=( $swords ); _clicue_cs_descs=( $sdescs ); _clicue_cs_for=$sfor
  _clicue_flag_save $cmd
  return 0
}

# `-l, --long` when both spellings are known, otherwise just what was given.
# `-r, -R, --recursive` — every spelling of one option, short forms first, which
# is the convention the manual pages use.
_clicue_flag_label() {
  local cmd=$1 f=$2
  _clicue_fkey $cmd $f
  local alt=${_clicue_flag_alt[$_clicue_fk]}
  if [[ -z $alt ]]; then
    _clicue_fl=$f
    return
  fi
  local -a all=( $f ${=alt} )
  local -a shorts=() longs=()
  local x
  for x in $all; do
    if [[ $x == --* ]]; then longs+=( $x ); else shorts+=( $x ); fi
  done
  _clicue_fl=${(j:, :)${(o)shorts}}
  if (( ${#longs} )); then
    [[ -n $_clicue_fl ]] && _clicue_fl+=", "
    _clicue_fl+=${(j:, :)${(o)longs}}
  fi
}

# The spelling that gets INSERTED: the shortest form, because that is what
# composes into a cluster. The label still names the long form so the operator can
# read what they are building.
_clicue_flag_canon() {
  local cmd=$1 f=$2
  _clicue_fkey $cmd $f
  local alt=${_clicue_flag_alt[$_clicue_fk]}
  _clicue_fc=$f
  [[ -z $alt ]] && return
  local x
  for x in $f ${=alt}; do
    [[ $x == --* ]] && continue
    [[ ${#x} -lt ${#_clicue_fc} || $_clicue_fc == --* ]] && _clicue_fc=$x
  done
}

# Split a clustered short-flag token (-lat) into its constituents, but ONLY when
# EVERY letter is a flag this command actually documents. A partial match means
# the cluster is something else — a value, a negative number, an unknown short
# option — and inventing properties the operator never asked about is exactly the
# kind of added information design value 4 rules out.
_clicue_decompose() {
  local cmd=$1 tok=$2
  _clicue_parts=()
  # Plain glob on purpose: `##` would need EXTENDED_GLOB, which this function does
  # not set, and an unsupported operator matches literally rather than failing —
  # so the shape test silently rejected every cluster. Two letters minimum, and
  # anything non-alphabetic is caught by the per-letter lookup below.
  [[ $tok == -[a-zA-Z][a-zA-Z]* ]] || return 1
  local letters=${tok#-}
  local -i i
  local ch
  for (( i = 1; i <= ${#letters}; i++ )); do
    ch=${letters[i]}
    _clicue_fkey $cmd "-$ch"
    [[ -n ${_clicue_flag_desc[$_clicue_fk]} ]] || return 1
    _clicue_parts+=( "-$ch" )
  done
  return 0
}

# Build the name -> description map from the aligned harvest.
#
# compdescribe packs each display string as "<word><padding>-- <description>" so
# the list lines up in COMPSYS's layout — one column, name and gloss in the same
# string. clicue renders name and gloss as separate columns, so that prefix has
# to come back off or every row shows its name twice. Done here rather than in
# the compadd shadow: alignment is guaranteed by -D, and this is our own code
# where the shell options are ours to set.
_clicue_cs_build_gloss() {
  _clicue_cs_gloss=()
  local w d
  local -i i
  for (( i = 1; i <= ${#_clicue_cs_words}; i++ )); do
    d=${_clicue_cs_descs[i]}
    [[ $d == '@' || -z $d ]] && continue      # placeholder: no description given
    w=${_clicue_cs_words[i]}
    _clicue_unpack_desc $w "$d"
    [[ -z $_clicue_ud ]] && continue
    _clicue_cs_gloss[$w]=$_clicue_ud
  done
}

# ── gloss lookup ─────────────────────────────────────────────────────────────
_clicue_gloss() {
  local name=$1 kind=$2
  if [[ $_clicue_mode == arg ]]; then
    if (( _clicue_info )); then
      if (( _clicue_coldflags )); then
        _clicue_g='press Tab to load this command'"'"'s options'
      else
        _clicue_g=${CLICUE_GLOSS[$name]:-'no recorded arguments'}
      fi
      return
    fi
    # What the flag MEANS leads; how often it was used trails.
    #
    # The count alone answers a question the operator rarely has. It is still
    # worth showing — it is the only evidence of their own habits — but as an
    # annotation after the description, not instead of one.
    _clicue_fkey $_clicue_cmd $name
    local d=${_clicue_cs_gloss[$name]:-${_clicue_flag_desc[$_clicue_fk]}}
    # A cluster has no description of its own, but it does have a meaning: the
    # flags it stands for. `-lat` glossing as `used 25×` says nothing; glossing as
    # `-l · -a, --all · -t` says what the operator actually typed.
    if [[ -z $d ]] && _clicue_decompose $_clicue_cmd $name; then
      local -a plabels=()
      local pf
      for pf in $_clicue_parts; do
        _clicue_flag_label $_clicue_cmd $pf
        plabels+=( $_clicue_fl )
      done
      d=${(j: · :)plabels}
    fi
    local c=${CLICUE_ARGN[${_clicue_cmd}\|${name}]:-}
    if [[ -n $d ]]; then
      _clicue_g="$d${c:+  ${c}×}"
    else
      _clicue_g=${c:+used ${c}×}
    fi
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
typeset -ga _clicue_explain_rows=()  # "label\tdescription" for the typed line
typeset -ga _clicue_explainrows=()   # indices into _clicue_lines that are explain rows
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
    name=${_clicue_disp[$ent]:-$ent}
    kind=${_clicue_kind[$ent]:-system}
    [[ $_clicue_mode == arg ]] && kind=arg
    # $ent, NOT $name: the description is keyed on the real token. Looking it up
    # by the display label silently returned nothing for every paired row.
    _clicue_gloss $ent $kind; g=$_clicue_g
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
    _clicue_lines+=( "├${label}${(l:$rule::─:):-}┤" )
  else
    _clicue_lines+=( "╭${label}${(l:$rule::─:):-}╮" )
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
    _clicue_lines+=( "│   ${line}${(l:$crule:: :):-}│" )
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
    _clicue_lines+=( "│   ${(r:$lw:)nm}  ${(r:$dw:)ds}│" )
    _clicue_explainrows+=( ${#_clicue_lines} )
  done
  if [[ -n $footer ]]; then
    local -i frule=$(( inner - ${#footer} - 3 ))
    (( frule < 1 )) && frule=1
    _clicue_lines+=( "│   ${footer}${(l:$frule:: :):-}│" )
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
    reply=( $_clicue_cmd ); _clicue_tier1_n=1
  elif [[ $_clicue_mode == arg ]]; then
    if ! _clicue_arg_candidates $_clicue_cmd "$pfx"; then
      # Typing an option with no flag data yet. Rendering nothing here is what
      # reads as "this command cannot be completed" — the operator has no way to
      # know one Tab would fill the card. Say it instead.
      if [[ $pfx == -* ]] && ! _clicue_flag_load $_clicue_cmd 2>/dev/null; then
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
  (( namew < 10 )) && namew=10
  local -i glossw=$(( inner - namew - 5 ))
  (( glossw < 10 )) && glossw=10

  _clicue_lines=()
  _clicue_gridrows=(); _clicue_selline=0
  _clicue_explainrows=(); _clicue_footrow=0
  local hint=${_clicue_hint:-' Tab accept · Esc dismiss '}
  (( _clicue_info )) && { local REPLY; local -a dv
    zstyle -a ':clicue:keys' dismiss dv || dv=( '^[' )
    _clicue_keylabel ${dv[1]}; hint=" ${REPLY} dismiss " }

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
    local gdisp=${_clicue_disp[$gname]:-$gname}
    local gkind=${_clicue_kind[$gname]:-system}
    [[ $_clicue_mode == arg ]] && gkind=arg
    _clicue_gloss $gname $gkind
    local -i gw=$(( inner - namew - 5 ))
    (( gw < 10 )) && gw=10
    local gg=$_clicue_g
    (( ${#gg} > gw )) && gg="${gg[1,$(( gw - 1 ))]}…"
    _clicue_lines+=( "│   ${(r:$namew:)${gdisp[1,$namew]}}  ${(r:$gw:)gg}│" )
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
    [[ -n $_clicue_cmd ]] && _clicue_harvest_flags $_clicue_cmd
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

zle -N _clicue_insert
zle -N _clicue_scroll_down
zle -N _clicue_scroll_up
zle -N _clicue_accept
zle -N _clicue_dismiss
zle -N _clicue_expand

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
