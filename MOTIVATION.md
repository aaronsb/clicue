# Why clicue

> Status: **draft.** This is the *why*; `SPEC.md` is the *what*.
> Captured 2026-07-28. Aspirational sections are marked as such and are
> deliberately not commitments.

## The asymmetry

An agent working in a terminal gets: MCP servers emitting typed schemas — name,
description, per-parameter types and docs — tool surfaces that describe
themselves, and structured returns it can navigate.

A human working in the *same terminal* gets: `--help` if the author bothered,
formatted however they chose; man pages in a pager that costs you your place; and
output as a flat byte stream to be re-parsed by eye.

Same machine. Two interfaces. One accreted over thirty years; the other arrived
more or less complete in eighteen months.

**The consequence is not that agents are better at the CLI. It is that agents have
a better API to it.** That is an interface problem, and interface problems are
fixable.

This matters beyond convenience. Delegating work to an agent because it is
genuinely better suited is fine. Delegating because the human's interface to the
same system is worse is a defect — and it quietly erodes the operator's ability to
supervise what is being done on their behalf.

## The tax

The operator's real cost is not typing. It is this:

**You re-enter information that is already on your screen.**

Run `docker ps`, read a container name, retype it. `ls`, see a filename, retype
it. `git branch`, see the branch, retype it. The data was right there, and it went
back in through a 60-wpm channel.

An agent does not pay this tax; it parses the output and reuses it.

The sharpest illustration, from the IRIS audit **[MEASURED]**: IRIS's context
providers *fork `docker ps`* so its completion engine can suggest container names
the operator looked at three lines earlier. The system re-derives what is already
on screen, because the screen holds bytes rather than objects.

## What was lost

This is restoration, not invention.

- **TOPS-20 `COMND` JSYS** (mid-1970s) — system-level command parsing available to
  every program; `?` listed valid options *with descriptions*, ESC completed.
  Help was built in, not bolted on.
- **Genera / CLIM** — *presentation types*: displayed output retained its semantic
  type and stayed directly actionable. The container name on screen **was** the
  object.
- **PowerShell** — objects survive the pipe boundary.

In a Unix pipe, structure is destroyed at every `|`: each tool serializes to text
and the next re-parses. The `--json` trend is Unix rediscovering this piecemeal,
but with no presentation layer to consume it — so `jq` becomes the tax rather than
the fix.

**[ASSUMED]** — these are design references offered from recollection, not
verified history. Check specifics before repeating them as fact.

## The response: one corpus, plural presenters

To render a cue card you need a structured description of a command: subcommands,
flags, which take arguments, argument types, and a gloss for each.

That is close to what an MCP tool definition needs.

So the architecture is not "a renderer with a corpus behind it." It is **a
normalized corpus with plural presenters**, one of which happens to be a cue card:

| Audience | Presenter | Disclosure |
|---|---|---|
| human | cue card | just-in-time, at the moment of relevance |
| agent | tool schema | catalog, searchable |

**Same substrate, different disclosure.** The bandwidth asymmetry does not
disappear — an agent reads a whole schema instantly; a human reads a card a glance
at a time — but the two want different things, so matching disclosure to
consumption rate is the design, not a compromise in it.

The practical implication, and the only near-term decision this document argues
for: **keep the corpus schema presenter-agnostic.** Cheap now, expensive later.

## Why this is worth doing even for agents

**[MEASURED]** 43 of the 172 commands actually used on this machine have no
description from any upstream source — `kg`, `ways`, `mmm`, `cookiedumper`, `qrc`,
`posh-theme`, `attend`, `askd`, `transcribbler` and similar locally authored tools.

Those are precisely what an agent arriving on this machine does *not* know. Today
it discovers them by reading shell history or running `--help` and hoping.

The loop is self-reinforcing: **an agent enriches the corpus, then benefits from
having enriched it.** Describe `cookiedumper` once and both the operator's cue
card and every future agent session inherit it.

## Aspiration — explicitly not a plan

If the corpus is presenter-agnostic, a `clicue-mcp` presenter becomes possible:
local, stdio, exposing the system's own commands as described tools. Human and
agent would then draw on the same semantic substrate and could refer to the same
objects by the same names — a prerequisite for supervision rather than trust.

**This is aspirational. It is recorded to preserve optionality, not to schedule
work.**

Four things must be true before it would be sane:

1. **Context economics.** A flat catalog of ~6,173 commands is unusable — at even
   ~100 tokens per definition that is ~600k tokens of schema before any work
   happens. The viable shape is a *searchable interface over* the corpus
   (find-tool / get-schema), leaving definitions latent until relevant. This is
   the same progressive-disclosure principle the cue card uses for humans.
2. **Execution surface.** An MCP server exposing every command on a system is an
   arbitrary-code-execution surface with good documentation attached — `rm`, `dd`,
   `mkfs`, `curl | sh`, all typed and discoverable. Allowlisting, capability
   scoping and confirmation semantics would be load-bearing from day one, not
   hardening added later.
3. **Semantics, not just syntax.** Completion specs describe *form*: compsys knows
   `git cherry-pick` takes a commit-ish. It does not know the command rewrites the
   working tree, can conflict, or is the wrong tool if you wanted `revert`. MCP
   descriptions carry intent and consequence. Generated schemas would be
   syntactically complete and semantically thin; the enrichment layer would be
   supplying meaning that completion data structurally lacks.
4. **Coarse types.** `_files`, `_directories`, `_git_branches` suffice to complete
   against, not to validate. Most parameters would degrade to `"type": "string"`,
   losing much of JSON Schema's value.

And one thing would remain unsolved regardless: **output is still bytes.** A
generated tool would have a good input schema and return an unstructured stream.
Good inputs, same terrible outputs.

## The honest gradient

| | Status |
|---|---|
| Presenter-agnostic corpus schema | tractable now; cheap now, expensive later |
| Cue card presenter | the current project |
| MCP presenter over a scoped set | plausible; needs search pattern + allowlisting |
| Agents preferring structured invocation over shelling out | aspirational |
| Typed objects flowing through Unix pipes | likely never without redesigning Unix |

The input half is tractable today. The output half needs a mechanism worth proving
before believing in — possibly semantic shell integration (OSC 133 prompt marking,
implemented by kitty, WezTerm, Ghostty, iTerm2), which would let a presenter know
which command produced which output and offer that output as candidates. **[ASSUMED
— unverified.]**

## What this document is not

- Not a commitment to build an MCP presenter.
- Not a claim that agents should stop running shell commands.
- Not a scope expansion of `SPEC.md`. The only decision argued for here is keeping
  the corpus schema presenter-agnostic.
