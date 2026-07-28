#!/usr/bin/env zsh
# clicue — corpus builder (prototype)
#
# Produces a cache the plugin can source cheaply at shell startup:
#   $XDG_CACHE_HOME/clicue/corpus.zsh
#
# Sources, in precedence order (later does NOT overwrite earlier):
#   1. compsys-adjacent: aliases + functions are self-describing
#   2. whatis / mandb  — 31k prebuilt distro-maintained glosses
#
# Frequency is DERIVED from shell history, never instrumented. HIST_IGNORE_SPACE
# therefore works as a per-command opt-out for free. See SPEC.md.

emulate -L zsh
setopt extended_glob null_glob

local cache_dir=${XDG_CACHE_HOME:-$HOME/.cache}/clicue
mkdir -p $cache_dir
local out=$cache_dir/corpus.zsh
local tmp=$out.$$

typeset -A gloss kind

# Only keep glosses for commands that actually exist here. The full whatis index
# carries ~2x entries for things not installed; storing them is pure startup tax.
typeset -A installed
local c
for c in ${(k)commands} ${(k)functions} ${(k)aliases} ${(k)builtins}; do
  installed[$c]=1
done

# ── 1. whatis / mandb ─────────────────────────────────────────────────────────
# Format:  name[, name2] (section)   - description
local line names section desc n
if (( $+commands[whatis] )); then
  whatis -w '*' 2>/dev/null | while IFS= read -r line; do
    [[ $line == *'('*')'*-* ]] || continue
    names=${line%%\(*}
    section=${${line#*\(}%%\)*}
    desc=${line#*\) }
    desc=${desc#*- }
    desc=${desc##[[:space:]]#}
    desc=${desc%%[[:space:]]#}
    [[ -z $desc ]] && continue
    # user (1) and admin (8) commands only — skip library/syscall sections
    [[ $section == (1|8|1p)* ]] || continue
    for n in ${(s:,:)names}; do
      n=${n##[[:space:]]#}; n=${n%%[[:space:]]#}
      [[ -z $n ]] && continue
      [[ -n ${gloss[$n]} ]] && continue
      (( ${+installed[$n]} )) || continue
      gloss[$n]=$desc
      kind[$n]=system
    done
  done
fi

# ── 2. frequency, derived from history ────────────────────────────────────────
typeset -A freq
local histfile=${HISTFILE:-$HOME/.zsh_history}
if [[ -r $histfile ]]; then
  # strip EXTENDED_HISTORY ': <ts>:<dur>;' prefix, take the command word
  sed 's/^: [0-9]*:[0-9]*;//' $histfile 2>/dev/null \
    | awk '{print $1}' \
    | grep -E '^[a-zA-Z0-9_.:+-]+$' \
    | sort | uniq -c | sort -rn \
    | while read -r c n; do
        freq[$n]=$c
      done
fi

# ── emit ──────────────────────────────────────────────────────────────────────
{
  print -r -- "# clicue corpus cache — generated, do not edit"
  print -r -- "# built: $(date -Iseconds)"
  print -r -- "typeset -gA CLICUE_GLOSS CLICUE_KIND CLICUE_FREQ"
  print -r -- "CLICUE_GLOSS=("
  for n in ${(k)gloss}; do
    print -r -- "  ${(qq)n} ${(qq)gloss[$n]}"
  done
  print -r -- ")"
  print -r -- "CLICUE_KIND=("
  for n in ${(k)kind}; do
    print -r -- "  ${(qq)n} ${(qq)kind[$n]}"
  done
  print -r -- ")"
  print -r -- "CLICUE_FREQ=("
  for n in ${(k)freq}; do
    print -r -- "  ${(qq)n} ${(qq)freq[$n]}"
  done
  print -r -- ")"
} > $tmp

mv -f $tmp $out

print -r -- "clicue corpus built: $out"
print -r -- "  glosses:   ${#gloss}"
print -r -- "  frequency: ${#freq}"
print -r -- "  size:      $(du -h $out | cut -f1)"
