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
              CLICUE_INVOKE CLICUE_INVOKE_PCT CLICUE_INVOKE_LAST CLICUE_LAST
  [[ -r $CLICUE_CACHE ]] || return 1
  source $CLICUE_CACHE
  # Compared AFTER sourcing, since the expected stamp is stored in the cache itself.
  # A cache built before stamping existed has no stamp at all, which counts as stale.
  _clicue_corpus_stamp
  [[ ${CLICUE_CORPUS_STAMP:-} == $_clicue_stamp_now ]] || _clicue_corpus_stale=1
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
        # Three distinct states, and they must read differently. Showing the same
        # "press Tab" line after a harvest that came back empty would send the
        # operator round the same loop for ever.
        _clicue_resolve_cmd $_clicue_cmd
        if (( ${+_clicue_flag_none[$_clicue_realcmd]} )); then
          if [[ $_clicue_realcmd != $_clicue_cmd ]]; then
            _clicue_g="no documented options for ${_clicue_realcmd}"
          else
            _clicue_g='no documented options'
          fi
        else
          _clicue_g='press Tab to load this command'"'"'s options'
        fi
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

# ── staleness ────────────────────────────────────────────────────────────────
# The corpus went a long time with no staleness check at all: _clicue_load sourced
# whatever was on disk and trusted it, so it quietly rotted as history grew and as
# packages came and went. The flag cache had the right pattern all along; this is it
# applied to the older artifact.
#
# Recomputed on every shell that draws a card, so it must cost no forks — zstat is a
# builtin. History mtime+size answers "have I run more commands"; the mtimes of the
# $path directories answer "has anything been installed or removed" without walking
# every binary.
zmodload -F zsh/stat b:zstat 2>/dev/null

typeset -g _clicue_corpus_stale=0
typeset -g _clicue_rebuild_started=0
typeset -gi _clicue_gc_dropped=0

_clicue_corpus_stamp() {
  local -a st st2
  _clicue_stamp_now="v2"   # v2 adds CLICUE_LAST (per-command recency)
  local hf=${HISTFILE:-$HOME/.zsh_history}
  if [[ -r $hf ]]; then
    # One `+` spec per call: a second is read as a FILENAME, so `+mtime +size` fails
    # and the component disappears with no error. [MEASURED]
    zstat -A st +mtime $hf 2>/dev/null && zstat -A st2 +size $hf 2>/dev/null \
      && _clicue_stamp_now+=":h${st[1]}.${st2[1]}"
  fi
  local d
  for d in $path; do
    [[ -d $d ]] || continue
    zstat -A st +mtime $d 2>/dev/null && _clicue_stamp_now+=":${st[1]}"
  done
}

# Rebuild without blocking the prompt. The builder already writes atomically
# (tmp + mv -f), so a reader during a rebuild sees either the old file or the new one,
# never a partial. Once per shell: a rebuild that keeps firing because the stamp is
# still stale would fork on every prompt.
_clicue_corpus_refresh() {
  (( _clicue_corpus_stale )) || return 0
  (( _clicue_rebuild_started )) && return 0
  _clicue_rebuild_started=1
  local auto=yes
  zstyle -s ':clicue:*' auto-rebuild auto 2>/dev/null || auto=yes
  [[ $auto == (no|off|0) ]] && return 0
  # detached, output discarded: this is maintenance, not something the operator asked
  # to watch, and a stray line here would land in the middle of their prompt
  ( zsh -i -c "source ${CLICUE_DIR}/build-corpus.zsh" >/dev/null 2>&1 & ) 2>/dev/null
  return 0
}

# Drop cached flag sets for commands that no longer exist. One file per command ever
# used, so this grows quietly; small, but there is no reason to keep entries for
# something uninstalled.
_clicue_flags_gc() {
  local dir=${XDG_CACHE_HOME:-$HOME/.cache}/clicue/flags
  [[ -d $dir ]] || return 0
  local f cmd
  # Sets a variable rather than printing, so no caller needs a command substitution.
  # This one is operator-invoked and not on the hot path, but the no-forks guard is
  # deliberately strict with no carve-outs — a guard with exceptions is worth less
  # than the convention it enforces.
  _clicue_gc_dropped=0
  for f in $dir/*.zsh(N); do
    cmd=${f:t:r}
    (( ${+commands[$cmd]} || ${+builtins[$cmd]} || ${+functions[$cmd]} || ${+aliases[$cmd]} )) && continue
    rm -f -- $f && (( _clicue_gc_dropped++ ))
  done
  return 0
}

clicue-cache() {
  local cachedir=${XDG_CACHE_HOME:-$HOME/.cache}/clicue
  case ${1:-status} in
    (status)
      _clicue_load
      _clicue_corpus_stamp
      print -r -- "corpus:  $CLICUE_CACHE"
      if [[ -r $CLICUE_CACHE ]]; then
        print -r -- "  glosses      ${#CLICUE_GLOSS}"
        print -r -- "  invocations  ${#CLICUE_INVOKE}"
        print -r -- "  built        ${$(grep -m1 '^# built:' $CLICUE_CACHE 2>/dev/null)#\# built: }"
        if [[ ${CLICUE_CORPUS_STAMP:-} == $_clicue_stamp_now ]]; then
          print -r -- "  state        current"
        elif [[ -z ${CLICUE_CORPUS_STAMP:-} ]]; then
          print -r -- "  state        STALE — built before input stamping; run clicue-cache rebuild"
        else
          print -r -- "  state        STALE — history or installed commands changed"
        fi
      else
        print -r -- "  state        absent — run clicue-cache rebuild"
      fi
      print -r -- "flags:   $cachedir/flags"
      print -r -- "  commands     $(print -rl -- $cachedir/flags/*.zsh(N) | grep -c . )"
      print -r -- "  theme        ${_clicue_theme_name}"
      ;;
    (rebuild)
      zsh -i -c "source ${CLICUE_DIR}/build-corpus.zsh" || return 1
      _clicue_loaded=0
      _clicue_corpus_stale=0
      _clicue_load
      ;;
    (gc)
      _clicue_flags_gc
      print -r -- "dropped ${_clicue_gc_dropped} stale flag cache file(s)"
      ;;
    (clear)
      rm -rf -- $cachedir
      _clicue_loaded=0
      print -r -- "cleared $cachedir — it is all derived data, so this is always safe"
      ;;
    (*)
      print -u2 "usage: clicue-cache [status|rebuild|gc|clear]"
      return 1
      ;;
  esac
  return 0
}
