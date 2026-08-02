//! The engine: one request in, one reply out, everything else is state.
//!
//! This is the integration seam ADR-100 drew: the shim reports events, the
//! engine decides (position → sources → layout) and answers. Per-shell
//! state lives here, keyed by protocol::Session.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use anyhow::Result;

use crate::corpus::{self, Corpus};
use crate::layout::{self, CardInput, Dims, KeyLabels, LayoutCfg, View};
use crate::model::{Cue, Mode};
use crate::protocol::{Action, Event, Reply, Request, Session, Span};
use crate::rank::RankMode;
use crate::sources::{self, ArgContext, HistoryWindow, SessionEnv, DEFAULT_WINDOW};
use crate::state::{self, SessionState};
use crate::theme::{self, Theme};

struct Sess {
    state: SessionState,
    env: SessionEnv,
    view: View,
    window: HistoryWindow,
    /// Grid geometry from the last render, for arrow/page moves.
    grid: Option<layout::Grid>,
    tier1: usize,
}

pub struct Engine {
    corpus: Corpus,
    theme: Theme,
    cfg: LayoutCfg,
    keys: KeyLabels,
    rank: RankMode,
    path_commands: std::collections::HashSet<String>,
    /// Seed for each new session's history window (newest N of HISTFILE).
    hist_seed: Vec<String>,
    sessions: Mutex<HashMap<Session, Sess>>,
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

impl Engine {
    /// Load corpus (rebuild if missing/stale — daemon start is the one
    /// place that cost is acceptable), theme, and the PATH universe.
    pub fn new() -> Result<Engine> {
        let cache = corpus::cache_path()?;
        let dirs = corpus::path_dirs();
        let histfile = corpus::default_histfile()?;
        let current = corpus::stamp(&histfile, &dirs);
        let corp = match corpus::load(&cache) {
            Ok(c) if !corpus::is_stale(&c, &current) => c,
            _ => {
                let c = corpus::build()?;
                let _ = corpus::save(&c, &cache);
                c
            }
        };
        let hist_seed = {
            // read_histfile, not read_to_string: zsh metafies the file
            // and a raw read fails UTF-8 on real histories.
            let lines = corpus::parse_history(&corpus::read_histfile(&histfile));
            let skip = lines.len().saturating_sub(DEFAULT_WINDOW);
            lines
                .into_iter()
                .skip(skip)
                .map(|h| h.line)
                .collect::<Vec<_>>()
        };
        // Theme choice comes from config later; aura is the shipped default.
        let (theme, _msgs) = theme::load("aura", None);
        Ok(Engine {
            corpus: corp,
            theme,
            cfg: LayoutCfg::default(),
            keys: KeyLabels::default(),
            rank: RankMode::Frecency,
            path_commands: corpus::scan_path(&corpus::path_dirs()),
            hist_seed,
            sessions: Mutex::new(HashMap::new()),
        })
    }

    pub fn handle(&self, req: Request) -> Reply {
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        let sess = sessions.entry(req.session.clone()).or_insert_with(|| {
            let mut window = HistoryWindow::new(DEFAULT_WINDOW);
            window.seed(self.hist_seed.iter().map(|s| s.as_str()));
            Sess {
                state: SessionState::default(),
                env: SessionEnv {
                    path_commands: self.path_commands.clone(),
                    ..SessionEnv::default()
                },
                view: View::default(),
                window,
                grid: None,
                tier1: 0,
            }
        });

        for h in &req.hist {
            sess.window.push(h.0, h.1.clone());
        }

        match &req.event {
            Event::Hello => {
                if let Some(env) = &req.env {
                    sess.env.aliases = env.aliases.clone();
                    sess.env.functions = env.functions.iter().cloned().collect();
                    sess.env.builtins = env.builtins.iter().cloned().collect();
                }
                self.ack(sess)
            }
            Event::LineFinish => {
                sess.state.on_line_finish();
                sess.view.reset();
                sess.view.maxed = false;
                self.ack(sess)
            }
            Event::Redraw => {
                sess.state.on_buffer(&req.buffer);
                self.render(sess, &req, Action::Delegate)
            }
            Event::Key { name } => self.on_key(sess, &req, name.clone()),
        }
    }

    fn ack(&self, sess: &Sess) -> Reply {
        Reply {
            ack: sess.window.ack(),
            ..Reply::stand_down()
        }
    }

