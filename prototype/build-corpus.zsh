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
local c=''
for c in ${(k)commands} ${(k)functions} ${(k)aliases} ${(k)builtins}; do
  installed[$c]=1
done

# ── 1. whatis / mandb ─────────────────────────────────────────────────────────
# Format:  name[, name2] (section)   - description
local line='' names='' section='' desc='' n=''
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
typeset -A freq lastseen
local histfile=${HISTFILE:-$HOME/.zsh_history}
if [[ -r $histfile ]]; then
  # Count AND last-seen, in one pass. Recency used to be discarded here — the `sed`
  # stripped the timestamp before awk ever saw it — which left frequency as the only
  # ranking signal available for command position. Keeping it costs nothing: the line
  # is already being parsed, and EXTENDED_HISTORY has already stamped it.
  local c='' n='' lst=''
  sed 's/^: \([0-9]*\):[0-9]*;/\1\t/' $histfile 2>/dev/null \
    | awk -F'\t' '
        {
          ts = 0; line = $0
          if (NF >= 2 && $1 ~ /^[0-9]+$/) { ts = $1; line = $2 }
          split(line, w, /[ \t]+/)
          cmd = w[1]
          if (cmd !~ /^[a-zA-Z0-9_.:+-]+$/) next
          c[cmd]++
          if (ts + 0 > last[cmd]) last[cmd] = ts + 0
        }
        END { for (k in c) print c[k] "\t" k "\t" last[k] }' \
    | sort -rn \
    | while IFS=$'\t' read -r c n lst; do
        [[ -z $n ]] && continue
        freq[$n]=$c
        lastseen[$n]=$lst
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
local pc=''
for pc in cd pushd popd ls ll la cat bat less more head tail wc sort diff \
          vim nvim nano vi code subl emacs micro \
          cp mv rm mkdir rmdir touch chmod chown chgrp ln stat file du df \
          source . open xdg-open tar zip unzip gzip gunzip rsync scp \
          mount umount dd shred realpath dirname basename tree; do
  pathish[$pc]=1
done

