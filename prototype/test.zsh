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

typeset -g DIR=${0:A:h}
typeset -gi PASS=0 FAIL=0
# Declared once, up front. Re-declaring a set `local` in zsh prints its value.
typeset -g k w d c body want got word disp leak bad harvest f srcout
typeset -g SCRATCH=${TMPDIR:-/tmp}/clicue-test.$$
mkdir -p $SCRATCH
trap "rm -rf $SCRATCH" EXIT

# EVERY source file, entry point first. The glob is (N) so this suite works both
# before and during the split into lib/.
typeset -ga SRCS=( $DIR/clicue.zsh $DIR/lib/*.zsh(N) )

# Content assertions read a CONCATENATION of all of them. A guard that reads only
# the entry point would go blind to exactly the regression splitting causes: a
# widget whose function ended up in a file nobody sources. Assertions that need a
# real filename or line number iterate $SRCS instead.
typeset -g SRC=$SCRATCH/all.zsh
cat $SRCS > $SRC

ok()   { (( PASS++ )); print -r -- "  ok   $1" }
nope() { (( FAIL++ )); print -r -- "  FAIL $1"; [[ -n $2 ]] && print -r -- "         $2" }

section() { print -r -- ""; print -r -- "## $1" }

# ─────────────────────────────────────────────────────────────────────────────
section "parses"

for f in $SRCS; do
  if zsh -n $f 2>$SCRATCH/syn; then
    ok "${f:t} parses"
  else
    nope "${f:t} parses" "$(<$SCRATCH/syn)"
  fi
done
ok "found ${#SRCS} source file(s)"

# ─────────────────────────────────────────────────────────────────────────────
section "the tree hangs together"
# Splitting into lib/ introduces a failure mode that nothing else here would catch:
# a file that defines functions but is never sourced. zle -N accepts a name whose
# function does not exist, so the result is silence at load and `no such shell
# function` on a keypress.

typeset -a unsourced=()
for f in $DIR/lib/*.zsh(N); do
  if grep -q "${f:t}" $DIR/clicue.zsh $DIR/lib/*.zsh(N) 2>/dev/null; then
    ok "lib/${f:t} is referenced by a source line"
  else
    unsourced+=( ${f:t} )
    nope "lib/${f:t} is referenced by a source line" \
         "defines functions that will never load"
  fi
done
if (( ${#SRCS} == 1 )); then
  print -r -- "  note  not split yet — lib/ assertions are inert until it is"
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
section "registration order"
# The grep-based check above proves a function exists SOMEWHERE in the sources. This
# one sources the tree for real and asks zsh whether every registered widget's
# handler is actually defined afterwards — which catches an orphaned lib file, a
# renamed function, or a typo in a registration, none of which grep-over-concatenation
# can distinguish from a working tree.
#
# What it deliberately does NOT claim: that a registration must follow its
# definition. `zle -C` accepts an undefined name and the widget still works provided
# the function is defined before the first keypress, which sourcing guarantees. An
# earlier version of this section asserted the ordering and was vacuous — the mutation
# test that was supposed to confirm it instead disproved the premise.
typeset -g srcout=$SCRATCH/src.out
zsh -f -c "
  source $DIR/clicue.zsh >/dev/null 2>&1
  for n in \${(k)functions}; do print -r -- \$n; done
" >$srcout 2>&1
if [[ -s $srcout ]]; then
  ok "the tree sources and defines functions"
else
  nope "the tree sources and defines functions" "nothing defined — the load failed"
fi

# every zle -N name, and every zle -C handler (its THIRD argument)
typeset -a handlers
handlers=( ${(f)"$(grep -ho '^[[:space:]]*zle -N [A-Za-z_][A-Za-z0-9_]*' $SRCS | awk '{print $3}')"} )
handlers+=( ${(f)"$(grep -ho '^[[:space:]]*zle -C [A-Za-z_][A-Za-z0-9_]*[[:space:]][a-z-]*[[:space:]][A-Za-z_][A-Za-z0-9_]*' $SRCS | awk '{print $5}')"} )
bad=''
for w in $handlers; do
  grep -qx "$w" $srcout || bad="$bad $w"
done
if [[ -z $bad ]]; then
  ok "all ${#handlers} widget handlers are defined after a real load"
else
  nope "all ${#handlers} widget handlers are defined after a real load" \
       "undefined:$bad — a keypress on these would say 'no such shell function'"
fi

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
section "Tab costs one press"
# The harvest must not consume the keystroke, and a stood-down clicue must
# delegate before forking compsys for a card it will not draw. Structural
# assertions only — no pty here can deliver a Tab into a live clicue shell
# reliably, so the BEHAVIOUR is verified in a real terminal.

# the whole function body, from its definition to the closing brace at column 1
body=$(awk '/^_clicue_accept\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
# strip comments so prose cannot satisfy a code assertion
body=${(F)${(f)body}:#[[:space:]]#\#*}

# The guard comes first, before the harvest — and it tests STAND-DOWN, not
# visibility. Those are different states, and conflating them is what dumped
# zsh's raw completion listing on screen: a card with no candidates YET is not a
# position clicue has yielded, and delegating there hands the flags to a
# completely different visual language.
if [[ $body == *'_clicue_standdown'*'_clicue_orig_tab'*'_clicue_cs_for != $LBUFFER'* ]]; then
  ok "a deliberate stand-down delegates to the original Tab BEFORE the harvest"
else
  nope "a deliberate stand-down delegates to the original Tab BEFORE the harvest" \
       "order matters: harvesting first is what cost the extra press"
fi

if [[ $body != *'! _clicue_visible'* ]]; then
  ok "Tab does not delegate merely because the card is empty"
else
  nope "Tab does not delegate merely because the card is empty" \
       "an empty card is not a yielded position — that is how the raw listing appeared"
fi

# The harvest block must fall through, not return. Checked by position: the
# harvest's closing `fi` must come BEFORE the cycle branch, with no return
# between the gloss build and that fi.
harvest=${${body#*_clicue_cs_build_gloss}%%$'\n  fi'*}
if [[ $harvest != *'return'* ]]; then
  ok "the harvest block falls through instead of returning"
else
  nope "the harvest block falls through instead of returning" \
       "a return here means press one fetches and press two moves"
fi

# after harvesting, the card must be rebuilt so the selection lands on the
# enlarged candidate set rather than a stale one
if [[ $body == *'_clicue_cs_build_gloss'*'_clicue_render'* ]]; then
  ok "the card is re-rendered against the harvested candidates"
else
  nope "the card is re-rendered against the harvested candidates"
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
section "silent-failure guards"
# Two zsh behaviours that fail by STORING THE WRONG THING rather than erroring.
# Both bit this project, one of them twice, so both are asserted across the whole
# file rather than at the site that happened to be wrong.

# 1. An unescaped `|` in an associative-array subscript does not store under the
#    key it appears to. The write lands where the read never looks and the map
#    stays empty, with no error anywhere.
typeset -a badsub
badsub=( ${(f)"$(grep -n '^[^#]*[A-Za-z_][A-Za-z0-9_]*\[\$[{(][^]]*|' $SRCS | grep -v '\\|' || true)"} )
if (( ${#badsub} == 0 )); then
  ok "no composite assoc subscript builds its key inline with a bare |"
else
  nope "no composite assoc subscript builds its key inline with a bare |" \
       "${badsub[1]}"
fi

if grep -q '_clicue_fkey()' $SRC; then
  ok "composite keys go through _clicue_fkey"
else
  nope "composite keys go through _clicue_fkey"
fi

# 2. `print -r` does NOT expand escapes, so "\t" writes backslash-t. A file
#    written that way and read back with a real-tab split silently merges fields.
typeset -a badtab
# Only the BROKEN form. Excluded: comment lines (the note explaining this bug
# contains the pattern) and lines using $'\t', which is the correct spelling.
badtab=( ${(f)"$(grep -n 'print -r.*\\t' $SRC \
                 | grep -v ':[[:space:]]*#' \
                 | grep -v "\\\$'" || true)"} )
if (( ${#badtab} == 0 )); then
  ok "no print -r writes a literal \\t where a tab is meant"
else
  nope "no print -r writes a literal \\t where a tab is meant" "${badtab[1]}"
fi

# 3. Re-declaring an already-set `local` inside a loop body PRINTS its value
#    straight to the terminal. It has happened three times in this file (gcol, w,
#    and sp/canon in the flag loop), so declarations belong outside the loop.
typeset -a loopdecl
loopdecl=( ${(f)"$(awk '
  /^[[:space:]]*(for|while|repeat) .*(do|\{)[[:space:]]*$/ { depth++; next }
  /^[[:space:]]*(done|\})[[:space:]]*$/ { if (depth > 0) depth-- ; next }
  depth > 0 && /^[[:space:]]*local [a-zA-Z_]/ && !/^[[:space:]]*#/ { print FILENAME ":" NR ": " $0 }
' $SRCS || true)"} )
if (( ${#loopdecl} == 0 )); then
  ok "no local declaration sits inside a loop body"
else
  nope "no local declaration sits inside a loop body" "${loopdecl[1]}"
fi

# 3. Glob operators that need EXTENDED_GLOB match LITERALLY when it is off, so a
#    shape test silently rejects everything. _clicue_decompose runs without it.
body=$(awk '/^_clicue_decompose\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
body=${(F)${(f)body}:#[[:space:]]#\#*}
if [[ $body != *'##'* ]] || [[ $body == *'extended_glob'* ]]; then
  ok "_clicue_decompose does not depend on EXTENDED_GLOB without setting it"
else
  nope "_clicue_decompose does not depend on EXTENDED_GLOB without setting it" \
       "a ## here matches literally and rejects every cluster"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "flags are described, not just counted"

# The description must come BEFORE the count in the argument gloss.
body=$(awk '/^_clicue_gloss\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
body=${(F)${(f)body}:#[[:space:]]#\#*}
if [[ $body == *'_clicue_g="$d'* ]]; then
  ok "argument gloss leads with the description"
else
  nope "argument gloss leads with the description" \
       "the count answers a question the operator rarely has"
fi
if [[ $body == *'used ${c}×'* ]]; then
  ok "the count survives as the fallback when nothing describes the flag"
else
  nope "the count survives as the fallback when nothing describes the flag"
fi

# Spellings sharing a description group together — not restricted to pairs, since
# `-r`, `-R` and `--recursive` are all one option. But CAPPED, because a generic
# description shared by unrelated flags must not group them.
body=$(awk '/^_clicue_harvest_flags\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'${#names} >= 2'* ]]; then
  ok "two or more spellings sharing a description group together"
else
  nope "two or more spellings sharing a description group together"
fi
if [[ $body == *'${#names} <= 3'* ]]; then
  ok "grouping is capped, so a generic description cannot merge unrelated flags"
else
  nope "grouping is capped, so a generic description cannot merge unrelated flags" \
       "'display help information' is shared by unrelated flags in some completers"
fi

# The buffer must be restored after the synthesised `<cmd> -` harvest, in a way
# that survives an aborting completer.
if [[ $body == *'always'*'BUFFER=$sbuf'* ]]; then
  ok "the synthesised harvest restores the operator's line in an always block"
else
  nope "the synthesised harvest restores the operator's line in an always block" \
       "leaving a fabricated line on screen is the worst possible failure here"
fi

# Decomposition must refuse unless EVERY letter is documented.
body=$(awk '/^_clicue_decompose\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'|| return 1'* ]]; then
  ok "decomposition refuses a cluster with any undocumented letter"
else
  nope "decomposition refuses a cluster with any undocumented letter"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "flag position belongs to clicue"
# A leading dash is never a filename. The stand-down rule used to yield whenever
# the corpus knew no arguments for a command, which is true of every path-centric
# command — so `rm -<Tab>` handed the flags to zsh and they appeared in a totally
# different visual language, with clicue's card gone.

body=$(awk '/^_clicue_pre_redraw\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
body=${(F)${(f)body}:#[[:space:]]#\#*}

if [[ $body == *'$_clicue_pfx != -*'* ]]; then
  ok "an option token is kept even when the corpus knows no arguments"
else
  nope "an option token is kept even when the corpus knows no arguments" \
       "yielding here is what printed zsh's raw listing instead of the card"
fi

if [[ $body == *'_clicue_standdown=1'* && $body == *'_clicue_standdown=0'* ]]; then
  ok "pre_redraw marks stand-down before, and clears it at the commit point"
else
  nope "pre_redraw marks stand-down before, and clears it at the commit point"
fi

# Path-like input must STILL yield — compsys owns the filesystem.
if [[ $body == *'*/*'* && $body == *"'~'*"* ]]; then
  ok "path-like input still yields to compsys"
else
  nope "path-like input still yields to compsys" \
       "clicue must not compete with the coloured path picker"
fi

# Flag candidates come from the on-disk cache, so the card has content without a
# fork. An empty card is how the raw listing got on screen.
body=$(awk '/^_clicue_arg_candidates\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_flag_load'* ]]; then
  ok "flag candidates load from cache with no fork"
