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

# ── ranking, as a configurable experiment ────────────────────────────────────
#
#   zstyle ':clicue:*' ranking frecency   # default: count, weighted by how recent
#   zstyle ':clicue:*' ranking frequency  # count alone — what this shipped with
#   zstyle ':clicue:*' ranking recency    # last-used alone, count ignored
#
# Configurable rather than decided, because which one is right is not knowable from
# first principles — it is knowable from living with it. Every report that shaped this
# tool so far came from its author using it and something feeling off, so ranking is
# built to be switched mid-session (`clicue-rank recency`) and, more importantly, to be
# *interrogated* when an order looks wrong (`clicue-rank why gi`). A ranking you cannot
# question is one you can only have opinions about.
#
# Integer arithmetic and bucketed decay, deliberately: a continuous half-life needs
# zsh/mathfunc, and this runs on the keystroke path. Buckets are Mozilla's frecency
# shape — a handful of multipliers by age — which is well-trodden and easy to reason
# about when a result surprises you.
_clicue_rank_mode() {
  zstyle -s ':clicue:*' ranking _clicue_rmode 2>/dev/null || _clicue_rmode=frecency
  case $_clicue_rmode in
    (frequency|recency|frecency) ;;
    (*) _clicue_rmode=frecency ;;
  esac
  return 0
}

# Age multiplier for a last-seen epoch. Sets _clicue_rw.
_clicue_recency_weight() {
  local -i last=${1:-0}
  _clicue_rw=1
  (( last > 0 && ${EPOCHSECONDS:-0} > 0 )) || return 0
  local -i days=$(( (EPOCHSECONDS - last) / 86400 ))
  if   (( days <= 0 ));  then _clicue_rw=16
  elif (( days <= 7 ));  then _clicue_rw=8
  elif (( days <= 30 )); then _clicue_rw=4
  elif (( days <= 180 )); then _clicue_rw=2
  else _clicue_rw=1
  fi
  return 0
}

# Sets _clicue_rscore for one command name. Higher sorts first.
_clicue_rank_score() {
  local n=$1
  local -i f=${CLICUE_FREQ[$n]:-0}
  local -i last=${CLICUE_LAST[$n]:-0}
  case $_clicue_rmode in
    (frequency) _clicue_rscore=$f ;;
    # Recency alone still needs a tiebreak for everything never dated: an undated
    # command scores 0 and falls to the alphabetical tier, which is where it belongs.
    (recency)   _clicue_rscore=$(( last / 86400 )) ;;
    (*)         _clicue_recency_weight $last
                _clicue_rscore=$(( f * _clicue_rw )) ;;
  esac
  return 0
}

# ── candidate generation (command position only, v1) ─────────────────────────
# Sets reply=( name:kind ... ) ranked by the configured metric, then name.
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
  _clicue_rank_mode
  for n in ${(k)_clicue_kind}; do
    _clicue_rank_score $n
    if (( _clicue_rscore )); then
      # Descending by score via an ascending string sort on its complement. Width 10,
      # not 8: `frecency` multiplies a count by up to 16, so an 8-digit field overflowed
      # for a heavily-used command and wrapped it to the BOTTOM of the card.
      freqd+=( "${(l:10::0:)$(( 9999999999 - _clicue_rscore ))}|$n" )   # no fork
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