typeset -A argrank argcount
if [[ -r $histfile ]]; then
  local cmd='' tok='' cnt=''
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
# something different: what the operator actually typed as a unit. `ls -lat` is a
# different fact from `ls` plus `-l`.
#
# Recency comes along for free: EXTENDED_HISTORY already stamps every line, so no
# instrumentation is added here either.
#
# ── what belongs in a key, and why it splits on pathish ───────────────────────
# This map now feeds the argument-position card, not only the familiarity gate, so a
# key has to be something worth PROPOSING rather than merely worth counting. Three
# rules, each earned by junk found in a real corpus:
#
#   1. A single-dash token containing hyphens is not a flag. `-home-aaron-Projects-x`
#      passed the old test and was stored as an invocation of `cd`; a mangled path
#      offered even once costs more trust than the feature earns. Clusters are letters
#      and digits only, long options carry the second dash.
#
#   2. Cluster spellings are CANONICALISED for the key and remembered for display.
#      `-lat` and `-alt` are one habit typed two ways; keyed raw they were two entries
#      of 1 each, so neither could ever rank. The key sorts the letters, the display
#      form is whichever spelling was typed most recently.
#
#   3. Leading word tokens count as part of the invocation for NON-pathish commands.
#      Dropping them discarded `git clone` — the dominant git habit — while keeping
#      `git --tags`, because the old rule required a flag. For pathish commands the
#      word after the command is a path, so those stay flags-only. That is the same
#      split the card uses (docs/design-notes/habits-in-argument-position.md), applied
#      once here rather than guessed at twice.
#
# NOT filtered on a minimum count. Under HIST_IGNORE_ALL_DUPS a line typed identically
# every time appears exactly once, so a count of 1 is the signature of the MOST
# habitual invocations, not of noise (SPEC: "history frequency ≠ usage frequency").
# Recency separates junk from habit here; frequency cannot.
typeset -A invoke invlast invpct invalias
if [[ -r $histfile ]]; then
  # NOT `local key cnt lst`: cnt is already a local from section 3 and holds a
  # value, and re-declaring a set local PRINTS it — that is how a stray `cnt=''`
  # ended up on stdout.
  local key='' lst='' disp=''
  sed 's/^: \([0-9]*\):[0-9]*;/\1\t/' $histfile 2>/dev/null \
    | awk -F'\t' -v PATHISH="${(kj: :)pathish}" '
        BEGIN { np = split(PATHISH, pa, " "); for (pi = 1; pi <= np; pi++) ps[pa[pi]] = 1 }
        # A long option, or a short cluster of letters/digits. The length bound keeps a
        # run-on token from posing as a cluster; real ones are short.
        # A long option, optionally carrying its value with `=`. The value is dropped
        # and only the option name kept, for the same reason a separate value token is
        # skipped — keeping it makes every invocation unique. Without the `=` form,
        # `ls --color=auto` matched nothing, hit the "no tokens" test, and the WHOLE
        # invocation was discarded rather than merely losing one flag. [REVIEW]
        function isflag(t) {
          if (t ~ /^--[a-zA-Z0-9][a-zA-Z0-9-]*(=.*)?$/) return 1
          if (t ~ /^-[a-zA-Z0-9]+$/ && length(t) <= 9) return 1
          return 0
        }
        function flagname(t,   e) {
          e = index(t, "=")
          return (e > 0) ? substr(t, 1, e - 1) : t
        }
        # Sort the letters of a short cluster so one habit has one key. Insertion sort
        # over substr rather than split(s, a, "") — the empty field separator is a GNU
        # extension and this has to run wherever awk does.
        function canon(t,   L, i, j, c, out, a) {
          if (t !~ /^-[a-zA-Z0-9][a-zA-Z0-9]+$/) return t
          L = length(t) - 1
          for (i = 1; i <= L; i++) a[i] = substr(t, i + 1, 1)
          for (i = 2; i <= L; i++) {
            c = a[i]
            for (j = i - 1; j >= 1 && a[j] > c; j--) a[j + 1] = a[j]
            a[j + 1] = c
          }
          out = "-"
          for (i = 1; i <= L; i++) out = out a[i]
          return out
        }
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
            key = cmd; disp = cmd; nt = 0
            # Leading subcommands, for commands whose arguments are not paths. Capped at
            # two (`gh org list`) and stopped by the first token that is not a plain
            # word, so a URL or a filename ends the run instead of joining the key.
            i = ci + 1
            if (!(cmd in ps)) {
              while (i <= m && nt < 2 && w[i] ~ /^[a-zA-Z][a-zA-Z0-9_-]*$/) {
                key = key " " w[i]; disp = disp " " w[i]; nt++; i++
              }
            }
            # Flags, wherever they fall in the rest of the segment. Values between them
            # are data and are skipped, which is what keeps a count meaningful.
            for (; i <= m; i++) {
              # `--` is an end-of-options marker, not an option. Acting on it would key
              # `grep -- -x file` as `grep -x`, claiming a flag the operator explicitly
              # marked as NOT one. [REVIEW]
              if (w[i] == "--") break
              if (isflag(w[i])) {
                fn = flagname(w[i])
                key = key " " canon(fn); disp = disp " " fn; nt++
              }
            }
            if (!nt) continue
            print key "\t" disp "\t" ts
          }
        }' \
    | awk -F'\t' '
        { c[$1]++
          seen[$1 SUBSEP $2] = 1
          if ($3+0 > last[$1]) { last[$1] = $3+0; d[$1] = $2 }
        }
        END {
          # Emit under the SPELLING, never under the canonical key. The canonical form
          # exists to make two spellings accumulate as one habit; it must not become
          # the name of that habit, because everything that looks an invocation up does
          # so with the line the operator actually typed. Keying canonically silently
          # broke _clicue_invocation_note and the familiarity gate for exactly the
          # multi-letter clusters they are meant to recognise. [REVIEW]
          for (k in c) print c[k] "\t" d[k] "\t" last[k] "\t" ""
          # Every OTHER spelling of the same habit, pointing at the one that won. This
          # is what lets a lookup with a non-winning spelling still resolve.
          for (s in seen) {
            split(s, p, SUBSEP)
            if (p[2] != d[p[1]]) print "0\t" p[2] "\t0\t" d[p[1]]
          }
        }' \
    | sort -rn \
    | while IFS=$'\t' read -r cnt key lst alias; do
        [[ -z $key ]] && continue
        if [[ -n $alias ]]; then
          invalias[$key]=$alias
          continue
        fi
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

