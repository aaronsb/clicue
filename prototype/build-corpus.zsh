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

# ── 3. argument frequency, per command, also derived from history ─────────────
# For each history line: split into segments on | ; && || (each segment is its
# own invocation, which is also how command position is decided at runtime),
# then emit cmd->token pairs for every word after the command.
#
# awk rather than a zsh read-loop: this walks ~100k history lines.
# clicue is about commands and their properties, not filesystem navigation.
# For these, the "arguments" in history are paths — compsys does that far
# better (slashes, continuation, trailing-slash semantics) and clicue must not
# compete with it.
typeset -A pathish
local pc
for pc in cd pushd popd ls ll la cat bat less more head tail wc sort diff \
          vim nvim nano vi code subl emacs micro \
          cp mv rm mkdir rmdir touch chmod chown chgrp ln stat file du df \
          source . open xdg-open tar zip unzip gzip gunzip rsync scp \
          mount umount dd shred realpath dirname basename tree; do
  pathish[$pc]=1
done

typeset -A argrank argcount
if [[ -r $histfile ]]; then
  local cmd tok cnt
  sed 's/^: [0-9]*:[0-9]*;//' $histfile 2>/dev/null \
    | awk '
        {
          n = split($0, segs, /\|\||&&|[|;]/)
          for (s = 1; s <= n; s++) {
            m = split(segs[s], w, /[ \t]+/)
            ci = 0
            for (i = 1; i <= m; i++) if (w[i] != "") { ci = i; break }
            if (!ci) continue
            cmd = w[ci]
            if (cmd !~ /^[a-zA-Z0-9_.:+-]+$/) continue
            for (i = ci + 1; i <= m; i++) {
              t = w[i]
              if (t == "") continue
              # flags, and plain words (subcommands). skip paths, globs, quotes,
              # substitutions — those are data, not reusable cues.
              if (t !~ /^-{1,2}[a-zA-Z0-9][a-zA-Z0-9_-]*$/ && t !~ /^[a-zA-Z][a-zA-Z0-9_-]*$/) continue
              print cmd "\t" t
            }
          }
        }' \
    | sort | uniq -c | sort -rn \
    | while read -r cnt cmd tok; do
        [[ -z $tok ]] && continue
        (( ${+pathish[$cmd]} )) && continue
        # a token that looks like a path is data, not a reusable cue
        [[ $tok == */* || $tok == '~'* || $tok == .* ]] && continue
        (( ${#${(s: :)argrank[$cmd]}} >= 40 )) && continue   # cap per command
        argrank[$cmd]="${argrank[$cmd]} $tok"
        argcount[${cmd}\|${tok}]=$cnt
      done
fi

# ── 4. whole-invocation frequency, recency, and percentile ────────────────────
# Per-token counts answer "which flags do I use". The WHOLE invocation answers
# something different: "do I know this command by heart" — which is what gates
# how much explanation to show. `ls -lat` is a different fact from `ls` plus `-l`.
#
# Recency comes along for free: EXTENDED_HISTORY already stamps every line, so no
# instrumentation is added here either.
typeset -A invoke invlast invpct
if [[ -r $histfile ]]; then
  # NOT `local key cnt lst`: cnt is already a local from section 3 and holds a
  # value, and re-declaring a set local PRINTS it — that is how a stray `cnt=''`
  # ended up on stdout.
  local key lst
  sed 's/^: \([0-9]*\):[0-9]*;/\1\t/' $histfile 2>/dev/null \
    | awk -F'\t' '
        {
          ts = 0; line = $0
          if (NF >= 2 && $1 ~ /^[0-9]+$/) { ts = $1; line = $2 }
          n = split(line, segs, /\|\||&&|[|;]/)
          for (s = 1; s <= n; s++) {
            m = split(segs[s], w, /[ \t]+/)
            ci = 0
            for (i = 1; i <= m; i++) if (w[i] != "") { ci = i; break }
            if (!ci) continue
            cmd = w[ci]
            if (cmd !~ /^[a-zA-Z0-9_.:+-]+$/) continue
            # key on the command plus its FLAG tokens only. Paths and values are
            # data — including them would make every invocation unique and the
            # count meaningless.
            key = cmd; nf = 0
            for (i = ci + 1; i <= m; i++) {
              if (w[i] ~ /^-{1,2}[a-zA-Z0-9][a-zA-Z0-9_-]*$/) { key = key " " w[i]; nf++ }
            }
            if (!nf) continue
            print key "\t" ts
          }
        }' \
    | awk -F'\t' '{ c[$1]++; if ($2+0 > last[$1]) last[$1] = $2+0 }
                  END { for (k in c) print c[k] "\t" k "\t" last[k] }' \
    | sort -rn \
    | while IFS=$'\t' read -r cnt key lst; do
        [[ -z $key ]] && continue
        invoke[$key]=$cnt
        invlast[$key]=$lst
      done

  # Percentile by RANK among distinct invocations, so "top 10%" means "in the most
  # frequent tenth of the things you actually run" — a threshold that reads the
  # same whatever the size of the history.
  local -i ninv=${#invoke} rank=0
  if (( ninv > 0 )); then
    for key in ${(k)invoke}; do
      invpct[$key]=0
    done
    # Walk in descending count order. The count is zero-padded so a plain string
    # sort orders it numerically, and the separator is a real tab — `print -r`
    # does NOT expand \t, so writing it as an escape would leave the field
    # unsplittable and every percentile identical.
    local -a ordered=()
    ordered=( ${(@f)"$(for key in ${(k)invoke}; do
                         print -r -- "${(l:9::0:)invoke[$key]}"$'\t'"$key"
                       done | sort -r | cut -f2-)"} )
    for key in $ordered; do
      (( rank++ ))
      invpct[$key]=$(( (rank * 100 + ninv - 1) / ninv ))
    done
  fi
fi

# ── emit ──────────────────────────────────────────────────────────────────────
{
  print -r -- "# clicue corpus cache — generated, do not edit"
  print -r -- "# built: $(date -Iseconds)"
  print -r -- "typeset -gA CLICUE_GLOSS CLICUE_KIND CLICUE_FREQ CLICUE_ARGS CLICUE_ARGN \\"
  print -r -- "            CLICUE_INVOKE CLICUE_INVOKE_PCT CLICUE_INVOKE_LAST"
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
  print -r -- "CLICUE_ARGS=("
  for n in ${(k)argrank}; do
    print -r -- "  ${(qq)n} ${(qq)${argrank[$n]## }}"
  done
  print -r -- ")"
  print -r -- "CLICUE_ARGN=("
  for n in ${(k)argcount}; do
    print -r -- "  ${(qq)n} ${(qq)argcount[$n]}"
  done
  print -r -- ")"
  print -r -- "CLICUE_INVOKE=("
  for n in ${(k)invoke}; do
    print -r -- "  ${(qq)n} ${(qq)invoke[$n]}"
  done
  print -r -- ")"
  print -r -- "CLICUE_INVOKE_PCT=("
  for n in ${(k)invpct}; do
    print -r -- "  ${(qq)n} ${(qq)invpct[$n]}"
  done
  print -r -- ")"
  print -r -- "CLICUE_INVOKE_LAST=("
  for n in ${(k)invlast}; do
    print -r -- "  ${(qq)n} ${(qq)invlast[$n]}"
  done
  print -r -- ")"
} > $tmp

mv -f $tmp $out

print -r -- "clicue corpus built: $out"
print -r -- "  glosses:   ${#gloss}"
print -r -- "  frequency: ${#freq}"
print -r -- "  arg cmds:  ${#argrank}"
print -r -- "  arg pairs: ${#argcount}"
print -r -- "  invocations: ${#invoke}"
print -r -- "  size:      $(du -h $out | cut -f1)"