    /// The card for the current buffer, or a stand-down reply carrying
    /// `action`. Mutates view/grid bookkeeping.
    fn render(&self, sess: &mut Sess, req: &Request, action: Action) -> Reply {
        let ack = sess.window.ack();
        let reply = move |card: String, spans: Vec<Span>, ghost: String, gstyle: String| Reply {
            v: crate::protocol::VERSION,
            card,
            ghost,
            ghost_style: gstyle,
            spans,
            ack,
            action,
        };

        if req.keymap == "menuselect" || sess.state.dismissed(&req.buffer) {
            sess.grid = None;
            return reply(String::new(), Vec::new(), String::new(), String::new());
        }
        let Ok(pos) = state::analyze(&req.buffer, 1) else {
            sess.grid = None;
            return reply(String::new(), Vec::new(), String::new(), String::new());
        };

        let now = now_epoch();
        let (cues, info) = self.cues_for(sess, &req.buffer, &pos, now);
        if cues.is_empty() {
            sess.grid = None;
            return reply(String::new(), Vec::new(), String::new(), String::new());
        }

        // Ghost precedence (GH1): navigated cue > newest history line > top cue.
        let sel_idx = sess.state.sel.max(1) - 1;
        let selected_stem = cues
            .get(sel_idx)
            .and_then(|c| sources::cue_stem(&c.insert, &pos.pfx));
        let hist_stem = sources::history_stem(&sess.window, &req.buffer);
        let top_stem = cues
            .first()
            .and_then(|c| sources::cue_stem(&c.insert, &pos.pfx));
        let ghost = sources::ghost_stem(sess.state.engaged, selected_stem, hist_stem, top_stem)
            .unwrap_or_default();

        let tab_inserts = sess.state.tab_inserts(
            cues.len(),
            cues.first().map(|c| c.insert == pos.pfx).unwrap_or(false),
            info,
        );

        sess.view.sel = sess.state.sel.max(1);
        sess.view.maxed = sess.state.maxed;
        let input = CardInput {
            cues: &cues,
            explain: &[],
            mode: pos.mode,
            prefix: &pos.pfx,
            info,
            argnomatch: false,
            engaged: sess.state.engaged,
            familiar: false,
            expanded: sess.state.expanded,
            tab_inserts,
            ghost: &ghost,
            invnote: &self.invnote(&pos),
            dims: Dims {
                cols: req.cols,
                lines: req.lines,
            },
            cfg: &self.cfg,
            keys: &self.keys,
        };
        match layout::render(&input, &mut sess.view, &self.theme) {
            Some(card) => {
                // View mutations (clamp, window slide) flow back to state.
                sess.state.sel = sess.view.sel;
                sess.grid = card.grid;
                sess.tier1 = card.tier1_count;
                let spans = card
                    .spans
                    .into_iter()
                    .map(|s| Span {
                        start: s.start,
                        end: s.end,
                        style: s.style,
                    })
                    .collect();
                reply(card.text, spans, ghost, self.theme.palette.ghost.clone())
            }
            None => {
                sess.grid = None;
                reply(String::new(), Vec::new(), String::new(), String::new())
            }
        }
    }

    /// Candidate resolution for a position. Returns (cues, info-card).
    fn cues_for(
        &self,
        sess: &Sess,
        buffer: &str,
        pos: &state::Position,
        now: u64,
    ) -> (Vec<Cue>, bool) {
        match pos.mode {
            Mode::Cmd => (
                sources::command_candidates(&sess.env, &self.corpus, &pos.pfx, self.rank, now),
                false,
            ),
            Mode::Arg => {
                let words: Vec<&str> = pos.words.iter().map(|s| s.as_str()).collect();
                let ctx = ArgContext {
                    corpus: &self.corpus,
                    window: &sess.window,
                    buffer,
                    words,
                    prefix: &pos.pfx,
                };
                (sources::arg_history_candidates(&ctx, 40), false)
            }
        }
    }

    /// E5: how often the operator has run THIS invocation.
    fn invnote(&self, pos: &state::Position) -> String {
        if pos.mode != Mode::Arg {
            return String::new();
        }
        let key = pos.words.join(" ");
        let key = self.corpus.invoke_alias.get(&key).cloned().unwrap_or(key);
        let Some(stat) = self.corpus.invoke.get(&key) else {
            return String::new();
        };
        let mut out = format!("run {}×", stat.count);
        if stat.pct > 0 {
            out.push_str(&format!("  ·  top {}% of your invocations", stat.pct));
        }
        if stat.last > 0 {
            let days = now_epoch().saturating_sub(stat.last) / 86400;
            match days {
                0 => out.push_str("  ·  today"),
                1 => out.push_str("  ·  yesterday"),
                d => out.push_str(&format!("  ·  {d}d ago")),
            }
        }
        out
    }