# ── input stamp ───────────────────────────────────────────────────────────────
# Cheap enough to recompute on every shell start: zstat is a builtin, so this costs
# no forks. History mtime+size covers "have I run more commands"; the mtimes of the
# $path directories cover "has anything been installed or removed" without walking
# every binary.
zmodload -F zsh/stat b:zstat 2>/dev/null
# One `+` spec per zstat call: a second is parsed as a FILENAME, not as another
# format, so `zstat -A st +mtime +size f` fails and the component vanishes silently.
# [MEASURED]
local -a st=() st2=()
local _clicue_stamp="v4"   # must match _clicue_corpus_stamp in lib/corpus.zsh
if [[ -r $histfile ]]; then
  zstat -A st +mtime $histfile 2>/dev/null && zstat -A st2 +size $histfile 2>/dev/null \
    && _clicue_stamp+=":h${st[1]}.${st2[1]}"
fi
local d=''
for d in $path; do
  [[ -d $d ]] || continue
  zstat -A st +mtime $d 2>/dev/null && _clicue_stamp+=":${st[1]}"
done

# ── emit ──────────────────────────────────────────────────────────────────────
{
  print -r -- "# clicue corpus cache — generated, do not edit"
  print -r -- "# built: $(date -Iseconds)"
  # A stamp of the INPUTS, so a stale cache can be detected rather than trusted.
  # The flag cache has had this since v2; the corpus went without one for far longer
  # and simply rotted as history grew and packages came and went.
  #
  # Format version first: an added field or changed layout must invalidate, and an
  # input stamp cannot notice that.
  print -r -- "CLICUE_CORPUS_STAMP=${(qq)_clicue_stamp}"
  print -r -- "typeset -gA CLICUE_GLOSS CLICUE_KIND CLICUE_FREQ CLICUE_ARGS CLICUE_ARGN \\"
  print -r -- "            CLICUE_INVOKE CLICUE_INVOKE_PCT CLICUE_INVOKE_LAST CLICUE_LAST \\"
  print -r -- "            CLICUE_INVOKE_ALIAS CLICUE_PATHISH"
  # Which commands take paths rather than reusable cues. Emitted rather than
  # duplicated into the runtime: the list decides both what section 3 collects and
  # what the card proposes, and two copies of a 56-entry judgement call will drift.
  print -r -- "CLICUE_PATHISH=("
  for n in ${(k)pathish}; do
    print -r -- "  ${(qq)n} 1"
  done
  print -r -- ")"
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
  # Last-seen epoch per command, so ranking can weigh recency without a rebuild.
  print -r -- "CLICUE_LAST=("
  for n in ${(k)lastseen}; do
    print -r -- "  ${(qq)n} ${(qq)lastseen[$n]}"
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
  # Other spellings of a habit, pointing at the one that won. A lookup keyed on the
  # line as TYPED resolves through here when the operator reached for the spelling
  # that is not the most recent one — which is what keeps the invocation note and the
  # familiarity gate working across `-lat` and `-alt`.
  print -r -- "CLICUE_INVOKE_ALIAS=("
  for n in ${(k)invalias}; do
    print -r -- "  ${(qq)n} ${(qq)invalias[$n]}"
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
print -r -- "  stamp:     ${_clicue_stamp[1,40]}..."
print -r -- "  size:      $(du -h $out | cut -f1)"
