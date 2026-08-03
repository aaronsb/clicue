#!/usr/bin/env zsh
# Design note navigation-and-place.md: a navigational command renders the
# "you are here" pane from RELAYED place (spec §4c) — breadcrumb, children
# with counts, and typed-target resolution with the honest failure row.
# The zero-data slice: everything here works against an empty history.
source "${0:a:h}/../harness.zsh"

pty_start plain

# Children of the sandbox HOME the pane should see (run/ and cache/ exist
# already; one name is unmistakably ours).
mkdir -p $T_SANDBOX/projects-dir/inner-a $T_SANDBOX/projects-dir/inner-b

# The pty shell inherits the runner's cwd; move it home first so the pane
# describes the sandbox, not the repo.
pty_type 'cd ~'
pty_key $'\r'
pty_drain 0.5
PTY_OUT=''

pty_type 'cd '
pty_drain 0.8
t_plain "$PTY_OUT"
[[ $REPLY == *'you are here'* ]] || t_fail "no pane on 'cd '"
[[ $REPLY == *'~'* ]]            || t_fail "breadcrumb missing its ~ root"
[[ $REPLY == *'projects-dir'* ]] || t_fail "children ring missing a real subdir"
PTY_OUT=''

# A target that resolves says where it lands; no recommendation.
pty_type 'projects-dir'
pty_drain 0.6
t_plain "$PTY_OUT"
[[ $REPLY == *'→'* ]]              || t_fail "no resolution row for a real target"
[[ $REPLY != *'did you mean'* ]]   || t_fail "success must not be recommended at"
PTY_OUT=''

# Clear the line, then a target that fails from here: the honest row.
# The stream is reset AFTER typing so the assertion sees one fresh frame
# — the backspaces pass through `cd ` whose reserved going box would
# otherwise pollute the no-going check.
local -i i
for (( i = 1; i <= 12; i++ )); do pty_key $'\x7f'; done
pty_type 'no-such-dir-z'
pty_drain 0.6
PTY_OUT=''
pty_type 'z'
pty_drain 0.6
t_plain "$PTY_OUT"
[[ $REPLY == *'no such'* ]]        || t_fail "missing the failure row for a dead target"
[[ $REPLY != *'you are going'* ]]  || t_fail "a dead target must not get a going pane"

# The going pane itself (cd . symmetry, attended preview, pronoun) is
# asserted in the engine tests at 50 lines: this pty is 80x24, and the
# height budget — honestly enforced — cannot hold both panes plus an
# explanation there. The pane dropping WHOLE in small windows is the
# behavior, not a gap.

t_done
