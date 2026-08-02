# Spec extraction — the prototype, decomposed

The prototype (`prototype/`) is the reference implementation. This directory
holds its behaviour decomposed into implementable spec sections for the Rust
rewrite (ADR-100). SPEC.md at the repo root keeps the product values; these
files hold the accumulated invariants — the things the prototype *measured*,
which a rebuild would otherwise rediscover the hard way.

## Tagging

Every extracted invariant carries one of two tags:

- **[domain]** — survives any implementation. Example: the card is a constant
  height for a given buffer, because ZLE paints a taller POSTDISPLAY over a
  shorter one rather than reflowing.
- **[zsh-hazard]** — a defense against zsh-the-language (pattern-vs-literal
  strips, GLOB_SUBST, subscript traps, fork budget). Recorded here only when
  the *shim* still needs it; hazards confined to rewritten code die with the
  rewrite and are not carried over.

Where the prototype marked a behaviour `[MEASURED]`, keep that provenance —
those are facts about zsh/terminals, not opinions.

## Planned sections

| File | Source material | Component (ADR-100) |
|---|---|---|
| `card-layout.md` | render.zsh | daemon: layout |
| `sources.md` | candidates.zsh, stats.zsh | daemon: sources + rank |
| `corpus.md` | build-corpus.zsh, corpus.zsh | daemon: corpus |
| `compsys-bridge.md` | compsys.zsh | shim ↔ daemon seam |
| `keys.md` | keys.zsh | shim + daemon state machine |
| `themes.md` | theme.zsh, themes/ | daemon: theme |
| `protocol.md` | (new) | protocol |
| `doctor.md` | conflict catalog from prototype comments | tool |

Each section is written by reading the prototype file(s) end to end and
harvesting every invariant its comments and tests assert, then checked
against `prototype/test.zsh` for behaviours the comments missed.
