# Doctor — the conflict catalog, promoted from scar tissue to a check

`clicue doctor` diagnoses the environment clicue must coexist with. Every
check below is harvested from a measured incident in the prototype's
comments; provenance points at the scar. Severity taxonomy (fighter /
degradation / info) is NEW in the rewrite — the prototype could only
document these; the doctor tests for them.

## M — method

- M1 [domain] Probe the LIVE shell, never parse config text: spawn a captive
  `zsh -i` and inspect the resulting state — bindkey table, loaded widgets
  and functions, setopts, env. A zshrc behind a plugin manager is not
  statically analyzable; measuring the loaded result is the same discipline
  the prototype applied everywhere else. (ADR-100)
- M2 [domain] Re-runnable anytime, not install-only. Configs drift; "clicue
  stopped working after I added a plugin" must be a one-command diagnosis.
  Every finding carries severity, the evidence observed, and a concrete fix
  instruction.
- M3 [domain] The daemon stashes protocol-level faults for the doctor to
  report: version mismatch frames, and a daemon that died twice (the shim
  spawns at most once and never restarts a repeat offender).
  (spec/protocol.md §9–10)

## F — fighters (recommend removal or explicit choice)

- F1 [domain] zsh-autocomplete: rebuilt compadd by round-tripping its body
  through `$functions` as text, which failed to re-parse on `#` comments
  and broke every completion; it also owns Tab and draws its own listing.
  Detect by function/widget names; genuine conflict. (clicue.zsh:127–130)
- F2 [domain] fzf-tab, or any other owner of `^I` whose widget the shim
  does not recognise as a standard completer: clicue delegates Tab to
  whatever owned it, so an exotic owner still works — but two candidate UIs
  on one keystroke is a choice the operator should make knowingly. Report
  the observed owner by name. (keys.zsh:536–538)
- F3 [domain] With the shim loaded, every sequence it binds must still
  point at a `_clicue_*` widget once the rc has finished loading — a later
  `bindkey` silently disconnects that key (Down went to
  history-substring-search and the grid was unreachable, while doctor
  reported no fighters [MEASURED 2026-08-02]). Probe every spelling the
  shim binds, including the application-mode `^[O…` variants (zle runs in
  smkx). Remedy in the message: bind BEFORE clicue — the shim captures the
  previous owner and delegates to it whenever the card is not engaged, so
  the original behavior survives when clicue binds last.

## X — coexistence (verify, then pass)

- X1 [domain] zsh-autosuggestions: POSTDISPLAY is single-tenant by
  convention only — its accept widgets do `BUFFER+=POSTDISPLAY` — and its
  async result arrives via a `zle -F` handler at an arbitrary moment. The
  shim wraps its consumers and its async response function by NAME; the
  doctor verifies those names exist in the loaded version
  (`_zsh_autosuggest_async_response`, the widget list the shim wraps) and
  flags an unknown version rather than letting the wrap silently miss.
  (clicue.zsh:449–505)
- X2 [domain] complist/menuselect: no conflict — clicue stands down while
  the native menu owns the display. Informational only. (clicue.zsh:247–250)
- X3 [domain] Load order: the shim must load after compinit (the bridge
  needs `_main_complete`) and after zsh-autosuggestions (wrap order, keys
  spec W3). The doctor confirms both are true in the probed shell and the
  installer chooses the insertion point accordingly. (clicue.zsh:494–505;
  prototype/45-clicue.example)

## D — silent degradations (warn with the consequence)

- D1 [domain] EXTENDED_HISTORY unset → history carries no timestamps → the
  recency signal is empty and frecency/recency silently behave as
  frequency. The prototype surfaces this only if the operator thinks to run
  `clicue-rank status`; the doctor surfaces it at install, because an
  invisible metric substitution is design value 1's forbidden fallback.
  (candidates.zsh:654–659; build-corpus.zsh:58–66)
- D2 [domain] Small HISTSIZE/SAVEHIST → thin corpus, weak ranking; report
  the observed sizes against the history window the daemon uses.
  (candidates.zsh:183–208)
- D3 [domain] whatis/mandb absent or index empty → no glosses for system
  commands; the card still works but loses its descriptions. Name the
  package to install. (build-corpus.zsh:32–56)
- D4 [domain] HIST_IGNORE_ALL_DUPS is fine and DESIGNED FOR (recency-based
  invocation ranking exists because of it) — report as info, not a warning,
  so the operator is not told to change a setting the tool already
  accommodates. (build-corpus.zsh:173–176)
- D5 [domain] Theme health, minimally: the ACTIVE theme must load cleanly —
  a broken file degrades to a fallback with a message only on the daemon's
  stderr, which nobody reads, so doctor is where the fallback becomes
  visible (degraded, with the loader's own messages). Other theme files
  that fail to load are listed as info — harmless until selected — with
  the two recovery gestures named (preview shows errors; delete
  regenerates). A healthy report states the active theme and the count
  available.

## T — terminal quirks

- T1 [domain] konsole claims Shift+Up/Down for Scroll Line Up/Down at the
  terminal level; the keystrokes never reach the shell. Detect via
  KONSOLE_DBUS_SESSION; report that Alt+↑↓ works, with the Settings path to
  free Shift. This closes the prototype's unfinished
  CLICUE_TERM_EATS_SHIFT feature — detection existed, but the legend never
  consulted it, so konsole users were shown a key that cannot arrive
  (review #18). (keys.zsh:56–68, 543–551)

## P — privacy posture (report, always)

- P1 [domain] The doctor's report states the data posture in one line:
  everything derived from history, nothing instrumented, space-prefixed
  commands never learned, `clicue data forget` for retroactive removal.
  Trust in a tool that watches every keystroke is earned by saying exactly
  what it keeps. (spec/corpus.md P1–P2)