    fn on_key(&self, sess: &mut Sess, req: &Request, name: String) -> Reply {
        let buffer = &req.buffer;
        sess.state.on_buffer(buffer);

        // What the card is currently showing decides what keys can do.
        let pos = state::analyze(buffer, 1).ok();
        let now = now_epoch();
        let (cues, info) = match &pos {
            Some(p) if req.keymap != "menuselect" && !sess.state.dismissed(buffer) => {
                self.cues_for(sess, buffer, p, now)
            }
            _ => (Vec::new(), false),
        };
        let total = cues.len();

        match name.as_str() {
            "accept" => {
                if total == 0 {
                    return self.render(sess, req, Action::Delegate);
                }
                let pfx = pos.as_ref().map(|p| p.pfx.as_str()).unwrap_or("");
                let exact = cues.first().map(|c| c.insert == pfx).unwrap_or(false);
                if sess.state.tab_inserts(total, exact, info) {
                    sess.state.engaged = true;
                    return self.insert_reply(sess, &cues, 1, pfx);
                }
                sess.state.tab_cycle(self.cfg.tier1_rows, total, false);
                self.render(sess, req, Action::Consume)
            }
            "dismiss" => {
                sess.state.dismiss(buffer);
                self.render(sess, req, Action::Consume)
            }
            "enter" => {
                if sess.state.engaged && total > 0 && !info {
                    let sel = sess.state.sel.max(1);
                    let pfx = pos.as_ref().map(|p| p.pfx.as_str()).unwrap_or("");
                    let r = self.insert_reply(sess, &cues, sel, pfx);
                    sess.state.reset_selection();
                    return r;
                }
                self.render(sess, req, Action::Delegate)
            }
            "scroll-up" | "arrow-up" => self.moved(sess, req, -1, total),
            "scroll-down" | "arrow-down" => self.moved(sess, req, 1, total),
            "arrow-right" => {
                if sess.state.engaged && sess.grid.is_some() && grid_focus(sess) {
                    let rows = sess.grid.map(|g| g.rows as i64).unwrap_or(1);
                    return self.moved(sess, req, rows, total);
                }
                // At end of line the ghost is the proposal (keys.md).
                let at_end = req.cursor >= buffer.chars().count();
                if at_end {
                    let r = self.render(sess, req, Action::Delegate);
                    if !r.ghost.is_empty() {
                        let ghost = r.ghost.clone();
                        sess.state.reset_selection();
                        return Reply {
                            action: Action::Insert {
                                strip: 0,
                                text: ghost,
                            },
                            card: String::new(),
                            spans: Vec::new(),
                            ghost: String::new(),
                            ..r
                        };
                    }
                    return r;
                }
                self.render(sess, req, Action::Delegate)
            }
            "arrow-left" => {
                if sess.state.engaged && grid_focus(sess) {
                    let rows = sess.grid.map(|g| g.rows as i64).unwrap_or(1);
                    return self.moved(sess, req, -rows, total);
                }
                self.render(sess, req, Action::Delegate)
            }
            "page-down" => self.moved(sess, req, page(sess) as i64, total),
            "page-up" => self.moved(sess, req, -(page(sess) as i64), total),
            "home" => self.moved(sess, req, -(total as i64), total),
            "end" => self.moved(sess, req, total as i64, total),
            "expand" => {
                sess.state.expanded = !sess.state.expanded;
                self.render(sess, req, Action::Consume)
            }
            "maximize" => {
                sess.state.maxed = !sess.state.maxed;
                self.render(sess, req, Action::Consume)
            }
            _ => self.render(sess, req, Action::Delegate),
        }
    }

    fn moved(&self, sess: &mut Sess, req: &Request, delta: i64, total: usize) -> Reply {
        if sess.state.move_sel(delta, total) {
            self.render(sess, req, Action::Consume)
        } else {
            self.render(sess, req, Action::Delegate)
        }
    }

