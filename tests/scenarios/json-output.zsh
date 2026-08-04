#!/usr/bin/env zsh
# ADR-400: the --json shapes are a compatibility surface. Pin them —
# every emitter parses as JSON and carries its declared keys, in both
# the populated and the absent-corpus states. No pty needed: this is
# the CLI surface, not the shim.
source "${0:a:h}/../harness.zsh"

# A sandboxed HOME so the binary sees a corpus we control. NOT named
# T_SANDBOX: the harness's TRAPEXIT (pty_stop) fires in EVERY command
# substitution's subshell, and it rm -rf's $T_SANDBOX — with that name,
# each $(run …) below deleted the corpus the previous step built
# [MEASURED: stats read "absent" one line after status read the same
# corpus fine].
SB=$(mktemp -d "${TMPDIR:-/tmp}/clicue-json-XXXXXX")
mkdir -p $SB/cache
print -l 'git status' 'git log' 'ls -la' > $SB/.zsh_history

jq_keys() {  # $1 json  $2… required top-level keys
  local json=$1; shift
  python3 - "$@" <<EOF
import json, sys
d = json.loads('''$json''')
missing = [k for k in sys.argv[1:] if k not in d]
sys.exit(1 if missing else 0)
EOF
}

run() { HOME=$SB XDG_CACHE_HOME=$SB/cache XDG_CONFIG_HOME=$SB/.config $CLICUE_BIN "$@" }

# ── absent corpus: all three data verbs answer in JSON, exit 0 ──────────
local out
out=$(run data status --json)  || t_fail "status --json (absent) exited nonzero"
jq_keys "$out" corpus state    || t_fail "status absent shape: $out"
out=$(run data stats --json)   || t_fail "stats --json (absent) exited nonzero"
jq_keys "$out" corpus state    || t_fail "stats absent shape: $out"
out=$(run data inspect git --json) || t_fail "inspect --json (absent) exited nonzero"
jq_keys "$out" cmd corpus state    || t_fail "inspect absent shape: $out"

# ── populated corpus ────────────────────────────────────────────────────
run data rebuild >/dev/null 2>&1 || t_fail "rebuild failed"
out=$(run data status --json)    || t_fail "status --json exited nonzero"
jq_keys "$out" corpus glosses invocations state || t_fail "status shape: $out"
out=$(run data stats --json)     || t_fail "stats --json exited nonzero"
jq_keys "$out" state corpus top_commands top_invocations recency flags \
  || t_fail "stats shape: $out"
out=$(run data inspect git --json) || t_fail "inspect --json exited nonzero"
jq_keys "$out" cmd gloss runs invocations flags subcommand_tables \
  || t_fail "inspect shape: $out"
out=$(run theme list --json)     || t_fail "theme list --json exited nonzero"
jq_keys "$out" current themes    || t_fail "theme list shape: $out"

# ── --json never carries ANSI, even at what looks like a tty ────────────
[[ $(run data stats --json) == *$'\x1b'* ]] && t_fail "--json output carries ANSI"

# ── piped human output is plain (zero escapes) ──────────────────────────
[[ $(run data stats) == *$'\x1b'* ]] && t_fail "piped human output carries ANSI"

rm -rf $SB
t_done
