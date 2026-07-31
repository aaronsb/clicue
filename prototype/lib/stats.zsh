#!/usr/bin/env zsh
# clicue — statistics about the operator's own habits
#
# The one thing no manual page knows: what THIS operator actually runs. Everything
# here reads the corpus maps (CLICUE_INVOKE / _PCT / _LAST) which are derived from
# shell history at build time and never instrumented — so HIST_IGNORE_SPACE works as
# a per-command opt-out for free.

# Declared at file scope, not left to _clicue_load. An undefined association read with
# a subscript is an ERROR in zsh, not an empty string — corpus.zsh records the same
# hazard for the maps it owns — and this file is reachable before any corpus is loaded.
typeset -gA CLICUE_INVOKE_ALIAS

# How often the operator has actually run THIS invocation, and how recently.
# Their own habits are the one thing no manual page knows, and it is the input
# the familiarity gate needs.
# Sets _clicue_invnote. Called from render, so it must not fork.
_clicue_invocation_note() {
  local key="${(j: :)_clicue_words}"
  # Resolve the spelling actually typed to the one the corpus stored. Two spellings of
  # one cluster accumulate as a single habit, and the winner is whichever was typed
  # most recently — so the OTHER spelling has to route here or the note silently goes
  # blank for exactly the invocations it is meant to recognise. [REVIEW]
  key=${CLICUE_INVOKE_ALIAS[$key]:-$key}
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
  key=${CLICUE_INVOKE_ALIAS[$key]:-$key}
  local pct=${CLICUE_INVOKE_PCT[$key]:-}
  [[ -n $pct ]] || return 1
  (( pct <= thresh ))
}
