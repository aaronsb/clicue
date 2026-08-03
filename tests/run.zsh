#!/usr/bin/env zsh
# Run every e2e scenario. Each is self-contained (own sandbox, own daemon)
# and exits 0 / non-zero; SKIPs (missing optional commands) do not fail.
emulate -L zsh
local -i failed=0 ran=0
local s
for s in "${0:a:h}"/scenarios/*.zsh; do
  print -- "── ${s:t} ──"
  if zsh "$s"; then
    (( ran++ ))
  else
    (( failed++ ))
  fi
done
print -- "──"
print "$ran scenario(s) ok (passes and skips), $failed failed"
exit $(( failed > 0 ))
