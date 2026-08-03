# clicue — generated zsh shim (protocol v@CLICUE_VERSION@). Do not edit;
# regenerate with `eval "$(clicue init zsh)"`.
#
# The shim owns mechanics only: hooks, key capture/delegation, POSTDISPLAY
# painting, and the socket. Every decision is the daemon's (ADR-100). On any
# failure the card is ABSENT, never degraded (spec/protocol.md §8).

# ── functions are defined unconditionally (testable via `zsh -c source`);
#    installation happens only in an interactive ZLE shell, at the bottom.

# ── JSON: escape a string for embedding in a JSON string literal ─────────────
# Backslash FIRST, then quote, then control chars as \u00XX. The common case
# (no specials) must stay cheap: this runs per keystroke on $BUFFER.
_clicue_json_esc() {
  local s=$1
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  if [[ $s == *[$'\x01'-$'\x1f']* ]]; then
    local out='' ch
    local -i i cp
    for (( i = 1; i <= ${#s}; i++ )); do
      ch=${s[i]}
      if [[ $ch == [$'\x01'-$'\x1f'] ]]; then
        printf -v cp '%d' "'$ch"
        printf -v ch '\\u%04x' $cp
      fi
      out+=$ch
    done
    s=$out
  fi
  REPLY=$s
}

# ── JSON: unescape a string value (serde_json's output escapes) ──────────────
# Split on literal `\\` first: afterwards every remaining backslash starts a
# simple escape, so plain substitutions cannot double-process. Rejoin with a
# single backslash at the end.
_clicue_json_unesc() {
  local s=$1
  if [[ $s != *'\'* ]]; then REPLY=$s; return 0; fi
  # $'' quoting: the separator variables must hold the REAL characters —
  # a $var in ${(ps.$var.)} is used literally, with no escape processing.
  local bb=$'\\\\' b=$'\\'
  local -a parts=( "${(@ps.$bb.)s}" )
  local -a dec=()
  local p pre hex ch
  for p in "${(@)parts}"; do
    p=${p//'\n'/$'\n'}
    p=${p//'\t'/$'\t'}
    p=${p//'\r'/$'\r'}
    p=${p//'\b'/$'\b'}
    p=${p//'\f'/$'\f'}
    p=${p//'\"'/\"}
    p=${p//'\/'//}
    while [[ $p == *'\u'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]* ]]; do
      pre=${p%%'\u'[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*}
      hex=${p[${#pre}+3,${#pre}+6]}
      printf -v ch "\u$hex"
      p="${pre}${ch}${p[${#pre}+7,-1]}"
    done
    dec+=( "$p" )
  done
  REPLY=${(pj.$b.)dec}
}

# ── cut: strip through the FIRST occurrence of a literal needle ─────────────
# `${j#*"$k"}` reads as one scan but probes every prefix length — quadratic,
# and 433ms [MEASURED] against a 12KB reply with the needle near the end
# (vs 0.24ms for this idiom). Every per-keystroke parse below goes through
# here; `#*` on anything reply-sized is the shim's one forbidden move.
_clicue_cut() {
  local pre=${1%%"$2"*}
  [[ $pre == "$1" ]] && return 1
  REPLY=${1[${#pre}+${#2}+1,-1]}
  return 0
}

# ── JSON: extract the RAW (still-escaped) value of a string field ────────────
# Scans for the closing quote by counting trailing backslashes — a quote
# preceded by an even number of them ends the string. Length arithmetic for
# every strip: `#`/`%` strip PATTERNS under GLOB_SUBST (spec/keys.md I1's
# hazard, and the prototype's most-repeated scar).
_clicue_jget_str() {
  local k='"'$2'":"'
  _clicue_cut "$1" "$k" || return 1
  local j=$REPLY
  local out='' seg t
  while true; do
    seg=${j%%'"'*}
    [[ $seg == "$j" ]] && return 1
    out+=$seg
    j=${j[${#seg}+2,-1]}
    t=${seg##*[^\\]}
    if (( ${#t} % 2 == 0 )); then REPLY=$out; return 0; fi
    out+='"'
  done
}

_clicue_jget_num() {
  local k='"'$2'":'
  [[ $1 == *"$k"[0-9]* ]] || return 1
  _clicue_cut "$1" "$k" || return 1
  REPLY=${REPLY%%[^0-9]*}
  return 0
}

# ── spans: [{"start":N,"end":N,"style":"S"},...] → triplet array ────────────
# Boundary is `],"ack"` — ack is the field serde emits after spans, and the
# raw sequence cannot occur inside a JSON string (its quotes would be
# escaped). Styles come from themes and carry no quotes or brackets.
typeset -ga _clicue_rh=()
_clicue_spans() {
  _clicue_rh=()
  _clicue_cut "$1" '"spans":[' || return 0
  local j=${REPLY%%'],"ack"'*}
  [[ -n $j ]] || return 0
  # One split into objects, then field strips on ~40-char strings — `#*`
  # is quadratic only in what it scans, and each object is tiny. The old
  # loop re-stripped the whole remainder per object: 74ms for 165 spans.
  # a literal `}` in the flag delimiter would close the ${…}; the p flag
  # takes the separator from a variable instead (the unescaper's idiom)
  local sep='},{'
  local -a objs=( "${(@ps.$sep.)j}" )
  local obj st en sty
  for obj in "${(@)objs}"; do
    st=${${obj#*'"start":'}%%[^0-9]*}
    en=${${obj#*'"end":'}%%[^0-9]*}
    sty=${obj#*'"style":"'}
    sty=${sty%%'"'*}
    [[ -n $st && -n $en ]] && _clicue_rh+=( $st $en "$sty" )
  done
  return 0
}

# ── history: unacked $history entries as `,"hist":[[n,"line"],...]` ─────────
# From $history, NEVER $BUFFER — a space-prefixed line never enters history,
# so HIST_IGNORE_SPACE stays a free opt-out (spec/protocol.md §5a). First
# call anchors at the current event: replaying a lifetime of history through
# a 32-entry batch window would take thousands of keystrokes to say nothing
# the daemon's own corpus build does not already know.
_clicue_hist_json() {
  REPLY=''
  local -i cur=${HISTCMD:-0}
  (( cur > 0 )) || return 0
  if (( _clicue_hist_acked == 0 )); then
    _clicue_hist_acked=$cur
    return 0
  fi
  (( cur > _clicue_hist_acked )) || return 0
  local out='' line
  local -i i n=0
  for (( i = _clicue_hist_acked; i < cur && n < 32; i++ )); do
    line=${history[$i]}
    [[ -n $line ]] || continue
    _clicue_json_esc "$line"
    out+="${out:+,}[$i,\"$REPLY\"]"
    (( n++ ))
  done
  [[ -n $out ]] && REPLY=',"hist":['$out']'
  return 0
}

# ── transport ────────────────────────────────────────────────────────────────
_clicue_connect() {
  [[ -n $_clicue_fd ]] && return 0
  if ! zsocket $_clicue_sock 2>/dev/null; then
    if (( ! _clicue_spawned )); then
      # Auto-spawn at most once per shell (spec §9); detached, silent. The
      # card is simply absent this event; the next keystroke connects.
      _clicue_spawned=1
      ( command clicue daemon >/dev/null 2>&1 & ) 2>/dev/null
    fi
    return 1
  fi
  _clicue_fd=$REPLY
  return 0
}

_clicue_disconnect() {
  [[ -n $_clicue_fd ]] && exec {_clicue_fd}>&- 2>/dev/null
  _clicue_fd=
}

# One request line out, one reply line in, 5ms read deadline (spec §8). One
# reconnect attempt per event, never more — reconnect costs 0.26ms measured,
# but a wedged daemon must cost one deadline, not several.
_clicue_rpc() {
  (( _clicue_dead )) && return 1
  local -i attempt
  local buf chunk
  for (( attempt = 1; attempt <= 2; attempt++ )); do
    _clicue_connect || return 1
    if syswrite -o $_clicue_fd "$1"$'\n' 2>/dev/null; then
      buf=''
      while [[ $buf != *$'\n' ]]; do
        if ! sysread -i $_clicue_fd -t 0.005 chunk 2>/dev/null; then
          buf=''
          break
        fi
        buf+=$chunk
      done
      if [[ -n $buf ]]; then
        REPLY=${buf%$'\n'}
        return 0
      fi
    fi
    _clicue_disconnect
  done
  return 1
}

# ── painting: POSTDISPLAY is shared; strip only what is OURS ────────────────
# Foreign content (zsh-autosuggestions et al.) is preserved by suffix-
# stripping our stored copies, exactly the prototype's tenancy discipline.
_clicue_unpaint() {
  region_highlight=( ${region_highlight:#*memo=clicue*} )
  if [[ -n $_clicue_card && $POSTDISPLAY == *"$_clicue_card" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_clicue_card"}
  fi
  _clicue_card=''
  if [[ -n $_clicue_ghost && $POSTDISPLAY == *"$_clicue_ghost" ]]; then
    POSTDISPLAY=${POSTDISPLAY%"$_clicue_ghost"}
  fi
  _clicue_ghost=''
}

# $1 card  $2 ghost; spans in _clicue_rh (CHARACTER offsets into the card —
# region_highlight is character-indexed, and the daemon owns the conversion
# so the shim never decodes UTF-8).
_clicue_paint() {
  _clicue_unpaint
  [[ -z $1 && -z $2 ]] && return 0
  local -i gbase=$(( ${#BUFFER} + ${#POSTDISPLAY} ))
  local -i base=$(( gbase + ${#2} ))
  POSTDISPLAY="${POSTDISPLAY}${2}${1}"
  _clicue_ghost=$2
  _clicue_card=$1
  (( ${#2} )) && region_highlight+=( "$gbase $base ${_clicue_gstyle:-fg=8},memo=clicue" )
  local -i i
  for (( i = 1; i + 2 <= ${#_clicue_rh}; i += 3 )); do
    region_highlight+=(
      "$(( base + _clicue_rh[i] )) $(( base + _clicue_rh[i+1] )) ${_clicue_rh[i+2]},memo=clicue" )
  done
  return 0
}

# ── one reply, applied ───────────────────────────────────────────────────────
# Sets _clicue_action (consume|delegate|insert|yield) and _clicue_instext.
# An error frame silences the shim for the shell's lifetime and stashes the
# message for `clicue doctor` (spec §10) — silent means NO card, visibly.
_clicue_apply() {
  local j=$1
  _clicue_action=delegate
  _clicue_instext=''
  if [[ $j == *'"error":'* ]]; then
    _clicue_dead=1
    if _clicue_jget_str "$j" error; then
      _clicue_json_unesc "$REPLY"
      _clicue_err=$REPLY
    fi
    _clicue_unpaint
    return 1
  fi
  if _clicue_jget_num "$j" ack; then
    (( REPLY > _clicue_hist_acked )) && _clicue_hist_acked=$REPLY
  fi
  local card='' ghost=''
  if _clicue_jget_str "$j" card; then
    _clicue_json_unesc "$REPLY"
    card=$REPLY
  fi
  if _clicue_jget_str "$j" ghost; then
    _clicue_json_unesc "$REPLY"
    ghost=$REPLY
  fi
  # The daemon owns the theme; the shim never invents a colour.
  if _clicue_jget_str "$j" ghost_style && [[ -n $REPLY ]]; then
    _clicue_gstyle=$REPLY
  fi
  _clicue_spans "$j"
  _clicue_paint "$card" "$ghost"
  if [[ $j == *'"action":"consume"'* ]]; then
    _clicue_action=consume
  elif [[ $j == *'"action":"insert"'* ]]; then
    _clicue_action=insert
    _clicue_instrip=0
    if _clicue_jget_str "$j" text; then
      _clicue_json_unesc "$REPLY"
      _clicue_instext=$REPLY
    fi
    _clicue_jget_num "$j" strip && _clicue_instrip=$REPLY
  elif [[ $j == *'"action":"yield"'* ]]; then
    _clicue_action=yield
  fi
  return 0
}

# ── requests ─────────────────────────────────────────────────────────────────
# $1 = event JSON fragment. Builds the full request into REPLY. A pending
# harvest fragment (set by _clicue_harvest) rides exactly one request.
_clicue_request() {
  local ev=$1
  _clicue_hist_json
  local hist=$REPLY
  _clicue_json_esc "$BUFFER"
  local buf=$REPLY
  REPLY='{"v":'$_clicue_v',"session":{"pid":'$$',"start":'$_clicue_start'},"event":'$ev',"buffer":"'$buf'","cursor":'${CURSOR:-0}',"cols":'${COLUMNS:-80}',"lines":'${LINES:-24}',"keymap":"'${KEYMAP:-main}'"'$hist$_clicue_pending'}'
  _clicue_pending=''
}

# ── compsys capture: the compadd shadow (spec/compsys-bridge.md §B) ─────────
# Drives compsys through documented interfaces only. The shadow APPENDS
# -O/-D and hands everything else to the builtin — never round-trips
# compadd's body as text (B1). Raw output crosses the wire; the daemon owns
# grouping, labels and storage (Z3).

# Scan a compadd argument list. Sets _clicue_csd (display array),
# _clicue_cs_probe, _clicue_cs_hassfx, _clicue_cs_sfxval.
_clicue_cs_scan() {
  _clicue_csd=(); _clicue_cs_probe=''; _clicue_cs_hassfx=''; _clicue_cs_sfxval=''
  local -i i
  local a dv
  for (( i = 1; i <= $#; i++ )); do
    a=${@[i]}
    # words follow the separator; a candidate may merely LOOK like an option
    [[ $a == - || $a == -- ]] && break
    [[ $a == -?* && $a != --* ]] || continue
    case ${a[-1]} in
      # -d takes the next word, so it is last in its cluster; compdescribe
      # emits it CLUSTERED (-ld), so an exact == -d test never matches (B3)
      (d) if [[ -z $dv ]]; then
            dv=${@[i+1]}
            if [[ -n ${(P)dv+x} ]]; then
              _clicue_csd=( "${(@P)dv}" )
            else
              _clicue_csd=( ${=${${dv#\(}%\)}} )   # literal (a b c) form
            fi
          fi ;;
      # caller-supplied -O/-A: the completer probing ITSELF — the first -O
      # wins, stealing it corrupts _git's layout (B2)
      (O|A) _clicue_cs_probe=1 ;;
      (S) _clicue_cs_hassfx=1; _clicue_cs_sfxval=${@[i+1]} ;;
    esac
    [[ $a == -[A-Za-z]#S?* && $a != --* ]] && \
      { _clicue_cs_hassfx=1; _clicue_cs_sfxval=${a#*S} }
  done
  return 0
}

_clicue_cap_fn() {
  _clicue_cs_words=(); _clicue_cs_descs=(); _clicue_cs_ipfx=''
  _clicue_cs_sfxw=(); _clicue_cs_sfxv=()
  compadd() {
    # what compsys treats as already on the line: _tar consumes the dash
    # into IPREFIX and completes bare letters (B5)
    _clicue_cs_ipfx=$IPREFIX
    _clicue_cs_scan "$@"
    local -a dsp=( "${(@)_clicue_csd}" )
    local probe=$_clicue_cs_probe sfx=$_clicue_cs_sfxval hassfx=$_clicue_cs_hassfx
    if [[ -n $probe ]]; then
      builtin compadd "$@" 2>/dev/null
      return $?
    fi
    local -a w
    builtin compadd -O w -D dsp "$@" 2>/dev/null
    (( ${#w} )) || return 1
    _clicue_cs_words+=( "${(@)w}" )
    local a
    if (( hassfx )); then
      # PARALLEL arrays, not an association keyed inline (Z1: an unescaped
      # | in a subscript stores under a key the read never looks at)
      for a in "${(@)w}"; do
        _clicue_cs_sfxw+=( "$a" )
        _clicue_cs_sfxv+=( "$sfx" )
      done
    fi
    if (( ${#dsp} == ${#w} )); then
      _clicue_cs_descs+=( "${(@)dsp}" )
    else
      # one placeholder PER WORD, split on the empty separator (B6)
      _clicue_cs_descs+=( ${(s::)${(l:${#w}::@:):-}} )
    fi
    return 0
  }
  # list-grouped decides whether descriptions survive to compadd: with it
  # on, curl - measured 664 words and ZERO descriptions (B7). Borrowed for
  # THIS call, restored in an always block.
  local -a _lg
  local -i _lg_had=0
  zstyle -g _lg ':completion:*' list-grouped 2>/dev/null && _lg_had=1
  zstyle ':completion:*' list-grouped false
  {
    _main_complete
  } always {
    # Suppression must come AFTER _main_complete: it recomputes
    # compstate[insert]/[list] from the operator's styles, and under
    # `menu select=1` a pre-set '' is overwritten — the capture then
    # inserted the first candidate into the LIVE buffer and opened the
    # full menu listing over the card ('ffmpeg -' + Tab) [MEASURED].
    # compstate is honored at widget RETURN, so last write wins.
    compstate[insert]=''
    compstate[list]=''
    if (( _lg_had )); then
      zstyle ':completion:*' list-grouped "${_lg[@]}"
    else
      zstyle -d ':completion:*' list-grouped
    fi
    unfunction compadd 2>/dev/null
  }
  return 0
}

# One harvest object from the capture arrays into REPLY.
# $1 pos  $2 path  $3 live (1/0). Words capped so a pathological completer
# cannot push the frame toward MAX_FRAME.
_clicue_cs_json() {
  local pos=$1 path=$2
  local lv=false
  (( $3 )) && lv=true
  if (( ${#_clicue_cs_words} > 800 )); then
    _clicue_cs_words=( "${(@)_clicue_cs_words[1,800]}" )
    _clicue_cs_descs=( "${(@)_clicue_cs_descs[1,800]}" )
  fi
  local -a wj=() dj=() sj=()
  local x kw
  for x in "${(@)_clicue_cs_words}"; do
    _clicue_json_esc "$x"; wj+=( '"'$REPLY'"' )
  done
  for x in "${(@)_clicue_cs_descs}"; do
    _clicue_json_esc "$x"; dj+=( '"'$REPLY'"' )
  done
  local -i i
  for (( i = 1; i <= ${#_clicue_cs_sfxw}; i++ )); do
    _clicue_json_esc "${_clicue_cs_sfxw[i]}"; kw=$REPLY
    _clicue_json_esc "${_clicue_cs_sfxv[i]}"
    sj+=( '"'$kw'":"'$REPLY'"' )
  done
  local pj paj ij
  _clicue_json_esc "$pos";            pj=$REPLY
  _clicue_json_esc "$path";           paj=$REPLY
  _clicue_json_esc "$_clicue_cs_ipfx"; ij=$REPLY
  REPLY='{"pos":"'$pj'","path":"'$paj'","live":'$lv',"iprefix":"'$ij'","words":['${(j:,:)wj}'],"descs":['${(j:,:)dj}'],"sfx":{'${(j:,:)sj}'}}'
}

# Mechanical colon path of the buffer's last segment: non-flag words,
# excluding the word still being typed. A mirror of the daemon's own
# derivation, not a decision — the daemon re-derives authoritatively.
_clicue_argpath() {
  local seg=${BUFFER##*[\|\;\&]}
  seg=${seg##[[:space:]]#}
  local -i trailing=0
  [[ $seg == *[[:space:]] ]] && trailing=1
  local -a words=( ${(z)seg} )
  (( ${#words} )) || { REPLY=''; return 1 }
  local -i upto=${#words}
  (( trailing )) || (( upto-- ))
  (( upto >= 1 )) || { REPLY=''; return 1 }
  local out=${words[1]} w
  local -i i
  for (( i = 2; i <= upto; i++ )); do
    w=${words[i]}
    [[ -n $w && $w != -* ]] && out+=":$w"
  done
  REPLY=$out
  return 0
}

# The harvest: live capture at the operator's buffer (compsys's membership
# answer for THIS position), then `p ` + `p -` per un-harvested ancestor
# path (H1/H2), buffer swapped and restored with no redraw between. Runs
# once per buffer (the prototype's _clicue_cs_for comparison) and keeps a
# session memo of harvested paths — storage authority is the daemon's (Z3).
_clicue_harvest() {
  [[ $BUFFER == *[^[:space:]]*[[:space:]]* ]] || return 0
  [[ $_clicue_cs_for == "$BUFFER" ]] && return 0
  _clicue_cs_for=$BUFFER
  _clicue_argpath || return 0
  local path=$REPLY
  local -a hj=()
  # The live capture must not move the line either — compstate suppression
  # is the mechanism, this restore is the guarantee (same discipline as the
  # ancestor loop below).
  local lbuf=$BUFFER
  local -i lcur=$CURSOR
  { zle _clicue_cap 2>/dev/null } always { BUFFER=$lbuf; CURSOR=$lcur }
  _clicue_cs_json "$lbuf" "$path" 1
  hj+=( "$REPLY" )
  local -a parts=( ${(s.:.)path} )
  local acc='' seg spaced sbuf pos mip
  local -i scur
  local -a mw md msw msv
  for seg in $parts; do
    acc=${acc:+$acc:}$seg
    (( ${+_clicue_cs_done[$acc]} )) && continue
    _clicue_cs_done[$acc]=1
    spaced=${acc//:/ }
    mw=(); md=(); msw=(); msv=(); mip=''
    sbuf=$BUFFER; scur=$CURSOR
    for pos in "$spaced " "$spaced -"; do
      BUFFER=$pos; CURSOR=${#BUFFER}
      { zle _clicue_cap 2>/dev/null } always { BUFFER=$sbuf; CURSOR=$scur }
      mw+=( "${(@)_clicue_cs_words}" ); md+=( "${(@)_clicue_cs_descs}" )
      msw+=( "${(@)_clicue_cs_sfxw}" ); msv+=( "${(@)_clicue_cs_sfxv}" )
      [[ -n $_clicue_cs_ipfx ]] && mip=$_clicue_cs_ipfx
    done
    _clicue_cs_words=( "${(@)mw}" ); _clicue_cs_descs=( "${(@)md}" )
    _clicue_cs_sfxw=( "${(@)msw}" ); _clicue_cs_sfxv=( "${(@)msv}" )
    _clicue_cs_ipfx=$mip
    _clicue_cs_json "$spaced -" "$acc" 0
    hj+=( "$REPLY" )
  done
  _clicue_pending=',"pending":{"harvests":['${(j:,:)hj}']}'
  return 0
}

# ── hello: the name universes only a live shell can enumerate ───────────────
# Sent once, before the first redraw. Aliases carry their expansions (the
# gloss for an alias IS its expansion); functions and builtins are names.
_clicue_hello() {
  local -a parts=()
  local k
  for k in ${(k)aliases}; do
    _clicue_json_esc "$k";           local ek=$REPLY
    _clicue_json_esc "${aliases[$k]}"
    parts+=( '"'$ek'":"'$REPLY'"' )
  done
  local aliases_json='{'${(j:,:)parts}'}'
  parts=()
  for k in ${(k)functions}; do
    # completion internals are never command candidates (sources A2), and
    # skipping them here keeps the hello frame small
    [[ $k == [_.]* ]] && continue
    _clicue_json_esc "$k"; parts+=( '"'$REPLY'"' )
  done
  local fns_json='['${(j:,:)parts}']'
  parts=()
  for k in ${(k)builtins} $reswords; do
    _clicue_json_esc "$k"; parts+=( '"'$REPLY'"' )
  done
  local bins_json='['${(j:,:)parts}']'
  _clicue_request '{"kind":"hello"}'
  # splice env in before the closing brace
  REPLY=${REPLY[1,-2]}',"env":{"aliases":'$aliases_json',"functions":'$fns_json',"builtins":'$bins_json'}}'
  _clicue_rpc "$REPLY" && _clicue_apply "$REPLY"
  _clicue_helloed=1
  return 0
}

# ── hooks ────────────────────────────────────────────────────────────────────
_clicue_pre_redraw() {
  (( _clicue_dead )) && return 0
  (( ${_clicue_helloed:-0} )) || _clicue_hello
  (( _clicue_dead )) && return 0
  _clicue_request '{"kind":"redraw"}'
  if ! _clicue_rpc "$REPLY"; then
    _clicue_unpaint
    return 0
  fi
  _clicue_apply "$REPLY"
  return 0
}

_clicue_line_finish() {
  if (( ! _clicue_dead )); then
    _clicue_request '{"kind":"line-finish"}'
    _clicue_rpc "$REPLY" && _clicue_apply "$REPLY"
  fi
  _clicue_unpaint
  return 0
}

# ── keys: report the event, obey the action ─────────────────────────────────
# $1 = action name (daemon vocabulary)  $2 = fallback widget ('' = none).
# Insert appends the daemon-computed text at the cursor: the daemon saw the
# exact buffer this event carried and did the prefix arithmetic itself
# (spec/keys.md I1 moved daemon-side; the shim stays policy-free).
_clicue_key() {
  local name=$1 fb=$2
  if (( _clicue_dead )); then
    [[ -n $fb ]] && zle $fb
    return 0
  fi
  _clicue_request '{"kind":"key","name":"'$name'"}'
  if ! _clicue_rpc "$REPLY"; then
    _clicue_unpaint
    [[ -n $fb ]] && zle $fb
    return 0
  fi
  _clicue_apply "$REPLY"
  case $_clicue_action in
    consume) zle -R ;;
    insert)
      # Replace the typed prefix by LENGTH — the daemon computed how many
      # characters (keys.md I1: an index strips regardless, so it is
      # guarded daemon-side by having seen this exact buffer).
      (( _clicue_instrip > 0 && _clicue_instrip <= ${#LBUFFER} )) && \
        LBUFFER=${LBUFFER[1,${#LBUFFER}-_clicue_instrip]}
      LBUFFER+=$_clicue_instext
      zle -R
      ;;
    yield|delegate) [[ -n $fb ]] && zle $fb ;;
  esac
  return 0
}

# Widget functions, registered BESIDE their definitions (spec/keys.md W1:
# `zle -N` accepts a missing function and fails only on the keypress).
# Accept harvests first (argument position, once per buffer): the same
# keypress that fetches also cycles, so the press is never consumed by a
# fetch alone (prototype keys.zsh:243–246).
_clicue_w_accept() {
  (( _clicue_dead )) || _clicue_harvest
  _clicue_key accept "${_clicue_fb[accept]:-expand-or-complete}"
}
_clicue_w_dismiss()  { _clicue_key dismiss  "${_clicue_fb[dismiss]}" }
_clicue_w_expand()   { _clicue_key expand   "${_clicue_fb[expand]}" }
_clicue_w_maximize() { _clicue_key maximize "${_clicue_fb[maximize]}" }
_clicue_w_sup()      { _clicue_key scroll-up   "${_clicue_fb[scroll-up]}" }
_clicue_w_sdown()    { _clicue_key scroll-down "${_clicue_fb[scroll-down]}" }
_clicue_w_up()       { _clicue_key arrow-up    "${_clicue_fb[up]:-up-line-or-history}" }
_clicue_w_down()     { _clicue_key arrow-down  "${_clicue_fb[down]:-down-line-or-history}" }
_clicue_w_left()     { _clicue_key arrow-left  "${_clicue_fb[left]:-backward-char}" }
_clicue_w_right()    { _clicue_key arrow-right "${_clicue_fb[right]:-forward-char}" }
_clicue_w_enter()    { _clicue_key insert      "${_clicue_fb[enter]:-accept-line}" }
_clicue_w_home()     { _clicue_key home        "${_clicue_fb[home]:-beginning-of-line}" }
_clicue_w_end()      { _clicue_key end         "${_clicue_fb[end]:-end-of-line}" }
_clicue_w_pgup()     { _clicue_key page-up     "${_clicue_fb[pgup]:-beginning-of-buffer-or-history}" }
_clicue_w_pgdn()     { _clicue_key page-down   "${_clicue_fb[pgdn]:-end-of-buffer-or-history}" }
# (zle -N registration happens inside _clicue_install: the zle builtin
# refuses widget manipulation in non-interactive shells, and the parsers
# above must stay testable via `zsh -c 'source …'`. Registration and
# definition still share this file — W1's actual requirement.)

# ── binding: capture, refuse, record ────────────────────────────────────────
# Every binding records the previous owner in _clicue_orig (seq → widget,
# '' = was unbound) so teardown RESTORES rather than removes (spec/keys.md
# C2 — the prototype's clicue-off failed both directions). Never capture a
# _clicue_* widget (W2: a re-source must not delegate to itself).
_clicue_capture() {
  local seq=$1
  local w=${${(z)$(bindkey -- "$seq")}[2]}
  [[ $w == (undefined-key|_clicue_*) ]] && w=''
  (( ${+_clicue_orig[$seq]} )) || _clicue_orig[$seq]=$w
  [[ -n $w ]] && return 0
  return 0
}

_clicue_bind() {  # $1 seq  $2 widget  $3 fallback-key ('' = none)
  case $1 in
    ('^[[A'|'^[[B'|'^[OA'|'^[OB')
      print -u2 "clicue: refusing to bind $1 — plain arrows belong to history"
      return 1 ;;
    ([[:print:]])
      print -u2 "clicue: refusing to bind '$1' — bare printable characters are typing"
      return 1 ;;
  esac
  _clicue_capture "$1"
  [[ -n $3 && -n ${_clicue_orig[$1]} ]] && _clicue_fb[$3]=${_clicue_orig[$1]}
  bindkey -- "$1" "$2"
  return 0
}

_clicue_install() {
  local wname
  for wname in accept dismiss expand maximize sup sdown up down left right \
               enter home end pgup pgdn; do
    zle -N _clicue_w_$wname
  done
  # configurable actions (zstyle ':clicue:keys' <action> <seq>...)
  local -A defaults=(
    accept      '^I'
    dismiss     '^['
    expand      '^[e'
    maximize    '^[m'
    scroll-up   '^[[1;2A ^[[1;3A ^[^[[A'
    scroll-down '^[[1;2B ^[[1;3B ^[^[[B'
  )
  local -A widget=(
    accept _clicue_w_accept  dismiss _clicue_w_dismiss
    expand _clicue_w_expand  maximize _clicue_w_maximize
    scroll-up _clicue_w_sup  scroll-down _clicue_w_sdown
  )
  local action seq
  local -a seqs
  for action in ${(k)defaults}; do
    seqs=()
    zstyle -a ':clicue:keys' $action seqs || seqs=( ${=defaults[$action]} )
    for seq in $seqs; do
      _clicue_bind "$seq" "${widget[$action]}" "$action"
    done
  done
  # borrowed keys: arrows, Enter, Home/End, PgUp/PgDn — capture + delegate
  local -A borrow=(
    '^[[A' _clicue_w_up     '^[OA' _clicue_w_up
    '^[[B' _clicue_w_down   '^[OB' _clicue_w_down
    '^[[C' _clicue_w_right  '^[OC' _clicue_w_right
    '^[[D' _clicue_w_left   '^[OD' _clicue_w_left
    '^M'   _clicue_w_enter
    '^[[H' _clicue_w_home   '^[[1~' _clicue_w_home   '^[OH' _clicue_w_home
    '^[[F' _clicue_w_end    '^[[4~' _clicue_w_end    '^[OF' _clicue_w_end
    '^[[5~' _clicue_w_pgup  '^[[6~' _clicue_w_pgdn
  )
  local -A fbname=(
    _clicue_w_up up  _clicue_w_down down  _clicue_w_right right
    _clicue_w_left left  _clicue_w_enter enter  _clicue_w_home home
    _clicue_w_end end  _clicue_w_pgup pgup  _clicue_w_pgdn pgdn
  )
  local w
  for seq w in ${(kv)borrow}; do
    _clicue_capture "$seq"
    [[ -n ${_clicue_orig[$seq]} ]] && _clicue_fb[${fbname[$w]}]=${_clicue_orig[$seq]}
    bindkey -- "$seq" "$w"
  done
  add-zle-hook-widget line-pre-redraw _clicue_pre_redraw
  add-zle-hook-widget line-finish _clicue_line_finish
  # zle -C fails silently at load on a missing function (Z2); definition is
  # in this file, registration here because zle refuses widget ops in
  # non-interactive shells (same constraint as the zle -N block above).
  zle -C _clicue_cap list-choices _clicue_cap_fn
  return 0
}

# Full teardown: hooks off, every captured original REPLAYED (or unbound if
# there was none), socket closed, card stripped. This shell only.
clicue-off() {
  add-zle-hook-widget -d line-pre-redraw _clicue_pre_redraw 2>/dev/null
  add-zle-hook-widget -d line-finish _clicue_line_finish 2>/dev/null
  local seq
  for seq in ${(k)_clicue_orig}; do
    if [[ -n ${_clicue_orig[$seq]} ]]; then
      bindkey -- "$seq" "${_clicue_orig[$seq]}"
    else
      bindkey -r -- "$seq" 2>/dev/null
    fi
  done
  _clicue_orig=()
  _clicue_disconnect
  zle && _clicue_unpaint 2>/dev/null
  print "clicue: unhooked (this shell only)"
  return 0
}

# ── state and installation ───────────────────────────────────────────────────
typeset -g  _clicue_v=@CLICUE_VERSION@
typeset -g  _clicue_sock='@CLICUE_SOCK@'
if [[ -z $_clicue_sock ]]; then
  if [[ -n $XDG_RUNTIME_DIR ]]; then
    _clicue_sock=$XDG_RUNTIME_DIR/clicue.sock
  else
    _clicue_sock=${XDG_CACHE_HOME:-$HOME/.cache}/clicue/clicue.sock
  fi
fi
typeset -g  _clicue_start=${${EPOCHREALTIME:-0}%%.*}
typeset -g  _clicue_fd=
typeset -gi _clicue_spawned=0
typeset -gi _clicue_dead=0
typeset -g  _clicue_err=''
typeset -g  _clicue_card=''
typeset -g  _clicue_ghost=''
typeset -g  _clicue_action=delegate
typeset -g  _clicue_instext=''
typeset -gi _clicue_hist_acked=0
typeset -gA _clicue_orig=()
typeset -gA _clicue_fb=()
# compsys capture state
typeset -g  _clicue_cs_for=''
typeset -g  _clicue_pending=''
typeset -gA _clicue_cs_done=()
typeset -ga _clicue_cs_words=() _clicue_cs_descs=() _clicue_csd=()
typeset -ga _clicue_cs_sfxw=() _clicue_cs_sfxv=()
typeset -g  _clicue_cs_ipfx='' _clicue_cs_probe='' _clicue_cs_hassfx='' _clicue_cs_sfxval=''

if [[ -o interactive && -o zle ]]; then
  zmodload zsh/net/socket zsh/system zsh/datetime 2>/dev/null || return 0
  autoload -Uz add-zle-hook-widget
  _clicue_start=${${EPOCHREALTIME:-0}%%.*}
  _clicue_install
fi
