#!/usr/bin/env zsh
# clicue — candidate resolution and ranking
#
# What goes on the card, and in what order. This is squarely clicue's half of design
# value 5: compsys decides what is VALID here, this file decides what is WORTH SHOWING
# FIRST and how spellings of one option collapse into a single row.
#
# Ranking is partitioned rather than fully sorted: frequency data covers only the
# commands actually used, so keying and sorting the whole match set is wasted work.
# Frequent candidates sort by count descending, the rest alphabetically.

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
  typeset -g _clicue_argnomatch=0
  if [[ $pfx == -* ]] || (( _clicue_optctx )); then
    # keyed on the path the cursor is in, so `gh org <Tab>` offers org's options
    local lookup=${_clicue_cmdpath:-$cmd}
    _clicue_flag_load $lookup 2>/dev/null
    # The flag map is keyed on the ALIAS-RESOLVED path — _clicue_flag_load and
    # _clicue_fkey both resolve before they touch it — so the scan below must compare
    # against the resolved head too. Comparing the typed path meant an aliased command
    # matched NOTHING: `ls` is declared to emulate `lsd`, the cache held `lsd|--long`,
    # and the scan looked for `ls|`. So `ls -` found zero options and the card bailed,
    # while `cat -` worked, which is what made it read as an alias bug rather than a
    # key-format one. [MEASURED]
    _clicue_resolve_path $lookup
    local keypfx=$_clicue_realpath
    # ALL declared here, outside the loop. Re-declaring a set `local` inside a loop
    # body prints its value — `sp=--help` and friends leaked straight onto the
    # terminal. Third time this exact gotcha has bitten this file.
    local fk alt canon sp fpfx
    local -i pass
    # TWO passes. The second drops the prefix filter, and only runs when the first
    # matched nothing at all.
    #
    # An option prefix that matches nothing is a TYPO, not a reason to hand the line
    # back to a completer. A leading dash is never a filename, and delegating here
    # does not merely show the wrong UI: measured, `cat -l1<Tab>` had zsh's own
    # completion REWRITE the line to `cat -A`. Losing what you typed is a worse
    # outcome than any card.
    #
    # So the whole option set is offered instead, and the card says the prefix matched
    # nothing rather than implying these are matches. The operator can then see what
    # they meant and arrow to it, which is the composition loop working as intended.
    # ── membership is compsys's; presentation is ours ──────────────────────────
    # Design value 5, finally honoured in flag position. When compsys has answered for
    # THIS buffer, its words are the candidate set: it knows what is valid *here*, and
    # the cached flag set cannot, because the cache is a snapshot taken at one canonical
    # position and replayed at every other.
    #
    # [MEASURED] the gap is real and visible. `rm -r -`: compsys offers 14 options and
    # omits `-r`, which is already on the line; the cache re-offered it. `man -a -`:
    # same for `-a`. `tar -c -`: compsys offers NOTHING, because the cluster letters are
    # mutually exclusive and one is chosen; the cache knows no such thing. Repeatability
    # is the same question from the other side — some flags legitimately repeat, and
    # only the `_arguments` spec knows which, so subtracting typed flags ourselves would
    # have been a heuristic that is wrong in the other direction.
    #
    # The cache is not discarded: it still decides GROUPING and LABELS, which is what it
    # was built for and what compsys does not provide. And before the first Tab it is
    # still the membership source — a provisional answer with no fork, which is the
    # whole reason the card has content in flag position at all. Compsys's answer
    # supersedes it the moment it exists.
    local -a src=()
    local -i from_compsys=0
    if [[ $_clicue_cs_for == $LBUFFER ]] && (( ${#_clicue_cs_words} )); then
      from_compsys=1
      for n in $_clicue_cs_words; do
        # normalise a dash the completer consumed into IPREFIX, exactly as the raw
        # pass below does — one representation, or dedup and insertion disagree
        [[ $n != -* && $_clicue_cs_iprefix == -* ]] && n="${_clicue_cs_iprefix}${n}"
        src+=( $n )
      done
    else
      for fk in ${(ko)_clicue_flag_desc}; do
        [[ $fk == ${keypfx}\|* ]] || continue
        src+=( ${fk#*\|} )
      done
      # On the CACHE path only, do not re-offer an option already on the line. This is
      # clicue's own bookkeeping over its own provisional list, not an override of
      # compsys — compsys has not spoken, or has declined to. `tar -c -` is the case:
      # compsys offers nothing (the cluster letters are exclusive and one is chosen),
      # and the cache offered all seven back including the `-c` already typed.
      #
      # Everything except the FIRST token (the command) and the LAST one (the word under
      # the cursor). Excluding the last would remove the very candidate being typed —
      # `rm -r` must still offer `-r`.
      #
      # Known limit, and the reason this stays on the fallback path: a cluster is one
      # token, so `rm -rf -` subtracts `-rf` and not `-r` and `-f`. Compsys gets that
      # right, and its answer supersedes this the moment Tab produces one.
      local tok
      local -i ti
      for (( ti = 2; ti < ${#_clicue_words}; ti++ )); do
        tok=${_clicue_words[ti]}
        [[ $tok == -* ]] && seen[$tok]=1
      done
    fi
    # Sorted so the SHORT spelling of a pair is met first and becomes the row.
    src=( ${(o)src} )

    for (( pass = 1; pass <= 2; pass++ )); do
      if (( pass == 2 )); then
        (( ${#hist} || ${#rest} )) && break
        [[ $pfx == -* ]] || break
        # Compsys already answered for this buffer, so an empty result is its DECISION,
        # not a stale cache. Overriding it with the full option set would be clicue
        # deciding — precisely what this section stops doing.
        (( from_compsys )) && break
        fpfx=''
        _clicue_argnomatch=1
      else
        fpfx=$pfx
      fi
    for n in $src; do
      (( ${+seen[$n]} )) && continue
      # One row per FLAG, not per spelling. `-d` and `--dir` describing the same
      # thing were two rows saying the same sentence twice, which is what the
      # description-pairing was for in the first place. The short form is the
      # candidate — it is what the operator is typing — and the long form rides
      # along in the label.
      [[ -n $fpfx && $n != ${fpfx}* ]] && continue
      _clicue_fkey $lookup $n
      alt=${_clicue_flag_alt[$_clicue_fk]}
      if [[ -z $alt ]]; then
        seen[$n]=1; rest+=( $n ); continue
      fi
      # One row for the whole group. The row is keyed on the spelling that gets
      # inserted, and every other spelling is marked seen so it cannot also appear
      # on its own row.
      _clicue_flag_canon $lookup $n
      canon=$_clicue_fc
      # when a prefix is being typed, honour it over the canonical short form —
      # typing `--rec` must not silently insert `-r`
      [[ -n $fpfx && $canon != ${fpfx}* ]] && canon=$n
      (( ${+seen[$canon]} )) && continue
      seen[$n]=1; seen[$canon]=1
      for sp in ${=alt}; do seen[$sp]=1; done
      _clicue_flag_label $lookup $n
      _clicue_disp[$canon]=$_clicue_fl
      rest+=( $canon )
    done
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
  # A prefix filter is NOT enough to tell a stale harvest from a live one. It catches
  # the operator narrowing within the same command, which is what it was written for,
  # and misses the case that matters: a harvest taken for a DIFFERENT command whose
  # flags all start with a dash and therefore all pass. Measured — probing `rm -r -`
  # and then `tar -c -` in one shell put `--no-preserve-root` and `--one-file-system`
  # on tar's card.
  #
  # The harvest is usable only if the buffer it was taken for is a prefix of the current
  # one: `git ` still answers for `git co`, and nothing answers for a line that no
  # longer starts the same way.
  if ! [[ -n $_clicue_cs_for && $LBUFFER == ${_clicue_cs_for}* ]]; then
    typeset -g _clicue_arg_t1=${#hist}
    reply=( $hist ${(o)rest} )
    (( ${#reply} )) || return 1
    return 0
  fi
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