    /// Compose the insertion: cue + its declared suffix, replacing the
    /// typed prefix (strip in CHARACTERS — protocol Insert contract).
    fn insert_reply(&self, sess: &mut Sess, cues: &[Cue], sel: usize, pfx: &str) -> Reply {
        let cue = &cues[sel.min(cues.len()) - 1];
        let tail = match &cue.suffix {
            None => " ",
            Some(s) if s.is_empty() => "",
            Some(s) => s.as_str(),
        };
        // The typed prefix is replaced whether the cue extends it or is a
        // canonical respelling of it — both cases remove what was typed.
        let strip = pfx.chars().count();
        Reply {
            action: Action::Insert {
                strip,
                text: format!("{}{}", cue.insert, tail),
            },
            ack: sess.window.ack(),
            ..Reply::stand_down()
        }
    }
}

fn grid_focus(sess: &Sess) -> bool {
    sess.grid
        .map(|g| sess.state.sel >= g.lo && sess.state.sel <= g.hi)
        .unwrap_or(false)
}

fn page(sess: &Sess) -> usize {
    sess.grid
        .map(|g| g.page)
        .filter(|p| *p > 0)
        .unwrap_or_else(|| sess.tier1.max(1))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{EnvPayload, HistEntry, Session as PSession, VERSION};

    fn engine_with(corpus: Corpus) -> Engine {
        Engine {
            corpus,
            theme: theme::base(),
            cfg: LayoutCfg::default(),
            keys: KeyLabels::default(),
            rank: RankMode::Frecency,
            path_commands: ["cargo", "git", "cat"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            hist_seed: vec!["git status".into(), "cargo build".into()],
            sessions: Mutex::new(HashMap::new()),
        }
    }

    fn test_corpus() -> Corpus {
        crate::corpus::build_from_parts(
            ": 1700000000:0;git status\n: 1700000100:0;cargo build\n: 1700000200:0;cargo build\n",
            "cargo (1) - Rust package manager\ngit (1) - the stupid content tracker\n",
            &["cargo", "git", "cat"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
        )
    }

    fn req(event: Event, buffer: &str) -> Request {
        Request {
            v: VERSION,
            session: PSession { pid: 7, start: 1 },
            event,
            buffer: buffer.into(),
            cursor: buffer.chars().count(),
            cols: 100,
            lines: 30,
            keymap: "main".into(),
            pending: None,
            env: None,
            hist: vec![],
        }
    }

    #[test]
    fn hello_then_redraw_yields_a_card_with_ranked_candidates() {
        let e = engine_with(test_corpus());
        let mut hello = req(Event::Hello, "");
        hello.env = Some(EnvPayload::default());
        e.handle(hello);

        let r = e.handle(req(Event::Redraw, "ca"));
        assert!(!r.card.is_empty(), "expected a card for prefix 'ca'");
        assert!(r.card.contains("cargo"));
        assert!(r.card.contains("Rust package manager"));
        assert!(!r.spans.is_empty());
        // ghost proposes the rest of the newest matching history line
        assert_eq!(r.ghost, "rgo build");
    }

    #[test]
    fn tab_cycles_then_enter_inserts_with_prefix_strip() {
        let e = engine_with(test_corpus());
        e.handle(req(Event::Hello, ""));
        e.handle(req(Event::Redraw, "ca"));
        let r = e.handle(req(
            Event::Key {
                name: "accept".into(),
            },
            "ca",
        ));
        assert_eq!(r.action, Action::Consume, "first Tab engages and cycles");
        let r = e.handle(req(
            Event::Key {
                name: "enter".into(),
            },
            "ca",
        ));
        match r.action {
            Action::Insert { strip, ref text } => {
                assert_eq!(strip, 2, "typed prefix replaced by length");
                assert!(text.starts_with("ca"), "top cue starts with prefix: {text}");
                assert!(text.ends_with(' '));
            }
            other => panic!("expected insert, got {other:?}"),
        }
    }

    #[test]
    fn dismiss_hides_for_this_buffer_and_typing_revives() {
        let e = engine_with(test_corpus());
        e.handle(req(Event::Hello, ""));
        e.handle(req(Event::Redraw, "ca"));
        let r = e.handle(req(
            Event::Key {
                name: "dismiss".into(),
            },
            "ca",
        ));
        assert_eq!(r.action, Action::Consume);
        assert!(r.card.is_empty(), "dismissed: no card");
        let r = e.handle(req(Event::Redraw, "ca"));
        assert!(r.card.is_empty(), "same buffer stays dismissed");
        let r = e.handle(req(Event::Redraw, "car"));
        assert!(!r.card.is_empty(), "typing revives the card");
    }

    #[test]
    fn menuselect_stands_down_and_line_finish_acks_history() {
        let e = engine_with(test_corpus());
        let mut r1 = req(Event::Redraw, "ca");
        r1.keymap = "menuselect".into();
        assert!(e.handle(r1).card.is_empty());

        let mut lf = req(Event::LineFinish, "");
        lf.hist = vec![HistEntry(4210, "cargo test".into())];
        let r = e.handle(lf);
        assert_eq!(r.ack, 4210);
        // the new line immediately informs the ghost
        let r = e.handle(req(Event::Redraw, "cargo t"));
        assert_eq!(r.ghost, "est");
    }

    #[test]
    fn arrow_up_before_engagement_delegates_to_history() {
        let e = engine_with(test_corpus());
        e.handle(req(Event::Redraw, "ca"));
        let r = e.handle(req(
            Event::Key {
                name: "arrow-up".into(),
            },
            "ca",
        ));
        assert_eq!(r.action, Action::Delegate, "plain arrows belong to history");
    }
}