else
  nope "flag candidates load from cache with no fork"
fi

# One row per flag, not per spelling — and the inserted token is the short form,
# because that is what composes into a cluster.
if [[ $body == *'_clicue_disp['* ]]; then
  ok "grouped spellings collapse to one row with a display label"
else
  nope "grouped spellings collapse to one row with a display label"
fi
if [[ $body == *'_clicue_flag_canon'* ]]; then
  ok "the row inserts the canonical short spelling"
else
  nope "the row inserts the canonical short spelling"
fi
# A typed prefix must win over the canonical form: typing --rec must not insert -r.
if [[ $body == *'canon != ${pfx}*'* ]]; then
  ok "a typed prefix overrides the canonical spelling"
else
  nope "a typed prefix overrides the canonical spelling" \
       "typing --rec and getting -r inserted would be a silent substitution"
fi

# After a space, options are still offered when the line already carries one.
if [[ $body == *'_clicue_optctx'* ]]; then
  ok "options are offered on an empty prefix while composing options"
else
  nope "options are offered on an empty prefix while composing options" \
       "inserting one long parameter dead-ended the card"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "no forks in the hot path"
# Render and the per-keystroke helpers run on every keystroke. A command
# substitution there is a fork per keystroke — the mistake that once put render
# latency at 87ms via a $(printf) per candidate.
typeset -a hotforks
hotforks=( ${(f)"$(grep -n '\$(_clicue_' $SRCS | grep -v ':[[:space:]]*#' || true)"} )
if (( ${#hotforks} == 0 )); then
  ok "no clicue helper is called through command substitution"
else
  nope "no clicue helper is called through command substitution" "${hotforks[1]}"
fi

# The display label must be measured, and the description looked up by TOKEN.
body=$(awk '/^_clicue_emit_box\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
body=${(F)${(f)body}:#[[:space:]]#\#*}
if [[ $body == *'_clicue_gloss $ent'* ]]; then
  ok "the description is looked up by token, not by display label"
else
  nope "the description is looked up by token, not by display label" \
       "keying on the label returned nothing for every paired row"
fi

# The explain box may be the first box on the card and then needs a real top edge.
body=$(awk '/^_clicue_emit_explain\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'╭'* && $body == *'├'* ]]; then
  ok "the explain box opens the card when nothing precedes it"
else
  nope "the explain box opens the card when nothing precedes it" \
       "a complete invocation has no candidates, so the card had no top edge"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "how a match ends is compsys's declaration"
# What follows an inserted match is per-match DATA handed to us in the compadd
# call: -S '' means append nothing (tar's -A clusters), -S <str> means append that
# (`=` for a value-taking option), no -S at all means a trailing space. clicue used
# to append a space unconditionally, which inserted `--file ` where `--file=` was
# meant and broke cluster-building with `tar -A `.

body=$(awk '/^_clicue_insert\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
body=${(F)${(f)body}:#[[:space:]]#\#*}
if [[ $body == *'_clicue_cs_sfx'* ]]; then
  ok "insertion replays the suffix compsys declared"
else
  nope "insertion replays the suffix compsys declared" \
       "appending a space unconditionally breaks --file= and tar -A"
fi

# "-S with an empty value" and "no -S at all" mean OPPOSITE things, so an
# association cannot represent both with the empty string.
if [[ $body == *"\$'\\0'"* ]]; then
  ok "an empty declared suffix is distinguishable from no declaration"
else
  nope "an empty declared suffix is distinguishable from no declaration"
fi

# The cache must carry it too, or a warm cache regresses what a fresh harvest gets
# right — the worst kind of bug, since it only appears in the SECOND shell.
body=$(awk '/^_clicue_flag_load\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_cs_sfx'* ]]; then
  ok "the flag cache restores the suffix"
else
  nope "the flag cache restores the suffix" \
       "a warm cache would insert a space where a fresh harvest would not"
fi

# A layout change must invalidate old caches; the mtime stamp cannot notice one.
if grep -q '_clicue_flag_fmt' $SRC; then
  ok "the cache carries a format version"
else
  nope "the cache carries a format version" \
       "an old cache would be parsed with the wrong field count"
fi

# Mechanism 1 was measured and rejected; make sure it is not half-present.
if ! grep -q '_clicue_finish' $SRC; then
  ok "no second unshadowed completion pass remains"
else
  nope "no second unshadowed completion pass remains" \
       "placing the candidate moves the completion position: tar - inserted tar -Af"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "familiarity gate is opt-in"
# A verbosity change nobody asked for is the invisible behaviour shift design
# value 1 forbids, so the threshold defaults to off.
body=$(awk '/^_clicue_is_familiar\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'thresh=0'* && $body == *'thresh > 0'* ]]; then
  ok "familiar-percentile defaults to 0 = off"
else
  nope "familiar-percentile defaults to 0 = off"
fi

body=$(awk '/^_clicue_emit_explain\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'to expand'* ]]; then
  ok "a collapsed explanation names the key that opens it"
else
  nope "a collapsed explanation names the key that opens it" \
       "an unexplained collapsed box reads as breakage"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "themes"
# "Is it themeable?" A theme owns colours and glyphs and nothing else. The glyph set
# is a CORRECTNESS concern, not decoration: a glyph the operator's font cannot draw
# renders as a hollow box, which reads as breakage (design value 1).

typeset -ga THEMES=( $DIR/themes/*.zsh(N) )
if (( ${#THEMES} )); then
  ok "found ${#THEMES} theme file(s)"
else
  nope "found theme files" "no themes/*.zsh"
fi
for f in $THEMES; do
  if zsh -n $f; then ok "theme ${f:t:r} parses"; else nope "theme ${f:t:r} parses"; fi
done

# Every theme must define every key the renderer reads, or the card renders with a
# region_highlight spec zsh rejects and no indication why.
typeset -ga TKEYS=( border accent text gloss selbg seltext hint ghost badge badgefg )
typeset -ga GKEYS=( tl tr bl br jl jr v h sel nosel )
# Sourced, not grepped: a theme may put several pairs on one line, and what matters
# is the resulting association, not the formatting.
for f in $THEMES; do
  bad=$(zsh -fc "
    typeset -gA CLICUE_THEME=() CLICUE_GLYPH=()
    source $f
    for k in $TKEYS; do [[ -n \${CLICUE_THEME[\$k]} ]] || print -n \" THEME[\$k]\"; done
    for k in $GKEYS; do (( \${+CLICUE_GLYPH[\$k]} )) || print -n \" GLYPH[\$k]\"; done
  " 2>/dev/null)
  if [[ -z $bad ]]; then
    ok "theme ${f:t:r} defines every key"
  else
    nope "theme ${f:t:r} defines every key" "missing:$bad"
  fi
done

# sel and nosel must be the same width or unselected rows sit a column off
for f in $THEMES; do
  body=$(zsh -fc "typeset -gA CLICUE_THEME=() CLICUE_GLYPH=(); source $f; print -r -- \"\${#CLICUE_GLYPH[sel]}:\${#CLICUE_GLYPH[nosel]}\"" 2>/dev/null)
  if [[ ${body%%:*} == ${body##*:} ]]; then
    ok "theme ${f:t:r} keeps sel and nosel the same width"
  else
    nope "theme ${f:t:r} keeps sel and nosel the same width" "got $body"
  fi
done

# At least one theme must be pure ASCII, as the fallback for a terminal whose font
# or encoding cannot be relied on.
bad='none'
for f in $THEMES; do
  # the glyph values only — comments are prose and may contain anything
  got=$(zsh -fc "
    typeset -gA CLICUE_THEME=() CLICUE_GLYPH=()
    source $f
    print -rn -- \"\${(j::)CLICUE_GLYPH}\"
  " 2>/dev/null)
  LC_ALL=C print -rn -- "$got" | LC_ALL=C grep -qP '[^\x00-\x7F]' || bad=${f:t:r}
done
if [[ $bad != none ]]; then
  ok "an all-ASCII theme exists as a fallback ($bad)"
else
  nope "an all-ASCII theme exists as a fallback" \
       "every theme needs a font that can draw its glyphs"
fi

# The renderer must not hard-code box glyphs any more.
bad=$(grep -n '[╭╮╰╯├┤│─▸]' $DIR/clicue.zsh | grep -v ':[[:space:]]*#' | head -1)
if [[ -z $bad ]]; then
  ok "the renderer hard-codes no box glyphs"
else
  nope "the renderer hard-codes no box glyphs" "$bad"
fi

# Padding a border needs the (p) flag: (l:n::pad:) expands NEITHER a subscripted nor
# a plain parameter in its pad argument, and emits the source text into the border.
bad=$(grep -n '(l:[^)]*\$_clicue_hg' $DIR/clicue.zsh | head -1)
if [[ -z $bad ]]; then
  ok "glyph padding uses the (p) flag so the parameter expands"
else
  nope "glyph padding uses the (p) flag so the parameter expands" "$bad"
fi

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
