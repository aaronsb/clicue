//! Wire types for the shim ↔ daemon protocol.
//!
//! Contract: spec/protocol.md. Framing is newline-delimited JSON — one
//! request line in, one reply line out. All offsets and limits are BYTES
//! (spec §2: zsh `${#var}` counts characters and must never size a frame),
//! with one deliberate exception: `cursor` travels in characters, ZLE's
//! native unit, and the daemon converts — the shim stays dumb.

use serde::{Deserialize, Serialize};

/// Bumped on any wire-visible change. Mismatch produces an [`ErrorFrame`],
/// never a guessed reply (spec §10).
pub const VERSION: u32 = 1;

/// Hard cap on one frame, in bytes (spec §2). A compsys harvest of several
/// hundred described candidates measures tens of KiB; a frame past this is
/// a malfunction, answered with an error frame and a closed connection.
/// One constant so shim and daemon cannot disagree.
pub const MAX_FRAME: usize = 1 << 20;

/// Keys per-shell daemon state: selection, engagement, suppression all
/// belong to one shell, not one connection (spec §4).
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct Session {
    /// Shell PID.
    pub pid: u32,
    /// Shell start time, so a recycled PID cannot inherit stale state.
    pub start: u64,
}

/// What the shim observed. It never interprets buffer content (spec §5).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Event {
    /// First event of a session; `env` on the request carries what only
    /// the shell knows (aliases, functions, builtins). Sent once per
    /// shell, before the first redraw.
    Hello,
    /// line-pre-redraw fired.
    Redraw,
    /// A bound key fired; `name` is the shim's action name (accept,
    /// dismiss, scroll-up, …), not a raw escape sequence.
    Key { name: String },
    /// The line was accepted; `hist` on the request carries new history.
    LineFinish,
}

/// Shell-side name universe, sent with [`Event::Hello`]. The daemon can
/// walk `$PATH` itself; aliases, functions and builtins exist only inside
/// the live shell (prototype read them per keystroke; the daemon gets
/// them once and the shim stays dumb thereafter).
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct EnvPayload {
    /// name → expansion (the gloss for an alias IS its expansion).
    #[serde(default)]
    pub aliases: std::collections::HashMap<String, String>,
    #[serde(default)]
    pub functions: Vec<String>,
    #[serde(default)]
    pub builtins: Vec<String>,
}

/// The shell's place, relayed with each request so the daemon can render
/// "you are here" (spec §4c). RELAY, NEVER RECORD: this is request context
/// like the compsys harvest — used for the reply it arrived with, never
/// persisted. A recorder of place would defeat `HIST_IGNORE_SPACE` (a
/// space-prefixed ` cd <secret>` hides the line but not the transition),
/// which is the design note's one promise-backed rejection
/// (docs/design-notes/navigation-and-place.md).
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct NavContext {
    pub pwd: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub oldpwd: Option<String>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub dirstack: Vec<String>,
}

/// One new `$history` entry: zsh event number and the line (spec §5a).
/// Serialized as a two-element array. Numbered so the daemon can ack and
/// the shim can resend only what was never acknowledged.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HistEntry(pub u64, pub String);

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Request {
    pub v: u32,
    pub session: Session,
    pub event: Event,
    pub buffer: String,
    /// Cursor position in CHARACTERS into `buffer` — ZLE's `$CURSOR`,
    /// forwarded untouched. The daemon converts to bytes; converting in
    /// zsh would put decision logic back in the shim.
    pub cursor: usize,
    pub cols: u16,
    pub lines: u16,
    /// Active keymap (`main`, `menuselect`, …) — the daemon stands down in
    /// menuselect (spec §5; prototype clicue.zsh:250).
    pub keymap: String,
    /// Compsys harvest payload, present only on the event that produced one.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub pending: Option<serde_json::Value>,
    /// Shell name universe; present only on [`Event::Hello`].
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub env: Option<EnvPayload>,
    /// New `$history` entries since the last acked event number — read from
    /// `$history`, never `$BUFFER` (spec §5a).
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub hist: Vec<HistEntry>,
    /// Relayed place (spec §4c). Optional and additive: absence means an
    /// older shim, and the nav pane simply does not render — no version
    /// bump, per §10's additive-field policy.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub nav: Option<NavContext>,
}

/// Style span over the reply's `card` text, in CHARACTER offsets —
/// region_highlight is character-indexed, and the daemon converting
/// (trivial in Rust) keeps the shim dumb, same reasoning as `cursor`
/// (spec §7, amended; frames themselves stay byte-limited per §2).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    /// A region_highlight style string, e.g. `fg=#a277ff`.
    pub style: String,
}

