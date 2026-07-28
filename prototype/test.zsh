#!/usr/bin/env zsh
# clicue — in-process assertions.
#
#   zsh prototype/test.zsh
#
# In-process, NOT pty-driven, on purpose. A zpty harness was tried first and was
# unreliable in ways that cost real time: false negatives on modified arrows, a
# silently dropped trailing space (so `git ` never reached argument position),
# and multi-key probe bindings that never arrived. Everything assertable without
# a terminal is asserted here; the pty is reserved for the compsys harvest,
# which genuinely cannot run outside a completion widget.

emulate -L zsh
setopt extended_glob

typeset -g SRC=${0:A:h}/clicue.zsh
typeset -gi PASS=0 FAIL=0
# Declared once, up front. Re-declaring a set `local` in zsh prints its value.
typeset -g k w d c body want got word disp leak bad
typeset -g SCRATCH=${TMPDIR:-/tmp}/clicue-test.$$
mkdir -p $SCRATCH
trap "rm -rf $SCRATCH" EXIT

ok()   { (( PASS++ )); print -r -- "  ok   $1" }
nope() { (( FAIL++ )); print -r -- "  FAIL $1"; [[ -n $2 ]] && print -r -- "         $2" }

section() { print -r -- ""; print -r -- "## $1" }

# ─────────────────────────────────────────────────────────────────────────────
section "parses"

if zsh -n $SRC 2>$SCRATCH/syn; then
  ok "clicue.zsh parses"
else
  nope "clicue.zsh parses" "$(<$SCRATCH/syn)"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "widget resolution"
# zle -N accepts a name whose function does not exist. It fails silently at load
# and only surfaces as `no such shell function` on the keypress. That regression
# happened TWICE, both times from an edit anchored on region markers that spanned
# code worth keeping — hence this assertion and the narrow-replacement rule.

# Collect `zle -N <name>` registrations and function definitions by reading the
# source, so no interactive shell is needed.
typeset -a registered defined
registered=( ${(f)"$(grep -o '^[[:space:]]*zle -N [A-Za-z_][A-Za-z0-9_]*' $SRC | awk '{print $3}')"} )
# `zle -C widget completion-widget function` names its handler in the THIRD
# argument — the widget itself has no function of its own name.
registered+=( ${(f)"$(grep -o '^[[:space:]]*zle -C [A-Za-z_][A-Za-z0-9_]*[[:space:]][a-z-]*[[:space:]][A-Za-z_][A-Za-z0-9_]*' $SRC | awk '{print $5}')"} )
defined=( ${(f)"$(grep -o '^[A-Za-z_][A-Za-z0-9_]*()' $SRC | sed 's/()//')"} )

