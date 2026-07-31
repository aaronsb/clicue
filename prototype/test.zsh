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
typeset -g k w d c body want got word disp leak bad harvest f srcout fbody hl alias_key
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

# Modules whose functions are pure enough to call DIRECTLY. This is what the split
# bought: sections below exercise the real implementations instead of carrying
# hand-copied duplicates that would keep passing after the originals drifted.
# 2>/dev/null because compsys.zsh ends in a `zle -C`, which needs an interactive
# shell — the function definitions above it land regardless.
typeset -g CLICUE_DIR=$DIR
source $DIR/lib/theme.zsh 2>/dev/null
source $DIR/lib/compsys.zsh 2>/dev/null
source $DIR/lib/stats.zsh 2>/dev/null

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
# Calls the REAL _clicue_cs_scan_opts. This section used to carry a hand-copied
# duplicate of the scan, which asserted that the COPY behaved — worthless the moment
# the original drifted. The scan was hoisted out of the compadd shadow into its own
# function so this could stop being a mirror; that is the whole reason it is a
# function.
_scan() {
  _clicue_cs_scan_opts "$@"
  print -r -- "${#_clicue_cs_dsp}|${_clicue_cs_probe:-0}"
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

# ── the suffix declaration, which decides how an inserted match ends ────────
_clicue_cs_scan_opts -J -default- -a words
[[ -z $_clicue_cs_hassfx ]] \
  && ok "no -S is reported as no declaration" \
  || nope "no -S is reported as no declaration" "an ordinary match must get a trailing space"

_clicue_cs_scan_opts -q -S '' -a words
[[ -n $_clicue_cs_hassfx && -z $_clicue_cs_sfxval ]] \
  && ok "-S '' is a declaration with an empty value, not an absence" \
  || nope "-S '' is a declaration with an empty value, not an absence" \
       "tar's clusterable letters depend on telling these apart"

_clicue_cs_scan_opts -qS= -M 'r:|=*' -a words
[[ -n $_clicue_cs_hassfx && $_clicue_cs_sfxval == '=' ]] \
  && ok "clustered -qS= yields the suffix '='" \
  || nope "clustered -qS= yields the suffix '='" "got [$_clicue_cs_sfxval]"

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
# Calls the REAL _clicue_unpack_desc. Also previously a mirror.
#
# compdescribe packs display strings as "<word><padding>-- <description>" so the list
# lines up in COMPSYS's single column. clicue renders name and gloss as separate
# columns, so the prefix has to come off or every row shows its name twice.
_unpack() { _clicue_unpack_desc "$1" "$2"; print -r -- $_clicue_ud }

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

got=$(_unpack foo 'some description')
[[ $got == 'some description' ]] && ok "unprefixed description passes through" \
  || nope "unprefixed description passes through" "got [$got]"

got=$(_unpack foo 'foo -- --bare is implied')
[[ $got == '--bare is implied' ]] && ok "description starting with -- survives" \
  || nope "description starting with -- survives" "got [$got]"

got=$(_unpack rm 'rm -- remove files')
[[ $got == 'remove files' ]] && ok "short word does not over-strip" \
  || nope "short word does not over-strip" "got [$got]"

# Trailing padding must go: compdescribe right-pads display strings to a column
# width, so an unstripped gloss carries invisible spaces into the card and throws
# off every width calculation downstream.
got=$(_unpack foo 'foo -- padded to a column   ')
[[ $got == 'padded to a column' ]] && ok "trailing padding is stripped" \
  || nope "trailing padding is stripped" "got [$got]"

# ── spelling groups and cluster decomposition, on the real functions ────────
# A synthetic flag set, so these assert behaviour rather than this machine's rm(1).
typeset -gA _clicue_flag_desc=() _clicue_flag_alt=()
_clicue_fkey demo -r; _clicue_flag_desc[$_clicue_fk]='recurse'
_clicue_fkey demo -R; _clicue_flag_desc[$_clicue_fk]='recurse'
_clicue_fkey demo --recursive; _clicue_flag_desc[$_clicue_fk]='recurse'
_clicue_fkey demo -f; _clicue_flag_desc[$_clicue_fk]='force'
_clicue_fkey demo --force; _clicue_flag_desc[$_clicue_fk]='force'
# Keys built with _clicue_fkey, the same builder the implementation uses. Writing
# the subscript literally did NOT produce a matching key, so every lookup returned
# nothing and the labels silently fell back to the bare flag — which is exactly the
# failure mode _clicue_fkey exists to prevent, reproduced in the test.
_clicue_fkey demo -r;          _clicue_flag_alt[$_clicue_fk]='-R --recursive'
_clicue_fkey demo -R;          _clicue_flag_alt[$_clicue_fk]='-r --recursive'
_clicue_fkey demo --recursive; _clicue_flag_alt[$_clicue_fk]='-r -R'
_clicue_fkey demo -f;          _clicue_flag_alt[$_clicue_fk]='--force'
_clicue_fkey demo --force;     _clicue_flag_alt[$_clicue_fk]='-f'

_clicue_flag_label demo -r
[[ $_clicue_fl == '-R, -r, --recursive' || $_clicue_fl == '-r, -R, --recursive' ]] \
  && ok "a three-spelling group labels short forms before long ($_clicue_fl)" \
  || nope "a three-spelling group labels short forms before long" "got [$_clicue_fl]"

_clicue_flag_label demo --force
[[ $_clicue_fl == '-f, --force' ]] \
  && ok "reaching a group by its long spelling still shows the short one first" \
  || nope "reaching a group by its long spelling still shows the short one first" "got [$_clicue_fl]"

_clicue_flag_canon demo --recursive
[[ $_clicue_fc == '-r' || $_clicue_fc == '-R' ]] \
  && ok "the canonical spelling is a short form ($_clicue_fc)" \
  || nope "the canonical spelling is a short form" "got [$_clicue_fc] — clusters need the short one"

if _clicue_decompose demo -rf; then
  [[ ${(j: :)_clicue_parts} == '-r -f' ]] \
    && ok "a cluster of documented letters decomposes" \
    || nope "a cluster of documented letters decomposes" "got [${(j: :)_clicue_parts}]"
else
  nope "a cluster of documented letters decomposes" "refused -rf"
fi

if _clicue_decompose demo -rz; then
  nope "a cluster with an undocumented letter is refused" "accepted -rz — z is not a flag here"
else
  ok "a cluster with an undocumented letter is refused"
fi

if _clicue_decompose demo -r; then
  nope "a single flag is not treated as a cluster" "decomposed -r"
else
  ok "a single flag is not treated as a cluster"
fi

# ── the familiarity gate, on the real function ──────────────────────────────
typeset -gA CLICUE_INVOKE=() CLICUE_INVOKE_PCT=() CLICUE_INVOKE_LAST=()
# key built in a variable: an unquoted space in a subscript is a bad pattern, the
# same class of trap as the unquoted pipe that once made every write vanish
typeset -g ikey='demo -rf'
CLICUE_INVOKE[$ikey]=31
CLICUE_INVOKE_PCT[$ikey]=1
_clicue_words=( demo -rf )
zstyle -d ':clicue:*' familiar-percentile 2>/dev/null
if _clicue_is_familiar; then
  nope "the familiarity gate is off unless configured" "collapsed with no threshold set"
else
  ok "the familiarity gate is off unless configured"
fi
zstyle ':clicue:*' familiar-percentile 5
if _clicue_is_familiar; then
  ok "a top-1% invocation is familiar at a 5% threshold"
else
  nope "a top-1% invocation is familiar at a 5% threshold"
fi
CLICUE_INVOKE_PCT[$ikey]=58
if _clicue_is_familiar; then
  nope "a top-58% invocation is not familiar at 5%" "collapsed something rarely run"
else
  ok "a top-58% invocation is not familiar at 5%"
fi
zstyle -d ':clicue:*' familiar-percentile

_clicue_invocation_note
[[ $_clicue_invnote == *'31×'* && $_clicue_invnote == *'58%'* ]] \
  && ok "the invocation note carries the count and the percentile" \
  || nope "the invocation note carries the count and the percentile" "got [$_clicue_invnote]"

_clicue_words=( demo --unseen )
_clicue_invocation_note
[[ -z $_clicue_invnote ]] \
  && ok "an invocation with no history yields no note" \
  || nope "an invocation with no history yields no note" "got [$_clicue_invnote]"

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
# `fpfx` is the EFFECTIVE prefix — $pfx on the first pass, empty on the second, which
# runs only when nothing matched what was typed. The invariant is unchanged: while a
# prefix is in play it decides the spelling.
if [[ $body == *'canon != ${fpfx}*'* ]]; then
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
typeset -ga GKEYS=( tl tr bl br jl jr v h sel nosel
                    k_alias k_function k_builtin k_system k_history k_flag k_sub k_none )
# Sourced, not grepped: a theme may put several pairs on one line, and what matters
# is the resulting association, not the formatting.
for f in $THEMES; do
  # Through the real loader, which merges over the ASCII base. Sourcing the theme in
  # isolation was stricter than the design: a theme that only changes the accent
  # colour is legal, and the renderer reads the MERGED result.
  bad=$(zsh -fc "
    CLICUE_DIR=$DIR
    source $DIR/lib/theme.zsh
    _clicue_theme_load ${f:t:r} >/dev/null 2>&1
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

# Every gutter glyph must be exactly ONE column. A two-column codepoint — anything
# East Asian Wide, or an emoji — shifts the whole row, and the span offsets are
# computed in columns.
for f in $THEMES; do
  bad=$(zsh -fc "
    CLICUE_DIR=$DIR
    source $DIR/lib/theme.zsh
    _clicue_theme_load ${f:t:r} >/dev/null 2>&1
    for k in k_alias k_function k_builtin k_system k_history k_flag k_sub k_none; do
      (( \${#CLICUE_GLYPH[\$k]} == 1 )) || print -n \" \$k\"
    done
  " 2>/dev/null)
  if [[ -z $bad ]]; then
    ok "theme ${f:t:r} gutter glyphs are one column each"
  else
    nope "theme ${f:t:r} gutter glyphs are one column each" "wrong width:$bad"
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
section "the source gutter and matched-prefix emphasis"

body=$(awk '/^_clicue_kind_glyph\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ -n $body ]]; then
  ok "a kind-to-glyph resolver exists"
else
  nope "a kind-to-glyph resolver exists"
fi
# An unknown kind must fall through to a blank, not to a guess. A wrong source marker
# is a confident lie about where a suggestion came from.
if [[ $body == *'k_none'* ]]; then
  ok "an unknown kind gets a blank gutter rather than a guessed glyph"
else
  nope "an unknown kind gets a blank gutter rather than a guessed glyph"
fi

# matchlen must be an ASSOCIATION: a plain array with sparse integer indices fills
# the gaps with empty strings, so ${+arr[n]} is true for every index up to the highest
# set, and the prefix would be emphasised on rows that do not match it.
if grep -q 'typeset -gA _clicue_matchlen' $SRC; then
  ok "matched-prefix lengths are held in an association, not a sparse array"
else
  nope "matched-prefix lengths are held in an association, not a sparse array" \
       "a sparse array reports every index as set"
fi

# Emphasis applies only when the DISPLAYED name starts with what was typed: a grouped
# label reached by its long spelling does not, and bolding its first characters would
# emphasise the wrong thing.
body=$(awk '/^_clicue_emit_box\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'$name == ${_clicue_pfx}*'* ]]; then
  ok "emphasis is gated on the displayed name matching the prefix"
else
  nope "emphasis is gated on the displayed name matching the prefix"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the two lower boxes coexist"
# They were alternatives, and the explanation won — so `ffmpeg -i x -ab` showed 10 of
# 185 options and NO browser, while the 1/185 counter said plainly there were 175 more.
# The boxes answer different questions and one must not silently displace the other.
body=$(awk '/^_clicue_render\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body != *'elif (( total > t1n ))'* ]]; then
  ok "the grid is not an else-branch of the explanation"
else
  nope "the grid is not an else-branch of the explanation" \
       "an explanation would hide the overflow browser"
fi
# The explanation is bounded and allocated first; the grid takes the remainder.
if [[ $body == *'ecap'* && $body == *'gr='* ]]; then
  ok "the explanation is bounded and the grid takes what remains"
else
  nope "the explanation is bounded and the grid takes what remains"
fi
# Budgeted against rows tier 1 will ACTUALLY draw: its allocation absorbs the grid's
# share when there is no overflow, which starved the explanation to one row.
if [[ $body == *'maxlines - t1n - 5'* ]]; then
  ok "the explanation budget uses actual tier-1 rows, not its allocation"
else
  nope "the explanation budget uses actual tier-1 rows, not its allocation"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the card never exceeds the terminal"
# The bug this section exists for: the card was drawn COLUMNS wide, and zsh's
# redisplay refuses to write the last column — it wraps there — so every row's closing
# border was pushed onto a line of its own and the card read as a total malfunction.
#
# It survived a long time for two reasons worth keeping in front of whoever reads this:
# the max-width cap happened to supply the missing column at a 121-column terminal, and
# the old assertions measured the RENDERED STRING, which is 104 characters whether that
# is correct or catastrophic. The invariant is about the BUDGET, so that is what is
# asserted here. A rendered-length assertion cannot express it.
source $DIR/lib/render.zsh 2>/dev/null
zstyle -d ':clicue:*' max-width 2>/dev/null
zstyle -d ':clicue:*' max-lines 2>/dev/null

typeset -gi WFAIL=0 WBAD=0
for c in 20 32 40 47 60 65 80 100 104 110 120 121 122 200; do
  _clicue_layout_width $c
  (( _clicue_lw <= c - 1 )) || { WFAIL=1; WBAD=$c; break }
done
if (( ! WFAIL )); then
  ok "the width is at most COLUMNS-1 at every width tried"
else
  nope "the width is at most COLUMNS-1 at every width tried" \
       "COLUMNS=$WBAD gave ${_clicue_lw}; zsh wraps in the last column"
fi

# The floor must not be honoured by drawing wider than the window. That is how the
# original bug got in: `(( width < 30 )) && width=$COLUMNS` let a preference win LAST.
_clicue_layout_width 20
if (( _clicue_lw == 19 )); then
  ok "a narrow terminal gets a narrow card, not a preferred minimum"
else
  nope "a narrow terminal gets a narrow card, not a preferred minimum" "got ${_clicue_lw}"
fi

# A cap, not a target.
_clicue_layout_width 200
if (( _clicue_lw == 120 )); then
  ok "a very wide terminal caps rather than following the window"
else
  nope "a very wide terminal caps rather than following the window" "got ${_clicue_lw}"
fi
zstyle ':clicue:*' max-width 90
_clicue_layout_width 200
if (( _clicue_lw == 90 )); then
  ok "the cap is configurable"
else
  nope "the cap is configurable" "got ${_clicue_lw}"
fi
zstyle -d ':clicue:*' max-width

# Height is the same discipline, and had the same latent defect: a fixed 14 lines in a
# 12-row window draws the card off the bottom of the screen.
typeset -gi HTFAIL=0 HTBAD=0
for r in 11 14 20 24 30 44 88; do
  _clicue_layout_height $r
  (( _clicue_lh <= r - 6 || _clicue_lh == 5 )) || { HTFAIL=1; HTBAD=$r; break }
done
if (( ! HTFAIL )); then
  ok "the height is bounded by the window at every height tried"
else
  nope "the height is bounded by the window at every height tried" \
       "LINES=$HTBAD gave ${_clicue_lh}"
fi
# max-lines used to default to 14 and bound only the explanation pane, while the card's
# real height was tier1-rows + tier2-rows + 5 with tier2 sized to FILL the window. The
# documented total budget was not a budget. It derives from the window now.
_clicue_layout_height 88
if (( _clicue_lh == 82 )); then
  ok "the height budget derives from the window by default"
else
  nope "the height budget derives from the window by default" "got ${_clicue_lh}"
fi
# An explicit setting is honoured — and still capped by the window, so a configured 40
# in a 24-row terminal cannot draw off the bottom of the screen.
zstyle ':clicue:*' max-lines 20
_clicue_layout_height 88
(( _clicue_lh == 20 )) && _clicue_layout_height 24
if (( _clicue_lh == 18 )); then
  ok "an explicit height is honoured but never exceeds the window"
else
  nope "an explicit height is honoured but never exceeds the window" "got ${_clicue_lh}"
fi
zstyle -d ':clicue:*' max-lines

# The budget must be ENFORCED on the row totals, not merely consulted. Without this the
# height was whatever tier1-rows + tier2-rows happened to add up to.
body=$(awk '/^_clicue_render\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'r1 + r2 + 5 - maxlines'* ]]; then
  ok "the row totals are cut to fit the budget"
else
  nope "the row totals are cut to fit the budget" \
       "a budget nothing checks is a comment, not a constraint"
fi
# The grid gives up rows before tier 1 does: it pages, so a row costs a scroll there
# and a ranked cue here.
if [[ $body == *'cut > r2'* && $body == *'r2 -= cut'* ]]; then
  ok "the grid gives up rows before tier 1 does"
else
  nope "the grid gives up rows before tier 1 does"
fi

# Both are read from the terminal on EVERY render — that is what makes a resize take
# effect on the next keystroke with no SIGWINCH hook. Inline arithmetic in the render
# body is what drifted; the named units are what the assertions above can reach.
body=$(awk '/^_clicue_render\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_layout_width'* && $body == *'_clicue_layout_height'* ]] \
   && [[ $body != *'width=${COLUMNS'* ]]; then
  ok "the render body asks for the layout budget instead of recomputing it"
else
  nope "the render body asks for the layout budget instead of recomputing it"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the card is rebuilt from empty, so its height may vary"
# SPEC used to state that the card CANNOT grow or shrink in response to state, and that
# both boxes pad to a constant total. Measured against a real typing sequence, that is
# simply false — height changes on nearly every keystroke:
#
#   [g] 29  [gi] 21  [git] 17  [git ] 16  [git c] 8  [git commit] 3  [git commit ] 18
#
# It does not mangle, and the reason is not padding. POSTDISPLAY is emptied and rebuilt
# on EVERY redraw (measured: 19 of 19 renders reported pd=0 after the clear, and the
# rebuilt length always equalled the card's own length, so nothing accumulates). ZLE
# then sees a complete new tail and does its own erasing, which is ordinary multi-line
# behaviour it gets right. The original defect was a POSTDISPLAY *grown* without being
# cleared; the clear is what fixed it.
#
# So the invariant worth asserting is the clear, not the height. Asserting constant
# height would encode a constraint the code does not have and does not need.
pbody=$(awk '/^_clicue_pre_redraw\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $pbody == *_clicue_clear* ]]; then
  ok "every redraw clears before it draws"
else
  nope "every redraw clears before it draws" \
       "a POSTDISPLAY appended to without clearing is the original mangling bug"
fi
# The clear must come BEFORE the card is composed, or it erases what was just built.
if [[ ${pbody%%POSTDISPLAY=\"*} == *_clicue_clear* ]]; then
  ok "the clear precedes composing the new card"
else
  nope "the clear precedes composing the new card"
fi
# And the card must be assigned, never appended to, across renders.
if [[ $pbody == *'POSTDISPLAY="${POSTDISPLAY}${ghost}${card}"'* ]]; then
  ok "the card is composed onto a POSTDISPLAY that was just emptied"
else
  nope "the card is composed onto a POSTDISPLAY that was just emptied"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "ranking is an experiment you can interrogate"
# Which metric is right is not knowable from first principles — it is knowable from
# living with the tool, and every improvement here so far started as "that feels off".
# So the metric is switchable and, more importantly, ASKABLE.
source $DIR/lib/candidates.zsh 2>/dev/null
# clicue.zsh loads this; the libs alone do not. Without it EPOCHSECONDS is unset and
# frecency degrades to frequency — which is exactly the assertion below failing for a
# reason that has nothing to do with the ranking code.
zmodload zsh/datetime 2>/dev/null
typeset -gA CLICUE_FREQ=( heavy 100 stale 100 fresh 4 ) CLICUE_LAST=()
typeset -gi NOW=${EPOCHSECONDS:-1785300000}
CLICUE_LAST=( heavy $NOW  stale $(( NOW - 400 * 86400 ))  fresh $NOW )

zstyle ':clicue:*' ranking frequency
_clicue_rank_mode
if [[ $_clicue_rmode == frequency ]]; then
  _clicue_rank_score stale; typeset -gi S1=$_clicue_rscore
  _clicue_rank_score fresh; typeset -gi S2=$_clicue_rscore
  if (( S1 > S2 )); then
    ok "frequency ignores age — a stale favourite outranks a fresh occasional"
  else
    nope "frequency ignores age" "stale=$S1 fresh=$S2"
  fi
else
  nope "the ranking mode is read from zstyle" "got $_clicue_rmode"
fi

# The blend is the point of the exercise: a count from a year ago should not beat
# something used today just because the count is bigger.
zstyle ':clicue:*' ranking frecency
_clicue_rank_mode
_clicue_rank_score heavy; typeset -gi H=$_clicue_rscore
_clicue_rank_score stale; typeset -gi T=$_clicue_rscore
if (( H > T )); then
  ok "frecency separates two equal counts by how recent they are"
else
  nope "frecency separates two equal counts by how recent they are" "heavy=$H stale=$T"
fi
zstyle ':clicue:*' ranking recency
_clicue_rank_mode
_clicue_rank_score fresh; typeset -gi F=$_clicue_rscore
_clicue_rank_score stale; typeset -gi T2=$_clicue_rscore
if (( F > T2 )); then
  ok "recency ignores count entirely"
else
  nope "recency ignores count entirely" "fresh=$F stale=$T2"
fi
# An unknown value must not silently rank by something nobody asked for.
zstyle ':clicue:*' ranking nonsense
_clicue_rank_mode
if [[ $_clicue_rmode == frecency ]]; then
  ok "an unrecognised mode falls back to the documented default"
else
  nope "an unrecognised mode falls back to the documented default" "got $_clicue_rmode"
fi
zstyle -d ':clicue:*' ranking

# The sort key must be wide enough for the widest score the blend can produce, or a
# heavily-used command wraps to the BOTTOM of the card — the failure is invisible in
# the arithmetic and obvious on screen.
cbody=$(awk '/^_clicue_candidates\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $cbody == *'(l:10::0:)'* && $cbody == *'9999999999 - _clicue_rscore'* ]]; then
  ok "the sort key is wide enough for a weighted count"
else
  nope "the sort key is wide enough for a weighted count" \
       "an 8-digit field overflows once a count is multiplied"
fi
# clicue-rank why is the instrument: a ranking you cannot question is one you can only
# have opinions about.
if (( ${+functions[clicue-rank]} )) && \
   [[ $(functions clicue-rank) == *'(why)'* ]]; then
  ok "clicue-rank can be asked to justify an order"
else
  nope "clicue-rank can be asked to justify an order"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the ghost proposes the rest of a remembered line"
# clicue took the ghost from zsh-autosuggestions — correctly, since two writers for one
# purpose fight — but took over only HALF of its job: it proposed the next TOKEN and
# never the rest of a remembered line. So "type a few characters, see the whole command
# from last time, press →" stopped working. Reported as a regression, and it was one.
source $DIR/lib/render.zsh 2>/dev/null
rbody=$(awk '/^_clicue_ghost_stem\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $rbody == *_clicue_history_stem* && $rbody == *_clicue_cue_stem* ]]; then
  ok "the proposal considers both a remembered line and the highlighted cue"
else
  nope "the proposal considers both a remembered line and the highlighted cue"
fi
# A cue the operator is actively navigating must not be overridden by history: they are
# choosing it right now.
if [[ $rbody == *'(( _clicue_engaged )) && _clicue_cue_stem'* ]]; then
  ok "a cue being navigated outranks history"
else
  nope "a cue being navigated outranks history"
fi
hbody=$(awk '/^_clicue_history_stem\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
# $history, not the corpus: the corpus is built from HISTFILE and lags this session.
if [[ $hbody == *'history[(r)'* ]]; then
  ok "it reads the in-memory history, which includes this session"
else
  nope "it reads the in-memory history, which includes this session"
fi
# (b) quoting, or a buffer containing a glob character pattern-matches every other line.
if [[ $hbody == *'${(b)LBUFFER}'* ]]; then
  ok "the buffer is quoted so a glob in it cannot match unrelated lines"
else
  nope "the buffer is quoted so a glob in it cannot match unrelated lines"
fi
# One definition, two callers — the drawer and the legend must agree about whether a
# ghost exists, or `→ accept` is advertised for a ghost that is not there.
if [[ $(awk '/^_clicue_pre_redraw\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'if _clicue_ghost_stem; then'* ]] \
   && [[ $(awk '/^_clicue_hint_segments\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *_clicue_ghost_stem* ]]; then
  ok "the drawn ghost and the advertised ghost still come from one rule"
else
  nope "the drawn ghost and the advertised ghost still come from one rule"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "compsys decides membership; the cache decides presentation"
# Design value 5 in flag position, which is where it had been quietly violated. The
# cached flag set is a snapshot taken at ONE canonical position and replayed at every
# other, so it cannot know what is valid HERE.
#
# [MEASURED] the gap was visible: `rm -r -` re-offered `-r` (already on the line) where
# compsys omits it; `man -a -` re-offered `-a`; `tar -c -` offered all seven cluster
# letters where compsys offers none, because one is chosen and they are exclusive.
body=$(awk '/^_clicue_arg_candidates\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_cs_for == $LBUFFER'* && $body == *'from_compsys=1'* ]]; then
  ok "when compsys has answered for this buffer, its words are the candidate set"
else
  nope "when compsys has answered for this buffer, its words are the candidate set"
fi
# An empty answer from compsys is a DECISION, not a stale cache: overriding it with the
# whole option set would be clicue deciding, which is the thing being stopped.
if [[ $body == *'(( from_compsys )) && break'* ]]; then
  ok "an empty answer from compsys is respected rather than overridden"
else
  nope "an empty answer from compsys is respected rather than overridden"
fi
# Repeatability is why the typed-flag subtraction is confined to the cache path: some
# flags legitimately repeat and only the _arguments spec knows which.
if [[ $body == *'ti < ${#_clicue_words}'* && $body == *'ti = 2'* ]]; then
  ok "the cache path drops options already on the line, first and last token excepted"
else
  nope "the cache path drops options already on the line, first and last token excepted"
fi
# A prefix filter cannot tell a stale harvest from a live one — every flag of every
# command starts with a dash, so they all pass it. Measured: probing `rm -r -` then
# `tar -c -` in one shell put `--no-preserve-root` on tar's card.
if [[ $body == *'$LBUFFER == ${_clicue_cs_for}*'* ]]; then
  ok "a harvest is only reused for a buffer it could still be answering"
else
  nope "a harvest is only reused for a buffer it could still be answering" \
       "a dash-prefixed flag set from another command passes a prefix filter intact"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "flag position is never handed back"
# The flag map is keyed on the ALIAS-RESOLVED path, because _clicue_flag_load and
# _clicue_fkey both resolve before touching it. Scanning it with the TYPED path meant
# every aliased command matched nothing: `ls` emulates `lsd`, the cache held `lsd|...`,
# the scan looked for `ls|`. Measured: `ls -` bailed with render-failed while `cat -`
# drew a full card — which is what made it look like an alias-config problem.
# Matches on the KEY the scan uses, not on the shape of the scan. The loop this
# originally asserted became a subscript filter for speed, and an assertion pinned to
# the old syntax fails on a change that preserves exactly what it was protecting.
if [[ $body == *'_clicue_resolve_path'* && $body == *'${keypfx}\|'* ]]; then
  ok "the flag scan uses the same resolved key the map is written with"
else
  nope "the flag scan uses the same resolved key the map is written with" \
       "an aliased command finds zero options and the card bails"
fi

# An option prefix matching nothing is a typo, not a reason to hand the line to a
# completer. Measured: `cat -l1<Tab>` delegated to complete-word, which REWROTE the
# line to `cat -A`. Losing what was typed is worse than any card.
if [[ $body == *'pass == 2'* && $body == *'_clicue_argnomatch=1'* ]]; then
  ok "a prefix that matches nothing offers the whole option set instead"
else
  nope "a prefix that matches nothing offers the whole option set instead"
fi
# and the card says so, rather than implying these are matches
if [[ $(awk '/^_clicue_render\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'nothing matches'* ]]; then
  ok "and the card says nothing matched, rather than implying these did"
else
  nope "and the card says nothing matched, rather than implying these did"
fi
# The backstop: even with no candidates at all, Tab must not delegate in flag
# position. A leading dash is never a filename.
if [[ $(awk '/^_clicue_accept\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'_clicue_pfx == -*'* ]]; then
  ok "Tab holds the line in flag position instead of delegating"
else
  nope "Tab holds the line in flag position instead of delegating" \
       "delegation there rewrites the line"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the split must not wipe what the modules captured"
# keys.zsh captures state while it is being SOURCED — what owned Tab, which keys we
# bound. A `typeset -g name=''` further down clicue.zsh then silently resets it, and
# the consumers all have plausible fallbacks, so nothing errors and nothing looks
# wrong. Both of these were being wiped since the modularisation:
#
#   _clicue_orig_tab   measured EMPTY in a real shell, so every Tab delegation ran a
#                      hardcoded `expand-or-complete` instead of the operator's actual
#                      completer (`complete-word` here) — visible only as the wrong
#                      completion UI appearing, which reads as clicue misbehaving.
#   _clicue_bound      reset after _clicue_bindall filled it, so clicue-off left every
#                      key from that pass bound.
typeset -gi SRCLINE=$(grep -n 'source \${CLICUE_DIR}' $DIR/clicue.zsh | head -1 | cut -d: -f1)
if (( SRCLINE > 0 )); then
  ok "clicue.zsh sources its modules at a known point"
else
  nope "clicue.zsh sources its modules at a known point"
fi

# Names the modules populate during `source`. Targeted rather than inferred: two of
# these are filled by a FUNCTION CALLED at source time, which no static scan of
# top-level assignments would see.
typeset -ga CAPTURED=( _clicue_orig_tab _clicue_bound _clicue_arrow_orig _clicue_hintparts
                       _clicue_key_accept _clicue_key_dismiss _clicue_key_maximize )
typeset -gi WIPED=0
typeset -g WIPEDNAME=''
# `capname`, not `n`: line 306 declares `local -i n` at script scope, so assigning a
# NAME to it silently yields 0 and this scan matched nothing while reporting success.
# Exactly the variable-reuse trap this suite has recorded twice before.
typeset -g capname late
for capname in $CAPTURED; do
  # a declaration of this name AFTER the source block resets it
  late=$(awk -v n="$capname" -v s=$SRCLINE 'NR>s && $0 ~ ("^typeset .*[ \t]" n "=") {print NR}' $DIR/clicue.zsh)
  if [[ -n $late ]]; then WIPED=1; WIPEDNAME="$capname (line $late)"; break; fi
done
if (( ! WIPED )); then
  ok "nothing captured during source is re-declared after it"
else
  nope "nothing captured during source is re-declared after it" \
       "$WIPEDNAME — the capture is silently discarded and the fallback hides it"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "the grid is clamped, and traversable because of it"
# `s` offers 460-odd commands. The grid used to take everything the terminal could
# spare, so it grew to 68 rows in an 88-row window and the 83-line card shoved the
# scrollback — including the output of the command just run — off the screen. A guidance
# surface that destroys the context it exists to support has inverted its own purpose.
source $DIR/lib/render.zsh 2>/dev/null
source $DIR/lib/keys.zsh 2>/dev/null
body=$(awk '/^_clicue_render\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
# Checks the clamp is USED, not merely computed: a mutation that dropped the assignment
# left the arithmetic in place and this assertion still passed.
if [[ $body == *'clamped=$(( ${LINES:-24} / 3 ))'* && $body == *'clamped < 10'* ]] \
   && [[ $body == *'t2rows=$clamped'* ]]; then
  ok "the grid is a third of the window, floored at 10 rows"
else
  nope "the grid is a third of the window, floored at 10 rows"
fi
if [[ $body == *'clamped > spare'* ]]; then
  ok "and is still bounded by what the window can spare"
else
  nope "and is still bounded by what the window can spare"
fi
if [[ $body == *'_clicue_maxed'* ]]; then
  ok "the operator can override the clamp deliberately"
else
  nope "the operator can override the clamp deliberately"
fi

# Clamping only works if the rest of the list stays reachable. A page is what the
# renderer is SHOWING, published rather than invented here: a PageDown moving by a
# number of its own would disagree with the visible page and with the `page 2/11`
# counter, and the operator would lose their place instead of advancing it.
typeset -gi _clicue_grid_page=42 _clicue_t1n=10
_clicue_page_size
if (( _clicue_ps == 42 )); then
  ok "a page is what the grid is showing"
else
  nope "a page is what the grid is showing" "got ${_clicue_ps}"
fi
_clicue_grid_page=0
_clicue_page_size
if (( _clicue_ps == 10 )); then
  ok "with no grid rendered yet, a page is tier 1"
else
  nope "with no grid rendered yet, a page is tier 1" "got ${_clicue_ps}"
fi

# Every traversal key goes through _clicue_move, so all of them inherit its clamping to
# the list ends AND its "not navigating -> delegate" contract for free. Arithmetic of
# their own would be a second place for the ends to be got wrong.
for w in _clicue_page_down _clicue_page_up _clicue_first_cue _clicue_last_cue; do
  fnbody=$(awk -v n="^${w}\\\\(\\\\)" '$0 ~ n {f=1} f{print} f&&/^}/{exit}' $SRC)
  if [[ $fnbody == *_clicue_move* ]]; then
    ok "${w#_clicue_} moves the selection rather than reimplementing the ends"
  else
    nope "${w#_clicue_} moves the selection rather than reimplementing the ends"
  fi
done

# End is load-bearing (it accepts the ghost, as autosuggestions did). Taking it for
# navigation is only safe under the same modal-only-while-engaged rule the arrows use.
fnbody=$(awk '/^_clicue_end_of_line\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $fnbody == *'_clicue_engaged'* && $fnbody == *'_clicue_accept_ghost'* ]]; then
  ok "End navigates only while engaged, and still accepts the ghost otherwise"
else
  nope "End navigates only while engaged, and still accepts the ghost otherwise"
fi
# ^A is beginning-of-line in every shell the operator has ever used. Home's escape
# sequences are unambiguous; ^A is not worth a second binding for the same action.
if [[ $(awk '/^_clicue_install_arrows\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) != *"'^A'"* ]]; then
  ok "^A is left alone"
else
  nope "^A is left alone" "beginning-of-line is not ours to take"
fi

# A label that outgrows its box produces a line wider than the card — the wrap that
# mangles the display. Latent until the grid label started carrying a page counter,
# which is exactly the kind of growth that finds it.
_clicue_fit_label " browsing 123456/123456 · page 100/100 " 20
if (( ${#_clicue_label} <= 19 )); then
  ok "a label too long for the box is truncated, not allowed to wrap it"
else
  nope "a label too long for the box is truncated, not allowed to wrap it" \
       "${#_clicue_label} > 19: [$_clicue_label]"
fi
for e in _clicue_emit_box _clicue_emit_grid _clicue_emit_explain; do
  fnbody=$(awk -v n="^${e}\\\\(\\\\)" '$0 ~ n {f=1} f{print} f&&/^}/{exit}' $SRC)
  if [[ $fnbody == *_clicue_fit_label* ]]; then
    ok "${e#_clicue_emit_} labels go through the fit"
  else
    nope "${e#_clicue_emit_} labels go through the fit"
  fi
done

# ─────────────────────────────────────────────────────────────────────────────
section "the legend names the next action"
# Calls the REAL _clicue_hint_segments and _clicue_fit_hint. The point of the change
# is that the legend is DERIVED from state, so a test that hand-built the expected
# segments would pass forever after the derivation drifted.
source $DIR/lib/render.zsh 2>/dev/null
source $DIR/lib/keys.zsh 2>/dev/null
typeset -ga _clicue_cands=() _clicue_explain_rows=()
typeset -gi _clicue_info=0 _clicue_sel=1
typeset -g _clicue_pfx='' _clicue_hintfit=''
_clicue_build_hint

hseg() {   # $1 pfx, $2 info, $3.. cands  → REPLY is the joined legend
  _clicue_pfx=$1; _clicue_info=$2; shift 2
  _clicue_cands=( "$@" ); _clicue_sel=1
  _clicue_hint_segments
  REPLY=${(j: · :)_clicue_hintparts}
}

# Tab has ONE rule — it advances your position in the candidate space — but that is a
# MOVE when there is somewhere to move and an INSERT when the cue is already the whole
# answer. The rule is constant; naming the outcome is what makes it visible.
_clicue_explain_rows=()
hseg gi 0 git gitk gio
if [[ $REPLY == 'Tab cycle'* ]]; then
  ok "with somewhere to move, the legend says cycle"
else
  nope "with somewhere to move, the legend says cycle" "$REPLY"
fi

# The reported gh dead end: `gh org<Tab>` offers exactly `org`, which is already typed.
_clicue_explain_rows=( "org"$'\t'"Manage organizations" )
hseg org 0 org
if [[ $REPLY == 'Tab insert'* ]]; then
  ok "when the only cue is already typed, the legend says insert"
else
  nope "when the only cue is already typed, the legend says insert" "$REPLY"
fi
# and it must not advertise browsing a one-item list, or a ghost that cannot exist
if [[ $REPLY != *browse* && $REPLY != *'→'* ]]; then
  ok "inert gestures are not advertised alongside it"
else
  nope "inert gestures are not advertised alongside it" "$REPLY"
fi

# The legend and the KEY read one predicate, not two copies of a condition.
# Matched on the CALL, not on the bare name: the name appears in the prose above both
# call sites, and an assertion that reads a comment keeps passing after the call goes.
# That exact mistake has been made in this suite before.
if [[ $(awk '/^_clicue_accept\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'_clicue_tab_inserts; then'* ]] \
   && [[ $(awk '/^_clicue_hint_segments\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'if _clicue_tab_inserts; then'* ]]; then
  ok "the legend and the key share the predicate rather than restating it"
else
  nope "the legend and the key share the predicate rather than restating it" \
       "a legend that says cycle while the key inserts is worse than no legend"
fi

# Two gestures require _clicue_engaged, which only Tab sets: before the first Tab the
# arrows reach command history and Enter RUNS THE LINE. Advertising `⏎ insert` there
# invited the operator to press Enter expecting text and execute the command instead —
# a legend naming the wrong outcome for a destructive key, which is worse than an inert
# one.
typeset -gi _clicue_engaged=0
_clicue_explain_rows=()
hseg gi 0 git gitk gio
if [[ $REPLY != *'⏎ insert'* && $REPLY != *browse* ]]; then
  ok "an unengaged card advertises neither the arrows nor Enter"
else
  nope "an unengaged card advertises neither the arrows nor Enter" "$REPLY"
fi
_clicue_engaged=1
hseg gi 0 git gitk gio
if [[ $REPLY == *'⏎ insert'* && $REPLY == *browse* ]]; then
  ok "an engaged card advertises both"
else
  nope "an engaged card advertises both" "$REPLY"
fi
# Same gate on the one-cue card, where Enter is the only other key named.
hseg org 0 org
if [[ $REPLY == *'⏎ insert'* ]]; then
  _clicue_engaged=0
  hseg org 0 org
  if [[ $REPLY != *'⏎ insert'* ]]; then
    ok "the gate applies to the insert card too"
  else
    nope "the gate applies to the insert card too" "$REPLY"
  fi
else
  nope "the gate applies to the insert card too" "engaged form lacked it: $REPLY"
fi
_clicue_engaged=1

# In the grid ALL FOUR arrows navigate. `→ accept` was plainly wrong there:
# _clicue_arrow_right tries the grid move first and never reaches the ghost.
typeset -gi _clicue_focus=2 _clicue_grid_page=42 _clicue_grid_lo=11 _clicue_canmax=1
hseg s 0 ${(s: :)"$(print -r -- ${(l:200:: a :)})"}
if [[ $REPLY == *'←→↑↓ navigate'* && $REPLY != *'→ accept'* ]]; then
  ok "the grid legend says all four arrows navigate, and drops the ghost accept"
else
  nope "the grid legend says all four arrows navigate, and drops the ghost accept" "$REPLY"
fi
if [[ $REPLY == *'PgUp/PgDn page'* && $REPLY == *'Home/End ends'* ]]; then
  ok "the grid legend names the traversal keys it depends on"
else
  nope "the grid legend names the traversal keys it depends on" "$REPLY"
fi
# Maximising is offered only where it would change something.
_clicue_canmax=0; typeset -gi _clicue_maxed=0
hseg s 0 a b c d e f g h i j k l m n o p q r s t u v w x y z
if [[ $REPLY != *taller* ]]; then
  ok "maximising is not offered in a window too small to grow into"
else
  nope "maximising is not offered in a window too small to grow into" "$REPLY"
fi
_clicue_canmax=1
hseg s 0 a b c d e f g h i j k l m n o p q r s t u v w x y z
if [[ $REPLY == *'taller'* ]]; then
  ok "and is offered where it would"
else
  nope "and is offered where it would" "$REPLY"
fi
# A single-page grid has no pages to turn.
_clicue_grid_page=500
hseg s 0 a b c d e f g h i j k l m n o p q r s t u v w x y z
if [[ $REPLY != *'PgUp/PgDn'* ]]; then
  ok "a single-page grid does not claim to have pages"
else
  nope "a single-page grid does not claim to have pages" "$REPLY"
fi
_clicue_focus=1; _clicue_grid_page=0; _clicue_grid_lo=0

# A complete invocation has nothing left to propose: the card is pure explanation, and
# every navigation gesture on it is inert.
_clicue_explain_rows=( "-r"$'\t'"recursive" )
hseg '' 0
if [[ $REPLY == 'Esc dismiss' ]]; then
  ok "an explanation-only card advertises only the way out"
else
  nope "an explanation-only card advertises only the way out" "$REPLY"
fi

# Same for an informational card carrying no explanation.
_clicue_explain_rows=()
hseg -x 1 man
if [[ $REPLY == 'Esc dismiss' ]]; then
  ok "an informational card advertises only the way out"
else
  nope "an informational card advertises only the way out" "$REPLY"
fi

# `→ accept` takes the GHOST, so it belongs in the legend only when a stem exists.
_clicue_explain_rows=()
hseg gr 0 grep
if [[ $REPLY == *'→ accept'* ]]; then
  ok "the ghost gesture is advertised when there is a stem to accept"
else
  nope "the ghost gesture is advertised when there is a stem to accept" "$REPLY"
fi
# ONE definition of the stem: clicue.zsh draws it, the legend advertises it.
if [[ $(awk '/^_clicue_pre_redraw\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'if _clicue_ghost_stem; then'* ]]; then
  ok "the drawn ghost and the advertised ghost come from one rule"
else
  nope "the drawn ghost and the advertised ghost come from one rule" \
       "two copies of the rule let the legend disagree with the key"
fi

# Width degradation. The last segment is the escape hatch and must survive: a narrow
# terminal that leaves the operator a card with no advertised way out is the failure
# design value 1 is about.
_clicue_explain_rows=()
hseg gi 0 git gitk gio
typeset -gi HFAIL=0
for w in 60 46 30 22 14; do
  _clicue_fit_hint $w
  (( ${#_clicue_hintfit} <= w )) || { HFAIL=1; break }
  [[ $_clicue_hintfit == *dismiss* ]] || { HFAIL=1; break }
done
if (( ! HFAIL )); then
  ok "the legend fits every width and always keeps the way out"
else
  nope "the legend fits every width and always keeps the way out" \
       "w=$w fit=[$_clicue_hintfit]"
fi
# Even at an absurd width it yields something rather than overflowing the box.
_clicue_fit_hint 3
if (( ${#_clicue_hintfit} <= 3 )); then
  ok "an absurd width truncates rather than overflowing"
else
  nope "an absurd width truncates rather than overflowing" "[$_clicue_hintfit]"
fi
# A join flag takes ONE parameter: `${(j:x:)${a[1,n]} ${a[n]}}` is a bad substitution,
# and it reports at render time — as a card that fails to draw.
if [[ $(awk '/^_clicue_fit_hint\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) != *'j: · :)${_clicue_hintparts[1,'* ]]; then
  ok "the segment join reads a real array, not a word list"
else
  nope "the segment join reads a real array, not a word list"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "cache lifecycle"
# The corpus went a long time with NO staleness check: _clicue_load sourced whatever
# was on disk and trusted it, so it rotted as history grew and packages changed.

if grep -q 'CLICUE_CORPUS_STAMP' $DIR/build-corpus.zsh; then
  ok "the builder emits an input stamp"
else
  nope "the builder emits an input stamp" "without one, staleness cannot be detected"
fi

body=$(awk '/^_clicue_load\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_corpus_stale=1'* ]]; then
  ok "loading records staleness"
else
  nope "loading records staleness"
fi

# A cache built before stamping existed has no stamp at all, which must read as
# stale rather than as current.
body=$(awk '/^_clicue_load\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'${CLICUE_CORPUS_STAMP:-}'* ]]; then
  ok "an unstamped cache counts as stale"
else
  nope "an unstamped cache counts as stale" "a missing stamp must not compare equal"
fi

# The rebuild must not block the prompt, and must not re-fire every prompt.
body=$(awk '/^_clicue_corpus_refresh\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $body == *'_clicue_rebuild_started'* ]]; then
  ok "the rebuild fires at most once per shell"
else
  nope "the rebuild fires at most once per shell" "it would fork on every prompt"
fi
if [[ $body == *'&'* && $body == *'/dev/null'* ]]; then
  ok "the rebuild is detached and silent"
else
  nope "the rebuild is detached and silent" \
       "a stray line here lands in the middle of the operator's prompt"
fi
if [[ $body == *'auto-rebuild'* ]]; then
  ok "the automatic rebuild can be turned off"
else
  nope "the automatic rebuild can be turned off"
fi

# zstat takes ONE + format spec per call; a second is read as a filename, so the
# component silently vanishes. Both stamp implementations must avoid it. [MEASURED]
bad=$(grep -n 'zstat.*+[a-z]* *+[a-z]' $DIR/build-corpus.zsh $DIR/lib/corpus.zsh 2>/dev/null | grep -v ':[[:space:]]*#' | head -1)
if [[ -z $bad ]]; then
  ok "no zstat call passes two + format specs"
else
  nope "no zstat call passes two + format specs" "$bad"
fi

# GC must judge by what the shell can actually run, not by $commands alone — cd is a
# builtin and dropping its cache would cost a needless fork on next use.
body=$(awk '/^_clicue_flags_gc\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
bad=''
for k in commands builtins functions aliases; do
  [[ $body == *"+${k}["* ]] || bad="$bad $k"
done
if [[ -z $bad ]]; then
  ok "GC keeps anything the shell can run"
else
  nope "GC keeps anything the shell can run" "does not consult:$bad"
fi

if grep -q 'clicue-cache' $SRC; then
  ok "clicue-cache exists so staleness is answerable, not guessable"
else
  nope "clicue-cache exists so staleness is answerable, not guessable"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "licensing"
if [[ -r $DIR/../LICENSE ]]; then
  ok "the project carries a LICENSE"
  if grep -qi 'MIT License' $DIR/../LICENSE; then
    ok "it is MIT, matching the zsh plugin norm (autosuggestions, fzf)"
  else
    ok "license is not MIT — fine, but README/packaging should agree"
  fi
else
  nope "the project carries a LICENSE" "unlicensed code is not reusable by anyone"
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
# ─────────────────────────────────────────────────────────────────────────────
section "a card may be shown and still not own Tab"
# `cd `, `pushd `, `popd `, `source ` — the only path-centric commands that document no
# options at all, measured across 40 of them. Nothing for clicue to enumerate, so the
# keystroke belongs to compsys and to muscle memory. The card stays: losing it the
# moment a space is typed was the most jarring thing about an earlier build.
abody=$(awk '/^_clicue_accept\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC)
if [[ $abody == *'(( _clicue_yieldtab ))'* ]]; then
  ok "Tab checks for a yielded position"
else
  nope "Tab checks for a yielded position"
fi
# BEFORE the harvest, which is the entire point. After it, the press had already paid
# for a fork producing 34 directories nothing would display. [MEASURED: 1 fork -> 0]
if [[ ${abody%%_clicue_capture*} == *_clicue_yieldtab* ]]; then
  ok "and does so before paying for a fork"
else
  nope "and does so before paying for a fork" \
       "yielding after the harvest keeps the cost and loses the press anyway"
fi
# The flag is per-render state, so it must be cleared on entry or a yield leaks into
# the next position.
if [[ $(awk '/^_clicue_pre_redraw\(\)/{f=1} f{print} f&&/^}/{exit}' $SRC) == *'_clicue_yieldtab=0'* ]]; then
  ok "the yield is cleared on every redraw rather than latching"
else
  nope "the yield is cleared on every redraw rather than latching"
fi

# ─────────────────────────────────────────────────────────────────────────────
section "habits in argument position"
# The two tier-1 sources, exercised against a SYNTHETIC corpus and a synthetic
# $history — so these assert the split's behaviour rather than this machine's
# shell history, which would make the suite pass or fail by whose laptop ran it.

source $DIR/lib/candidates.zsh 2>/dev/null

typeset -gA CLICUE_INVOKE=(
  'zzcat -pp'  '4'   'zzcat --help' '1'   'zzcat -f' '1'
  'zzls -lat'  '3'   'zzls -l'      '1'
)
typeset -gA CLICUE_INVOKE_LAST=(
  'zzcat -pp'  '2000'  'zzcat --help' '1000'  'zzcat -f' '3000'
  'zzls -lat'  '2000'  'zzls -l'      '9000'
)
# Keys are stored under the SPELLING the operator typed. The canonical form exists only
# inside the builder, where it merges two spellings into one count; the other spelling
# routes here so a lookup by what was typed still resolves. Keying the map canonically
# instead is what silently broke the invocation note and the familiarity gate. [REVIEW]
typeset -gA CLICUE_INVOKE_ALIAS=( 'zzls -alt' 'zzls -lat' )
typeset -gA CLICUE_PATHISH=( zzcat 1 zzls 1 )

typeset -ga reply=()

# Recency, not count. -f is the newest at 1 occurrence; -pp has four and is older.
# Getting this backwards is the whole failure the design note was written to avoid.
reply=(); _clicue_invocation_cues zzcat ''
if [[ ${reply[1]} == -f ]]; then
  ok "invocation cues rank by last-seen, not by count"
else
  nope "invocation cues rank by last-seen, not by count" \
       "got [${reply[1]}] — a count-ranked order would put -pp first"
fi

# One habit, one row, spelled the way it was typed.
reply=(); _clicue_invocation_cues zzls ''
if (( ${reply[(I)-lat]} )) && (( ! ${reply[(I)-alt]} )); then
  ok "a habit is proposed in the spelling last typed"
else
  nope "a habit is proposed in the spelling last typed" \
       "got (${reply}) — expected -lat, never the sorted key -alt"
fi

# The other spelling has to reach the same entry, or the note goes blank for exactly the
# clusters it is meant to recognise.
# Subscript UNQUOTED. `${A['k with space']}` returns empty in zsh — the quotes become
# part of the key rather than grouping it — which is how this assertion first failed
# against a map that was correct.
alias_key=${CLICUE_INVOKE_ALIAS[zzls -alt]}
if [[ $alias_key == 'zzls -lat' ]] && [[ -n ${CLICUE_INVOKE[$alias_key]} ]]; then
  ok "a non-winning spelling resolves to the stored habit"
else
  nope "a non-winning spelling resolves to the stored habit"
fi

reply=(); _clicue_invocation_cues zzcat '--'
if [[ ${#reply} == 1 && ${reply[1]} == --help ]]; then
  ok "invocation cues honour the prefix being typed"
else
  nope "invocation cues honour the prefix being typed" "got (${reply})"
fi

# The BRANCH, not the fixture. Asserting that _clicue_invocation_cues emits no path is
# tautological — it reads a map that holds none. What can actually regress is
# _clicue_arg_candidates choosing the wrong source, so these drive that instead, with a
# history full of paths that must never surface. [REVIEW]
typeset -gA CLICUE_ARGS=() CLICUE_ARGN=()
typeset -g _clicue_cs_for=''; typeset -ga _clicue_cs_words=(); typeset -gi _clicue_optctx=0
typeset -ga _clicue_words=()

branchprobe() {
  local -a lines=( ${(@f)1} zz-sentinel )
  print -rl -- $lines > $SCRATCH/hist
  zsh -c "
    HISTFILE=$SCRATCH/hist HISTSIZE=200 SAVEHIST=200
    fc -R \$HISTFILE
    source ${(q)DIR}/lib/candidates.zsh 2>/dev/null
    # Stubs for the flag machinery. These probes exercise SOURCE SELECTION — which of
    # the two tier-1 sources answers — and the flag path below it belongs to another
    # module. Without them _clicue_arg_candidates aborts on the first undefined
    # function and every probe returns empty, which reads as a passing safety test.
    _clicue_flag_load()  { return 1 }
    _clicue_resolve_path() { typeset -g _clicue_realpath=\$1 }
    _clicue_fkey()       { typeset -g _clicue_fk=\"\$1|\$2\" }
    _clicue_flag_canon() { typeset -g _clicue_fc=\$2 }
    _clicue_flag_label() { typeset -g _clicue_fl=\$2 }
    typeset -gA _clicue_flag_desc=() _clicue_flag_alt=() _clicue_flag_none=() _clicue_disp=()
    typeset -gA CLICUE_INVOKE=( 'zzcat -pp' 4 'zzcat -f' 1 'sudo zzcat -pp' 2 )
    typeset -gA CLICUE_INVOKE_LAST=( 'zzcat -pp' 2000 'zzcat -f' 3000 'sudo zzcat -pp' 2000 )
    # Interpolated UNQUOTED so it splits into key and value. ${(q)3} made 'zzcat 1' one
    # word, so the map held a single malformed key, every probe returned empty, and the
    # two safety assertions passed by asserting nothing. [REVIEW]
    typeset -gA CLICUE_ARGS=() CLICUE_PATHISH=( ${3} )
    typeset -g _clicue_cs_for=''; typeset -ga _clicue_cs_words=(); typeset -gi _clicue_optctx=0
    # (z) needs a PARAMETER NAME. Written as \${(z)${(q)2}} it interpolated to
    # \${(z)zzcat\ }, which zsh reads as the parameter named 'zzcat ' — empty — so
    # _clicue_words was empty in every probe and all three safety assertions were
    # vacuous while appearing to pass. [REVIEW]
    typeset -g buf=${(q)2}
    typeset -ga _clicue_words=( \${(z)buf} )
    typeset -a reply=()
    LBUFFER=\$buf
    _clicue_arg_candidates \${_clicue_words[1]} '' && print -rl -- \$reply
  " 2>/dev/null
}

# A pathish command must not take the whole-line branch, whatever history holds.
hl=( ${(@f)"$(branchprobe 'zzcat /home/someone/gone.md
zzcat -pp' 'zzcat ' 'zzcat 1')"} )
if (( ${#hl} )) && (( ! ${hl[(I)*/*]} )); then
  ok "a pathish command never proposes a path from history"
else
  nope "a pathish command never proposes a path from history" "got (${hl})"
fi

# An ABSENT pathish map means a pre-v3 cache, which is still sourced and still rendered
# from. Unknown must fail safe to flags-only, or every command looks non-pathish for one
# shell after upgrading and `rm <Tab>` offers deleted paths. [REVIEW]
hl=( ${(@f)"$(branchprobe 'zzcat /home/someone/gone.md
zzcat -pp' 'zzcat ' '')"} )
if (( ! ${hl[(I)*/*]} )); then
  ok "an absent pathish map fails safe to flags only"
else
  nope "an absent pathish map fails safe to flags only" "got (${hl})"
fi

# A wrapper with nothing after it cannot say what it will run, so it fails safe too.
# `sudo`, not a zz-prefixed stand-in: the wrapper list is the shipped one, and a
# fixture name that is not on it silently skips the branch under test.
hl=( ${(@f)"$(branchprobe 'sudo rm -rf /var/tmp/build-9931
sudo zzcat -pp' 'sudo ' 'zzcat 1')"} )
if (( ! ${hl[(I)*/*]} )); then
  ok "an unresolved wrapper fails safe to flags only"
else
  nope "an unresolved wrapper fails safe to flags only" "got (${hl})"
fi

# A remembered line may run on past a separator into a different command; the candidate
# is one segment, truncated there.
hl=( ${(@f)"$(branchprobe 'zzgit status && rm -rf node_modules
zzgit pull' 'zzgit ' '')"} )
if (( ! ${hl[(I)*rm*]} )); then
  ok "a candidate stops at a separator rather than carrying a second command"
else
  nope "a candidate stops at a separator rather than carrying a second command" \
       "got (${hl})"
fi

# The other half needs a real $history, which is a special parameter this shell cannot
# reassign — `typeset -ga history` fails with "can't change type of autoloaded
# parameter". So these run in a child with a synthetic HISTFILE, which also keeps the
# suite from asserting against whoever's laptop is running it.
# The trailing sentinel is load-bearing: `fc -R` in a non-interactive shell does not
# surface the LAST line of the file, so without it the newest entry — the one every
# recency assertion here turns on — is silently absent and the test reads as a ranking
# bug. [MEASURED: 5 lines in, 4 in $history]
histprobe() {
  local -a lines=( ${(@f)1} zz-sentinel )
  print -rl -- $lines > $SCRATCH/hist
  zsh -c "
    HISTFILE=$SCRATCH/hist HISTSIZE=200 SAVEHIST=200
    fc -R \$HISTFILE
    source ${(q)DIR}/lib/candidates.zsh 2>/dev/null
    typeset -a reply=()
    LBUFFER=${(q)2}
    _clicue_history_lines ${(q)2} ${(q)3} && print -rl -- \$reply
  " 2>/dev/null
}

typeset -a hl=( ${(@f)"$(histprobe 'zzssh other@host
zzssh user@older
zzssh user@newest' 'zzssh user@' 'user@')"} )

# Values ARE the point for a command whose arguments are not paths, and the newest
# occurrence leads — the one signal de-duplication does not distort.
if [[ ${hl[1]} == 'user@newest' ]]; then
  ok "history lines keep values and lead with the newest"
else
  nope "history lines keep values and lead with the newest" "got (${hl})"
fi

# The candidate must still START with the prefix, or _clicue_cue_stem produces no stem
# and _clicue_insert splices the line at the wrong place.
if [[ ${hl[1]} == user@* ]]; then
  ok "a multi-token candidate still begins at the cursor's own word"
else
  nope "a multi-token candidate still begins at the cursor's own word" \
       "got [${hl[1]}] — the stem arithmetic in _clicue_cue_stem needs this"
fi

# A glob in the buffer must not turn the lookup into a pattern match over history.
hl=( ${(@f)"$(histprobe 'zzglob other
zzglob * literal' 'zzglob *' '*')"} )
if [[ ${hl[1]} == '* literal' ]]; then
  ok "a glob in the buffer is matched literally"
else
  nope "a glob in the buffer is matched literally" \
       "got (${hl}) — an unquoted lookup matches every line instead"
fi

# The same defect in the other direction: the typed word is removed from the buffer by
# LENGTH, never by `${LBUFFER%$pfx}`. Pattern-stripping a word that carries a glob
# removes the wrong amount of line — and losing what you typed is the worst outcome
# this project has, already recorded once for delegation in flag position.
for f in $DIR/lib/keys.zsh $DIR/lib/candidates.zsh; do
  # Comments stripped first — both files explain the bad form in prose directly above
  # the good one, and prose must not satisfy a code assertion. Same idiom as above.
  fbody=${(F)${(f)"$(<$f)"}:#[[:space:]]#\#*}
  if [[ $fbody == *'${LBUFFER%$'* || $fbody == *'${buf%$'* ]]; then
    nope "${f:t} splices by length, not by pattern" \
         "a glob in the typed word eats the wrong amount of buffer"
  else
    ok "${f:t} splices by length, not by pattern"
  fi
done

unset CLICUE_INVOKE CLICUE_INVOKE_LAST CLICUE_INVOKE_DISP CLICUE_PATHISH

print -r -- "${PASS} passed, ${FAIL} failed"
(( FAIL == 0 ))
