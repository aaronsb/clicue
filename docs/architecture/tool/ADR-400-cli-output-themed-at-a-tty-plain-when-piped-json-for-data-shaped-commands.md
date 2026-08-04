---
status: Accepted
date: 2026-08-04
deciders:
  - aaronsb
  - claude
related: []
---

# ADR-400: CLI output: themed at a tty, plain when piped, --json for data-shaped commands

## Context

The card is themed; the CLI is not. `clicue data status`, `data stats`,
`data inspect`, `theme list`, and `config set` print unstyled text while
the daemon renders every card in the operator's chosen palette — the tool
does not wear its own clothes. At the same time the data-shaped outputs
(status, stats, inspect, theme list) are useful to scripts, and scraping
aligned columns is the wrong interface to offer.

Two pressures, one convention needed: styled output for humans, stable
output for machines, without a mode flag the operator must remember on
every invocation.

## Decision

Three output modes, selected in this order:

1. **`--json`** (explicit, per data-shaped subcommand): structured
   serde_json output, one object per invocation, no ANSI ever. Offered
   on `data status`, `data stats`, `data inspect`, and `theme list` —
   the commands whose output IS data. Action commands (`rebuild`,
   `forget`, `theme set`, `config set`) keep prose confirmations; their
   output is a receipt, not a dataset.
2. **Themed** (default when stdout is a tty): labels and values styled
   through the ACTIVE theme's palette — the same `style_to_ansi`
   conversion the swatch and preview already use, the same palette roles
   the card uses (accent for names, gloss for descriptions, hint for
   labels/keys, matched for emphasis). The CLI inherits the operator's
   theme choice; it never invents colours (the shim's own rule, applied
   to the tool).
3. **Plain** (default when stdout is not a tty): the identical text with
   zero ANSI — the `--color=auto` convention. Piping any command yields
   grep-able output without a flag.

Two exemptions. Doctor keeps its unthemed report for now: diagnostic
prose, often pasted into issues, and a 700-line surface that is a
separate sweep. The theme **swatch** keeps its ANSI even when piped: a
swatch IS its colours — stripped, it is a row of box glyphs asserting
nothing — and the machine form of `theme list` is `--json`, not a
decolourised swatch.

## Consequences

### Positive

- The tool matches the card — one palette everywhere the operator looks.
- Scripts get JSON, pipes get plain text, and neither requires a flag
  the operator must remember (only `--json` is explicit, and only where
  structure exists to offer).

### Negative

- Every themed print site carries a style call; new CLI output must
  choose a palette role instead of bare `println!`.
- JSON shapes become a compatibility surface: field renames are
  breaking changes once scripts depend on them.

### Neutral

- `style_to_ansi` becomes a public seam of theme.rs.
- A small output helper (tty detection + palette lookup) joins the
  crate; doctor adopting it later is mechanical.

## Alternatives Considered

- **Global `--output human|plain|json` flag**: most explicit, but plumbs
  through every subcommand and makes the common case (a human at a tty)
  carry the cost of the rare one. Auto-detection covers human/plain with
  zero typing; rejected.
- **`--json` only, no theming**: leaves the CLI permanently unstyled —
  the mismatch that motivated this ADR; rejected.
- **`NO_COLOR` / `CLICOLOR` env contract**: worth honouring later, but
  an env-var contract is not a substitute for pipe detection; deferred,
  compatible with this decision (`NO_COLOR` set → plain even at a tty).
