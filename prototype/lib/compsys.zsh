#!/usr/bin/env zsh
# clicue — the candidate source adapter (SPEC component 3)
#
# Drives zsh's own completion system for DATA and renders it ourselves. Everything
# here uses a documented interface — compsys AGREED to be driven, which is what
# separates this from the zsh-autosuggestions integration that design value 0 is
# about:
#
#   zle -C <w> list-choices <fn>   create a completion widget (its stated purpose)
#   compstate[insert]=''           "the command line is not to be changed"
#   compstate[list]=''             draw nothing
#   compadd -O array               matches to an array, not the match set
#   compadd -D array               prune a parallel array in lockstep
#
# The boundary that matters (design value 5): compsys decides what matches, where the
# current word starts, and how a match ends. This file records those decisions and
# hands them on. It does not re-derive them.

# ── outputs of the option scan ───────────────────────────────────────────────
typeset -ga _clicue_cs_dsp=()
typeset -g  _clicue_cs_probe=''
typeset -g  _clicue_cs_hassfx=''
typeset -g  _clicue_cs_sfxval=''

# Scan a compadd argument list. Extracted from the shadow below so the suite can
# call it directly: it used to be inline, which forced the tests to carry a
# hand-copied duplicate of the logic — a copy that would keep passing if the
# original drifted, which is the one thing a test must never do.
#
# Sets, for the caller:
#   _clicue_cs_dsp     the -d display array, resolved by name or literal
#   _clicue_cs_probe   the caller supplied its own -O/-A: this call is its internal
#                      probe, not a presentation
#   _clicue_cs_hassfx  a -S was given at all — distinct from -S with an empty value
#   _clicue_cs_sfxval  that value
_clicue_cs_scan_opts() {
  _clicue_cs_dsp=(); _clicue_cs_probe=''; _clicue_cs_hassfx=''; _clicue_cs_sfxval=''
  local -i i
  local a dv
  for (( i = 1; i <= $#; i++ )); do
    a=${@[i]}
    # words follow the separator; stop before a candidate that merely LOOKS like an
    # option (completing `-ld` would otherwise read as `-d`)
    [[ $a == - || $a == -- ]] && break
    [[ $a == -?* && $a != --* ]] || continue
    case ${a[-1]} in
      # -d takes the next word as its argument, so it is necessarily last in its
      # cluster. It arrives CLUSTERED in practice: compdescribe emits `-ld`, which an
      # exact `== -d` test silently never matches. [MEASURED]
      (d) if [[ -z $dv ]]; then
            dv=${@[i+1]}
            if [[ -n ${(P)dv+x} ]]; then
              _clicue_cs_dsp=( "${(@P)dv}" )
            else
              _clicue_cs_dsp=( ${=${${dv#\(}%\)}} )   # literal (a b c) form
            fi
          fi ;;
      # A caller-supplied -O/-A means this call is the completer talking to ITSELF —
      # a "does anything match / how wide is the longest" probe. Two -O arrays do not
      # both fill: the FIRST wins [MEASURED], so passing ours would silently steal
      # theirs. _git computes its description column width from exactly such an
      # array, so stealing it corrupts the layout we are trying to read.
      (O|A) _clicue_cs_probe=1 ;;
      # -S takes an argument, so it is last in its cluster; it may also arrive with
      # the value attached, as -S=
      (S) _clicue_cs_hassfx=1; _clicue_cs_sfxval=${@[i+1]} ;;
    esac
    [[ $a == -[A-Za-z]#S?* && $a != --* ]] && \
      { _clicue_cs_hassfx=1; _clicue_cs_sfxval=${a#*S} }
  done
  return 0
}

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
    local -a w
    local -i i
    local a
    _clicue_cs_scan_opts "$@"
    local -a dsp=( "${(@)_clicue_cs_dsp}" )
    local probe=$_clicue_cs_probe
    local sfx=$_clicue_cs_sfxval
    local hassfx=$_clicue_cs_hassfx

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

# Registered here, beside the function it names. `zle -C` accepts a name whose
# function does not exist and fails SILENTLY at load, surfacing only as `no such
# shell function` on a keypress — so the registration and the definition must not be
# able to drift into different files, and the registration must not be able to run
# before the definition.
zle -C _clicue_capture list-choices _clicue_capture_fn