if (( ${#registered} )); then
  ok "found ${#registered} zle registrations"
else
  nope "found zle registrations" "grep matched nothing — did the file move?"
fi

typeset -A have=()

for d in $defined; do have[$d]=1; done


for w in $registered; do
  if (( ${+have[$w]} )); then
    ok "widget $w has a function body"
  else
    nope "widget $w has a function body" "zle -N $w with no definition — silent at load"
  fi
done

# The completion widget's handler is named separately from the widget.
if (( ${+have[_clicue_capture_fn]} )); then
  ok "capture handler _clicue_capture_fn is defined"
else
  nope "capture handler _clicue_capture_fn is defined"
fi

# Widgets referenced as delegation fallbacks must also exist.
for w in _clicue_cs_build_gloss _clicue_gloss _clicue_render; do
  if (( ${+have[$w]} )); then
    ok "helper $w is defined"
  else
    nope "helper $w is defined"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "bind guards"
# Plain Up/Down must always reach history, and no bare printable character may
# ever be bound — binding 'q' as an alternate dismiss would break every command
# containing a q.

# Plain Up/Down ARE bound — to widgets that delegate. The invariant is not "never
# bind an arrow", it is "an arrow always ends up where it started when no card is
# being navigated". So assert the delegation, which is the part that can regress.
# NOTE: no `local k` / `local body` here. Re-declaring an already-set local
# inside or after a loop PRINTS its current value in zsh — that is how a stray
# `w=_clicue_render` once leaked onto stdout. Declare once, at the top.
typeset -A arrow_orig=( up A down B right C left D )
for k in ${(k)arrow_orig}; do
  # the widget may be one line or several, so always take a window
  body=$(grep -A6 "^_clicue_arrow_${k}()" $SRC)
  if [[ $body == *"_clicue_arrow_orig[${arrow_orig[$k]}]"* ]]; then
    ok "_clicue_arrow_${k} delegates to the original binding"
  else
    nope "_clicue_arrow_${k} delegates to the original binding" \
         "no _clicue_arrow_orig[${arrow_orig[$k]}] fallback — the key would be swallowed"
  fi
done

# Up/Down must fall back to HISTORY specifically, not to a cursor motion.
for k in up down; do
  body=$(grep -A6 "^_clicue_arrow_${k}()" $SRC)
  if [[ $body == *-line-or-history* ]]; then
    ok "_clicue_arrow_${k} falls back to history"
  else
    nope "_clicue_arrow_${k} falls back to history" "got: $body"
  fi
done

# _clicue_install_arrows must capture what owned the key BEFORE rebinding it,
# and must never rebind its own widget (which would lose the original).
if grep -q '_clicue_arrow_orig\[\$k\]=\$w' $SRC && grep -q '\$w == _clicue_arrow_\*' $SRC; then
  ok "install captures the prior owner and is idempotent"
else
  nope "install captures the prior owner and is idempotent"
fi

# No bare printable character may ever be bound: 'q' as an alternate dismiss
# would break every command containing a q, and typing IS how the operator
# narrows a card. Extract the literal key argument of each bindkey call.
typeset -a boundkeys
boundkeys=( ${(f)"$(grep -o "bindkey [\"'][^\"']*[\"']" $SRC | sed "s/bindkey //; s/^[\"']//; s/[\"']$//")"} )
bad=''
for k in $boundkeys; do
  # a single character that is not a control sequence
  if (( ${#k} == 1 )) && [[ $k != '^'* ]] && [[ $k == [[:print:]] ]]; then
    bad="$bad [$k]"
  fi
done
if [[ -z $bad ]]; then
  ok "no bare printable character is bound (${#boundkeys} literal bindings checked)"
else
  nope "no bare printable character is bound" "found:$bad"
fi

if grep -q '_clicue_bindall\|_clicue_bind' $SRC; then
  ok "bindings go through a guarded binder"
else
  nope "bindings go through a guarded binder" "raw bindkey calls bypass the guards"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "compadd shadow: option scanning"
# The shadow's job is to find the -d display array and to notice a caller-supplied
# -O/-A. Both are pure string work, so both are testable without compsys.

_scan() {
  # mirrors the scan in _clicue_capture_fn
  local -a dsp
  local -i i
  local a dv probe=''
  for (( i = 1; i <= $#; i++ )); do
    a=${@[i]}
    [[ $a == - || $a == -- ]] && break
    [[ $a == -?* && $a != --* ]] || continue
    case ${a[-1]} in
      (d) if [[ -z $dv ]]; then
            dv=${@[i+1]}
            if [[ -n ${(P)dv+x} ]]; then
              dsp=( "${(@P)dv}" )
            else
              dsp=( ${=${${dv#\(}%\)}} )
            fi
          fi ;;
      (O|A) probe=1 ;;
    esac
  done
  print -r -- "${#dsp}|${probe:-0}"
}

typeset -a disp_by_name=( 'add -- add file contents' 'rm -- remove files' )

# compdescribe emits -d CLUSTERED as -ld. An exact `== -d` test misses it, which
# is what dropped every description. [MEASURED]
[[ $(_scan -J -default- -ld disp_by_name -a words) == '2|0' ]] \
  && ok "clustered -ld is recognised" \
  || nope "clustered -ld is recognised" "got $(_scan -J -default- -ld disp_by_name -a words)"

[[ $(_scan -d disp_by_name -a words) == '2|0' ]] \
  && ok "plain -d is recognised" \
  || nope "plain -d is recognised" "got $(_scan -d disp_by_name -a words)"

# The literal parenthesised form must not keep its parens.
[[ $(_scan -d '(one two three)' -a words) == '3|0' ]] \
  && ok "literal -d (a b c) splits to 3" \
  || nope "literal -d (a b c) splits to 3" "got $(_scan -d '(one two three)' -a words)"

# A caller-supplied -O marks a probe call; ours would steal it (first -O wins).
[[ $(_scan -J -default- -O allmatching -a allcmds) == '0|1' ]] \
  && ok "caller -O is detected as a probe" \
  || nope "caller -O is detected as a probe" "got $(_scan -J -default- -O allmatching -a allcmds)"

[[ $(_scan -A theirs -a words) == '0|1' ]] \
  && ok "caller -A is detected as a probe" \
  || nope "caller -A is detected as a probe" "got $(_scan -A theirs -a words)"

# A CANDIDATE that looks like an option must not be read as one. Words come after
# the separator, so the scan has to stop there.
[[ $(_scan -J -default- - -ld -x) == '0|0' ]] \
  && ok "candidate word '-ld' after the separator is not read as -d" \
  || nope "candidate word '-ld' after the separator is not read as -d" "got $(_scan -J -default- - -ld -x)"

# ─────────────────────────────────────────────────────────────────────────────
section "compadd shadow: placeholder alignment"
# Padding to width N yields ONE N-char string. Splitting it on spaces returned a
# single blob and misaligned every group following an undescribed one, so the
# split must be on the empty separator. [MEASURED]

local -i n
for n in 1 5 45 153; do
  local -a ph=( ${(s::)${(l:${n}::@:):-}} )
  if (( ${#ph} == n )) && [[ ${ph[1]} == '@' && ${ph[-1]} == '@' ]]; then
    ok "placeholder run of $n yields $n elements"
  else
    nope "placeholder run of $n yields $n elements" "got ${#ph}"
  fi
done

local -a oldph=( ${(s: :)${(l:45::@:):-}} )
if (( ${#oldph} == 1 )); then
  ok "the old space-split form is confirmed broken (1 blob, not 45)"
else
  nope "the old space-split form is confirmed broken" "got ${#oldph} — regression premise changed"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "list-grouped is borrowed, not kept"
# clicue turns list-grouped off for the duration of its own capture, because with
# it on compsys routes long options through a grouped path that drops the
# description and duplicates every option. Borrowing it is fine; keeping it is
# not — a completer that errors mid-call must not leave the operator's normal Tab
# menu quietly regrouped.

if grep -q "zstyle ':completion:\*' list-grouped false" $SRC; then
  ok "list-grouped is set for the capture"
else
  nope "list-grouped is set for the capture"
fi

# The restore MUST be in an `always` block, not merely on the next line.
# window spans BOTH sides: the save (zstyle -g) precedes the anchor line
body=$(grep -B6 -A12 'zstyle .:completion:\*. list-grouped false' $SRC)
if [[ $body == *'always'* && $body == *'_main_complete'* ]]; then
  ok "_main_complete is wrapped so the restore always runs"
else
  nope "_main_complete is wrapped so the restore always runs" \
       "no always block — an aborting completer would leak the style"
fi

# Both restore arms must exist: put the old value back, or delete ours outright.
if [[ $body == *'zstyle -g'* ]] && [[ $body == *'zstyle -d'* ]]; then
  ok "restore handles both a previously-set and an unset style"
else
  nope "restore handles both a previously-set and an unset style"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "gloss unpacking"
# compdescribe packs display strings as "<word><padding>-- <description>".
# clicue renders name and gloss as separate columns, so the prefix must come off.

_unpack() {
  local w=$1 d=$2 sep=${3:---}
  if [[ $d == ${w}* ]]; then
    d=${d#$w}
    d=${d##[[:space:]]#}
    [[ $d == ${sep}(|[[:space:]]*) ]] && d=${d#$sep}
    d=${d##[[:space:]]#}
  fi
  d=${d%%[[:space:]]#}
  print -r -- $d
}

typeset -a cases=(
  'stripspace|stripspace -- filter out empty lines|filter out empty lines'
  'add|add          -- Add file contents to the index|Add file contents to the index'
  'patch-id|patch-id -- compute unique ID for patches|compute unique ID for patches'
)

for c in $cases; do
  word=${c%%|*}; disp=${${c#*|}%%|*}; want=${c##*|}
  got=$(_unpack $word $disp)
  [[ $got == $want ]] && ok "unpack [$word]" || nope "unpack [$word]" "want [$want] got [$got]"
done

# A description that does NOT repeat its word must pass through untouched.
got=$(_unpack foo 'some description')
[[ $got == 'some description' ]] && ok "unprefixed description passes through" \
  || nope "unprefixed description passes through" "got [$got]"

# A description that legitimately begins with a dash must survive.
got=$(_unpack foo 'foo -- --bare is implied')
[[ $got == '--bare is implied' ]] && ok "description starting with -- survives" \
  || nope "description starting with -- survives" "got [$got]"

# A word that is a prefix of its own description must not be over-stripped.
got=$(_unpack rm 'rm -- remove files')
[[ $got == 'remove files' ]] && ok "short word does not over-strip" \
  || nope "short word does not over-strip" "got [$got]"

# ─────────────────────────────────────────────────────────────────────────────
section "corpus"

typeset -g CORPUS=${XDG_CACHE_HOME:-$HOME/.cache}/clicue/corpus.zsh
if [[ -r $CORPUS ]]; then
  ok "corpus cache exists"
  if zsh -n $CORPUS 2>/dev/null; then
    ok "corpus cache parses"
  else
    nope "corpus cache parses"
  fi
  # Sourcing must not leak to stdout — a stray `local` redeclaration inside a
  # loop PRINTS the existing value, which once leaked into the rendered card.
  leak=$(zsh -f -c "source $CORPUS" 2>&1)
  if [[ -z $leak ]]; then
    ok "sourcing the corpus is silent"
  else
    nope "sourcing the corpus is silent" "leaked: ${leak[1,120]}"
  fi
else
  print -r -- "  skip corpus assertions (no cache at $CORPUS)"
fi

# ─────────────────────────────────────────────────────────────────────────────
print -r -- ""
print -r -- "${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
