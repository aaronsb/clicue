#!/usr/bin/env zsh
# clicue — corpus access
#
# The description database and its lookup. Built offline by build-corpus.zsh from
# whatis/mandb plus shell history, loaded lazily so shell startup pays nothing and
# the first card pays ~8ms once.
#
# Gloss lookup is the one place that decides what text a row carries, so it is also
# where the precedence between sources lives: compsys's own description, then the
# flag set, then the corpus, then the operator's usage count as an honest fallback.

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
