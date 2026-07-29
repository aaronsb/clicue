# clicue

Live, contextual command guidance for zsh — the IntelliSense pattern applied to the
command line.

As you type, a cue card renders below the prompt: candidates with real one-line
descriptions, narrowing with every keystroke. Once you are past the command name it
switches to explaining what you have already typed, so `rm -rf` tells you what `-r`
and `-f` actually do, and how often you have run that exact invocation before.
Choosing from the card composes the command; it never runs it.

clicue is **not** a completion engine. zsh's compsys represents decades of work by
many people, and clicue consumes its output rather than reimplementing it —
candidates, argument positions and insertion semantics all come from compsys. What
clicue adds is presentation: ranking by your own history, descriptions from a corpus
built out of `whatis` and compsys itself, grouped option spellings, and statistics
about your own habits that no manual page knows.

## Quick start

```zsh
# 1. build the description corpus (~3,400 glosses from installed man pages)
zsh -i -c 'source /path/to/clicue/prototype/build-corpus.zsh'

# 2. load it from your zsh config, AFTER any completion setup
zstyle ':clicue:*' theme aura
source /path/to/clicue/prototype/clicue.zsh
```

`prototype/45-clicue.example` is a documented, known-working configuration — copy it
into your `conf.d` and edit. **All `zstyle` settings must come before the `source`
line**, because keys are bound at source time.

Startup cost is ~2 ms; the corpus loads lazily on the first card.

## Keys

| Key | Action |
|---|---|
| `Tab` | cycle the primary card. It is history-ranked, so what you want is usually one or two presses away |
| `↑` `↓` | walk the selection once you have started cycling; continues into the second box |
| `←` `→` | jump a grid column; `→` also accepts the ghost-text proposal |
| `Enter` | put the highlighted cue on the line — **not** run it |
| `Esc` | dismiss for the current line |
| `Alt+E` | expand a collapsed explanation |

Unmodified `↑`/`↓` always reach command history. That is enforced in code, not merely
intended. No bare printable character is ever bound — binding `q` as an alternate
dismiss would break every command containing a q.

## Themes

```zsh
zstyle ':clicue:*' theme aura    # default: rounded Unicode box drawing
zstyle ':clicue:*' theme plain   # pure ASCII, for a font or TERM you cannot trust
zstyle ':clicue:*' theme mono    # Unicode, but weight and dimming instead of hue
```

`clicue-theme <name>` switches without restarting; `clicue-theme` alone lists what is
available. A theme owns colours and box glyphs and nothing else, and every key is
validated at load — a theme that forgets one falls back to the built-in default
rather than rendering a broken card. Themes are treated as an accessibility surface,
not a skin: see design value 3 in [SPEC.md](SPEC.md).

## Caches

Both live under `$XDG_CACHE_HOME/clicue` and are derived data — deleting them is
always safe.

| File | What | Rebuild |
|---|---|---|
| `corpus.zsh` | glosses, history frequency, invocation statistics | `clicue-rebuild` |
| `flags/<cmd>.zsh` | a command's documented options, harvested from compsys | automatic on first use |

The flag cache is versioned and invalidated by the command's mtime. The corpus is
**not yet** — it is rebuilt only when you ask, so it goes stale as history grows.
That is a known gap.

## Status

Working prototype, in daily use by its author. Not packaged, not versioned, no
install script. `prototype/test.zsh` holds ~100 in-process assertions; run it after
any change.

- [SPEC.md](SPEC.md) — design values and every measured finding, tagged by
  confidence. Read design values 0, 1 and 5 first; they were learned expensively and
  constrain everything else.
- [MOTIVATION.md](MOTIVATION.md) — why this exists: the asymmetry between the typed
  interfaces agents get and the byte streams humans get on the same machine.

## Prior art

The interaction pattern is inspired by
[IRIS](https://github.com/versenilvis/IRIS), which demonstrated the live-narrowing
card and the visual language. clicue takes the UX and rejects the architecture: IRIS
wraps the terminal in a pty and carries a hand-authored spec corpus, where clicue
runs inside zsh and derives everything from what the system already documents.