/// What the shim should do with the key it forwarded (spec §6).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "action", rename_all = "kebab-case")]
pub enum Action {
    /// The daemon handled it; repaint and swallow the key.
    Consume,
    /// Hand the key to its original owner.
    Delegate,
    /// Put `text` on the command line (composition, never execution),
    /// after removing `strip` CHARACTERS before the cursor — the typed
    /// prefix being replaced. The daemon computes strip (it saw the exact
    /// buffer); the shim applies it by length arithmetic, the zsh-safe
    /// form (keys.md I1). Plain append is strip 0.
    Insert { strip: usize, text: String },
    /// Card may stay visible, but this key belongs to compsys.
    Yield,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Reply {
    pub v: u32,
    /// Text to append to POSTDISPLAY. Empty means no card (spec §6).
    pub card: String,
    pub ghost: String,
    /// region_highlight style for the ghost text; the daemon owns the
    /// theme, so the shim never invents a colour.
    #[serde(default)]
    pub ghost_style: String,
    pub spans: Vec<Span>,
    /// Highest `$history` event number incorporated for this session
    /// (spec §5a); 0 before any history has been seen.
    pub ack: u64,
    #[serde(flatten)]
    pub action: Action,
}

impl Reply {
    /// The stand-down reply: no card, no ghost, key delegates. Also what
    /// the shim must synthesize locally on any protocol failure (spec §8).
    pub fn stand_down() -> Self {
        Reply {
            v: VERSION,
            card: String::new(),
            ghost: String::new(),
            ghost_style: String::new(),
            spans: Vec::new(),
            ack: 0,
            action: Action::Delegate,
        }
    }
}

/// Sent instead of a [`Reply`] when the request cannot be honoured; the
/// shim goes silent and stashes it for `clicue doctor` (spec §10). Must
/// never echo request content — the request may be a command line.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ErrorFrame {
    pub v: u32,
    pub error: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_round_trips() {
        let req = Request {
            v: VERSION,
            session: Session {
                pid: 4242,
                start: 1754160000,
            },
            event: Event::Key {
                name: "accept".into(),
            },
            buffer: "git sta".into(),
            cursor: 7,
            cols: 120,
            lines: 40,
            keymap: "main".into(),
            pending: None,
            env: None,
            hist: vec![HistEntry(101, "git status".into())],
            nav: Some(NavContext {
                pwd: "/home/op/proj".into(),
                oldpwd: Some("/home/op".into()),
                dirstack: vec!["/home/op".into(), "/tmp".into()],
            }),
        };
        let line = serde_json::to_string(&req).unwrap();
        assert!(!line.contains('\n'), "one frame must be one line");
        assert!(line.contains(r#"[101,"git status"]"#), "hist is [n, line]");
        // The wire shape the shim's _clicue_nav_json emits, exactly.
        assert!(line.contains(
            r#""nav":{"pwd":"/home/op/proj","oldpwd":"/home/op","dirstack":["/home/op","/tmp"]}"#
        ));
        let back: Request = serde_json::from_str(&line).unwrap();
        assert_eq!(back.buffer, "git sta");
        assert_eq!(back.hist[0].0, 101);
        assert_eq!(back.nav.unwrap().dirstack.len(), 2);
    }

    #[test]
    fn nav_is_additive_and_optional() {
        // An older shim omits nav entirely; a fresh shell omits oldpwd and
        // dirstack. Both must parse — §10's additive-field policy.
        let minimal = r#"{"v":1,"session":{"pid":1,"start":0},"event":{"kind":"redraw"},"buffer":"","cursor":0,"cols":80,"lines":24,"keymap":"main"}"#;
        let back: Request = serde_json::from_str(minimal).unwrap();
        assert!(back.nav.is_none());
        let fresh = r#"{"v":1,"session":{"pid":1,"start":0},"event":{"kind":"redraw"},"buffer":"","cursor":0,"cols":80,"lines":24,"keymap":"main","nav":{"pwd":"/home/op"}}"#;
        let back: Request = serde_json::from_str(fresh).unwrap();
        let nav = back.nav.unwrap();
        assert_eq!(nav.pwd, "/home/op");
        assert!(nav.oldpwd.is_none());
        assert!(nav.dirstack.is_empty());
    }

    #[test]
    fn optional_fields_absent_from_wire_and_input() {
        let req = Request {
            v: VERSION,
            session: Session { pid: 1, start: 0 },
            event: Event::Redraw,
            buffer: String::new(),
            cursor: 0,
            cols: 80,
            lines: 24,
            keymap: "main".into(),
            pending: None,
            env: None,
            hist: vec![],
            nav: None,
        };
        let line = serde_json::to_string(&req).unwrap();
        assert!(!line.contains("pending"));
        assert!(!line.contains("hist"));
        assert!(!line.contains("nav"));
        // The shim may omit them entirely.
        let minimal = r#"{"v":1,"session":{"pid":1,"start":0},"event":{"kind":"redraw"},"buffer":"","cursor":0,"cols":80,"lines":24,"keymap":"main"}"#;
        let back: Request = serde_json::from_str(minimal).unwrap();
        assert!(back.hist.is_empty());
    }

    #[test]
    fn reply_action_is_flattened() {
        let line = serde_json::to_string(&Reply::stand_down()).unwrap();
        assert!(line.contains(r#""action":"delegate""#));
        assert!(line.contains(r#""ack":0"#));
        let ins = Reply {
            action: Action::Insert {
                strip: 3,
                text: "status ".into(),
            },
            ..Reply::stand_down()
        };
        let line = serde_json::to_string(&ins).unwrap();
        assert!(line.contains(r#""action":"insert""#));
        assert!(line.contains(r#""strip":3"#));
        assert!(line.contains(r#""text":"status ""#));
    }

    #[test]
    fn span_offsets_survive_multibyte_text() {
        // Spans are BYTES: "│" is 3 bytes, and both sides must agree.
        let card = "│ cue";
        let span = Span {
            start: 0,
            end: "│".len(),
            style: "fg=blue".into(),
        };
        assert_eq!(span.end, 3);
        assert_eq!(&card.as_bytes()[span.start..span.end], "│".as_bytes());
    }
}
