#!/usr/bin/env zsh
# Run every e2e scenario. Each is self-contained (own sandbox, own daemon)
# and exits 0 / non-zero; SKIPs (missing optional commands) do not fail.
# One LOUD retry per failed scenario: these are real-time pty suites, and
# a contended CI VM can starve a keystroke window past its deadline in
# ways no readiness gate closes (PR #39, runs 6–11: different scenarios
# each run, none reproducible on idle hardware). A genuine regression
# fails twice; a starved VM does not.
emulate -L zsh
local -i failed=0 ran=0 retried=0
local s
for s in "${0:a:h}"/scenarios/*.zsh; do
  print -- "── ${s:t} ──"
  if zsh "$s"; then
    (( ran++ ))
  elif { print -- "── ${s:t} RETRY (first attempt failed) ──"; zsh "$s" }; then
    (( ran++, retried++ ))
  else
    (( failed++ ))
  fi
done
print -- "──"
print -n "$ran scenario(s) ok (passes and skips), $failed failed"
(( retried )) && print -n " — $retried passed only on retry (contended machine?)"
print
exit $(( failed > 0 ))