# ── whole remembered lines, for commands whose arguments are not paths ───────
#
# The corpus cannot answer `ssh <user>@<host>`. The host is a VALUE, and values are
# stripped when invocation keys are built — deliberately, because keeping them makes
# every invocation unique and the count meaningless. So for commands whose arguments
# are worth replaying verbatim, the source is history itself.
#
# This is `_clicue_history_stem` generalised from one match to N. That function already
# finds the newest line continuing the buffer and offers its remainder as ghost text;
# everything here is the same lookup without the early stop, so Tab can cycle the rest.
#
# Ranked by RECENCY, and not by count, because counting is broken on a de-duplicated
# history: under HIST_IGNORE_ALL_DUPS every unique line appears exactly once no matter
# how often it was run, so a count measures argument diversity rather than habit. What
# de-duplication preserves is the NEWEST occurrence — which makes `$history` order the
# undistorted signal, and it is already sorted that way.
# (docs/design-notes/habits-in-argument-position.md)
#
# Sets reply=( candidate ... ). A candidate is the line minus whatever precedes the word
# under the cursor, so it still begins with $pfx — which is what lets _clicue_cue_stem
# and _clicue_insert treat a multi-token cue exactly like a one-word one.
_clicue_history_lines() {
  local buf=$1 pfx=$2
  local -i cap=${3:-40}
  reply=()
  [[ -n $buf ]] || return 1
  (( ${#history} )) || return 1
  # Everything to the left of the word being typed. Stripped from each match so the
  # candidate starts at the cursor's own word rather than at the start of the line.
  #
  # By LENGTH, not by `${buf%$pfx}`. That form strips a PATTERN, so a word containing a
  # glob eats the wrong amount: with pfx `*`, `%` matches the shortest suffix — the
  # empty string — and the head swallows the whole buffer, leaving every candidate
  # empty. The prefix is a literal substring of the buffer, so its length is exact.
  local head=${buf[1,${#buf}-${#pfx}]}
  local -A seen=()
  local m c
  # (b) quotes the buffer. Without it a line containing a glob character turns this
  # lookup into a pattern match against every other line in history — the same reason
  # _clicue_history_stem quotes, recorded there.
  #
  # The (R) SUBSCRIPT, not `${(M)history:#...}`. Both look like they filter values by a
  # pattern and only one re-scans the expansion as one: inside `:#` the quoted result of
  # (b) is compared as literal text, backslashes and all, so a buffer carrying a glob
  # matched nothing at all. The subscript is also the form _clicue_history_stem already
  # uses, one letter apart — (r) takes the first match, (R) takes them all. [MEASURED]
  for m in ${(v)history[(R)${(b)buf}*]}; do
    # Length again, for the same reason as $head: `${m#$head}` strips a pattern, and a
    # glob anywhere earlier in the line makes it remove the wrong amount.
    c=${m[${#head}+1,-1]}
    # The RHS is QUOTED. Unquoted, `!=` inside [[ ]] is a pattern match, so a prefix of
    # `*` matched every candidate and the whole list was discarded as "same as what is
    # typed". Third form of one gotcha in this function alone: %, # and != are all
    # pattern operators, and every one of them needs a literal here.
    [[ -n $c && $c != "$pfx" ]] || continue
    # Distinct LINES can still share a suffix once the head is removed, and dedup has
    # only guaranteed the lines differ.
    (( ${+seen[$c]} )) && continue
    seen[$c]=1
    reply+=( $c )
    (( ${#reply} >= cap )) && break
  done
  (( ${#reply} ))
}

# ── remembered invocations, for commands whose arguments ARE paths ───────────
#
# The counterpart to _clicue_history_lines. For `rm`, `ls`, `tar` and the rest of the
# pathish class, replaying a whole remembered line would offer a path that was deleted
# months ago — so what is offered is the flag part alone, which is exactly what the
# invocation keys hold.
#
# Ordered by LAST-SEEN, not by count, for the reason recorded above _clicue_history_lines
# and measured in the design note: at invocation level a de-duplicated history makes the
# count a measure of argument diversity, so the most habitual entries score lowest.
# `rm -rf` reaches ~30 only because the paths after it varied; a listing typed the same
# way every time sits at 1.
_clicue_invocation_cues() {
  local cmd=$1 pfx=$2
  local -i cap=${3:-40}
  reply=()
  (( ${#CLICUE_INVOKE} )) || return 1
  local k disp rest
  local -a scored=()
  local -A seen=()
  for k in ${(k)CLICUE_INVOKE}; do
    [[ $k == "${cmd} "* ]] || continue
    # The key is canonical so one habit has one entry; the SPELLING is what the
    # operator last reached for, and that is what gets proposed and inserted.
    disp=${CLICUE_INVOKE_DISP[$k]:-$k}
    rest=${disp#${cmd} }
    [[ -n $rest ]] || continue
    [[ -n $pfx && $rest != ${pfx}* ]] && continue
    (( ${+seen[$rest]} )) && continue
    seen[$rest]=1
    # Descending by epoch via an ascending string sort on its complement, the same
    # trick command position uses. Width 12, not 10: an epoch is already 10 digits, and
    # the note above the command-position sort records what an overflowing field did —
    # it wrapped the most-used entry to the BOTTOM of the card.
    scored+=( "${(l:12::0:)$(( 99999999999 - ${CLICUE_INVOKE_LAST[$k]:-0} ))}|$rest" )
  done
  reply=( ${${(o)scored}#*|} )
  (( ${#reply} > cap )) && reply=( ${reply[1,cap]} )
  (( ${#reply} ))
}

# ── argument candidates: what YOU have actually passed this command ──────────
# Tier 1 is the operator's own habits, sourced by splitting on pathish: whole remembered
# lines where the values are worth replaying, flag-only invocation keys where they are
# not. Tier 2 — everything below — is compsys's authoritative set, alphabetical.
# (docs/design-notes/habits-in-argument-position.md)
_clicue_arg_candidates() {
  local cmd=$1 pfx=$2
  local -a hist=() rest=()
  if (( ${+CLICUE_PATHISH[$cmd]} )); then
    _clicue_invocation_cues $cmd "$pfx" && hist=( $reply )
  else
    _clicue_history_lines "$LBUFFER" "$pfx" && hist=( $reply )
  fi
  reply=()
  # The per-token map still answers when neither source has anything — a command whose
  # arguments were never a whole line worth keeping, but whose subcommands were seen.
  if (( ! ${#hist} )); then
    local -a toks=( ${(s: :)CLICUE_ARGS[$cmd]} )
    if [[ -n $pfx ]]; then
      hist=( ${(M)toks:#${pfx}*} )
    else
      hist=( $toks )
    fi
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
  reply=( $hist ${(o)rest} )
  (( ${#reply} )) || return 1
  return 0
}

# ── clicue-rank: switch the metric, and ask it to justify itself ──────────────
# `why` exists because every improvement to this tool so far started as "that order
# feels wrong" and then cost a measurement to explain. This makes the measurement one
# command, so the feeling can be checked immediately instead of remembered vaguely.
clicue-rank() {
  emulate -L zsh
  _clicue_rank_mode
  local sub=$1
  case $sub in
    (''|status)
      # The corpus loads LAZILY, so a status that does not load it first reports on an
      # empty one and warns about missing recency that is sitting on disk.
      _clicue_load 2>/dev/null
      print -r -- "ranking: ${_clicue_rmode}"
      print -r -- "modes:   frequency  recency  frecency"
      print -r -- "         clicue-rank <mode>        switch for this session"
      print -r -- "         clicue-rank why <prefix>  show the scores behind an order"
      # Both ways recency can be silently absent. A metric that quietly degrades to a
      # different metric is design value 1's invisible fallback, so it is stated.
      (( ${#CLICUE_LAST} )) || \
        print -u2 -- "note: no recency data in the corpus — run 'clicue-cache rebuild'"
      (( ${EPOCHSECONDS:-0} )) || \
        print -u2 -- "note: zsh/datetime is not loaded, so ages are unknown and ${_clicue_rmode} behaves as frequency"
      return 0 ;;
    (frequency|recency|frecency)
      zstyle ':clicue:*' ranking $sub
      print -r -- "clicue: ranking is now ${sub}"
      return 0 ;;
    (why)
      shift
      local pfx=$1
      if [[ -z $pfx ]]; then print -u2 -- "usage: clicue-rank why <prefix>"; return 1; fi
      _clicue_load 2>/dev/null
      local -a reply=()
      local n
      _clicue_candidates $pfx
      print -r -- "ranking: ${_clicue_rmode}   prefix: ${pfx}   candidates: ${#reply}"
      printf '%-28s %6s %7s %5s %10s\n' NAME COUNT AGE WEIGHT SCORE
      local -i shown=0 f last days
      for n in $reply; do
        (( shown++ > 19 )) && { print -r -- "  … ${#reply} total"; break }
        f=${CLICUE_FREQ[$n]:-0}
        last=${CLICUE_LAST[$n]:-0}
        _clicue_recency_weight $last
        _clicue_rank_score $n
        if (( last > 0 && ${EPOCHSECONDS:-0} > 0 )); then
          days=$(( (EPOCHSECONDS - last) / 86400 ))
          printf '%-28s %6d %6dd %5d %10d\n' $n $f $days $_clicue_rw $_clicue_rscore
        else
          printf '%-28s %6d %7s %5s %10d\n' $n $f '—' '—' $_clicue_rscore
        fi
      done
      return 0 ;;
    (*)
      print -u2 -- "clicue-rank: unknown '${sub}' — try: frequency recency frecency why"
      return 1 ;;
  esac
}
