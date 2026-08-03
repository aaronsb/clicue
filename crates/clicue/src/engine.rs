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
use crate::flags::{self, FlagStore, Harvest};
use crate::layout::{self, CardInput, Dims, KeyLabels, LayoutCfg, View};
use crate::model::{Cue, Kind, Mode};
use crate::nav::{self, NavScanner};
use crate::protocol::{Action, Event, NavContext, Reply, Request, Session, Span};
use crate::rank::RankMode;
use crate::sources::{self, ArgContext, HistoryWindow, SessionEnv, DEFAULT_WINDOW};
use crate::state::{self, SessionState};
use crate::theme::{self, Theme};

pub(crate) struct Sess {
    state: SessionState,
    /// Live compsys harvest for the exact buffer it was taken at —
    /// membership authority that supersedes the cache (sources spec).
    live: Option<Harvest>,
    env: SessionEnv,
    view: View,
    window: HistoryWindow,
    /// Grid geometry from the last render, for arrow/page moves.
    grid: Option<layout::Grid>,
    tier1: usize,
}

pub struct Engine {
    corpus: Corpus,
    flags: FlagStore,
    theme: Theme,
    cfg: LayoutCfg,
    keys: KeyLabels,
    rank: RankMode,
    path_commands: std::collections::HashSet<String>,
    /// Seed for each new session's history window (newest N of HISTFILE).
    hist_seed: Vec<String>,
    sessions: SharedSessions,
    /// Ring cache for the "you are here" pane — daemon-lifetime, shared
    /// across shells. Rebuilt empty on a hot-reload swap: the cache is
    /// warmth, not state, and a cold first render costs ~0.1 ms.
    nav_scanner: Mutex<NavScanner>,
}

/// What candidate resolution produced, beyond the cues themselves.
#[derive(Default)]
struct CueSet {
    cues: Vec<Cue>,
    info: bool,
    argnomatch: bool,
    /// Membership came from a live compsys harvest for this buffer.
    live_membership: bool,
}

fn info_cue(cmd: &str, gloss: &str) -> Cue {
    Cue {
        insert: cmd.to_string(),
        label: cmd.to_string(),
        gloss: gloss.to_string(),
        kind: Kind::Arg,
        suffix: None,
    }
}

fn now_epoch() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

/// Sessions live OUTSIDE the engine so a config hot-reload can swap the
/// engine without open shells losing their hello universes (aliases,
/// functions), dismissals, or live harvests.
pub(crate) type SharedSessions = std::sync::Arc<Mutex<HashMap<Session, Sess>>>;

/// How a fresh engine treats the corpus cache (S7). `RebuildIfStale` is
/// for the daemon's FIRST engine — start is the one place a whatis-sized
/// build cost is acceptable, and the place trailing history folds in.
/// Every hot-reload swap is `LoadOnly`: a live histfile moves with every
/// command, so a swap that rebuilt-if-stale would build (and save, and
/// re-trigger the corpus watch) on every config edit — and could chase a
/// busy shell in a rebuild loop. Either way a missing or unreadable cache
/// falls back to a build.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CorpusPolicy {
    RebuildIfStale,
    LoadOnly,
}

impl Engine {
    /// Load corpus (rebuild if missing/stale — daemon start is the one
    /// place that cost is acceptable), theme, and the PATH universe.
    pub fn new() -> Result<Engine> {
        Self::new_shared(SharedSessions::default(), CorpusPolicy::RebuildIfStale)
    }

    /// The hot-reload entry: a fresh engine over EXISTING sessions.
    pub(crate) fn new_shared(sessions: SharedSessions, policy: CorpusPolicy) -> Result<Engine> {
        let cache = corpus::cache_path()?;
        let dirs = corpus::path_dirs();
        let histfile = corpus::default_histfile()?;
        let current = corpus::stamp(&histfile, &dirs);
        let corp = match (corpus::load(&cache), policy) {
            (Ok(c), CorpusPolicy::LoadOnly) => c,
            (Ok(c), CorpusPolicy::RebuildIfStale) if !corpus::is_stale(&c, &current) => c,
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
        let loaded = crate::config::load();
        for w in &loaded.warnings {
            eprintln!("clicue daemon: config: {w}");
        }
        let cfgf = loaded.config;
        // The SAME directory the CLI validates against and the reloader
        // watches (config::themes_dir, one owner) — `None` here meant the
        // daemon silently resolved every operator TOML theme to `base`
        // while the tool surface reported it set (review #19). Seeding a
        // missing file (T14) touches the watched themes dir and costs one
        // bounded extra swap, the S7 absent-cache pattern: the second
        // swap finds the file present and writes nothing.
        let (theme, msgs) =
            theme::load_or_seed(&cfgf.theme, crate::config::themes_dir().as_deref());
        for m in &msgs {
            eprintln!("clicue daemon: theme: {m}");
        }
        Ok(Engine {
            corpus: corp,
            flags: FlagStore::new(
                FlagStore::default_dir()?,
                corpus::path_dirs(),
                cfgf.emulates.clone().into_iter().collect(),
            ),
            theme,
            cfg: LayoutCfg {
                tier1_rows: cfgf.tier1_rows,
                min_width: cfgf.min_width,
                max_width: cfgf.max_width,
                max_lines: cfgf.max_lines,
                tier2_rows: cfgf.tier2_rows,
            },
            keys: KeyLabels::default(),
            rank: RankMode::parse(&cfgf.ranking),
            path_commands: corpus::scan_path(&corpus::path_dirs()),
            hist_seed,
            sessions,
            nav_scanner: Mutex::new(NavScanner::new()),
        })
    }

    pub fn handle(&self, req: Request) -> Reply {
        let mut sessions = self.sessions.lock().unwrap_or_else(|e| e.into_inner());
        // (sessions are shared across engine swaps — see SharedSessions)
        let sess = sessions.entry(req.session.clone()).or_insert_with(|| {
            let mut window = HistoryWindow::new(DEFAULT_WINDOW);
            window.seed(self.hist_seed.iter().map(|s| s.as_str()));
            Sess {
                state: SessionState::default(),
                live: None,
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

        // Harvest payloads ride any event. Live captures are membership
        // for that exact buffer; synthesised ancestors feed the store.
        if let Some(p) = &req.pending {
            if let Some(pending) = flags::parse_pending(p) {
                for h in pending.harvests {
                    if h.live {
                        sess.live = Some(h);
                    } else if let Err(e) = self.flags.ingest(&h, &sess.env.aliases) {
                        eprintln!("clicue daemon: flag ingest: {e:#}");
                    }
                }
            }
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
        let set = self.cues_for(sess, &req.buffer, &pos, now, req.nav.as_ref());
        let cues = set.cues;
        let info = set.info;
        let explain = self.explain_rows(sess, &pos, req.nav.as_ref());
        if cues.is_empty() && explain.is_empty() {
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
            explain: &explain,
            mode: pos.mode,
            prefix: &pos.pfx,
            info,
            argnomatch: set.argnomatch,
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

    /// Candidate resolution for a position.
    fn cues_for(
        &self,
        sess: &Sess,
        buffer: &str,
        pos: &state::Position,
        now: u64,
        navctx: Option<&NavContext>,
    ) -> CueSet {
        match pos.mode {
            Mode::Cmd => CueSet {
                cues: sources::command_candidates(
                    &sess.env,
                    &self.corpus,
                    &pos.pfx,
                    self.rank,
                    now,
                ),
                ..CueSet::default()
            },
            Mode::Arg => {
                let mut set = self.arg_cues(sess, buffer, pos);
                if let Some(cue) = self.nav_suggestion(sess, pos, navctx) {
                    set.cues.push(cue);
                    set.info = false;
                }
                set
            }
        }
    }

    /// The effective command, resolved one alias deep, tested against the
    /// navigational class (design note). Unknown fails safe to false.
    fn navigational(&self, sess: &Sess, pos: &state::Position) -> bool {
        let words: Vec<&str> = pos.words.iter().map(|s| s.as_str()).collect();
        let Some(eff) = sources::effective_command(&words) else {
            return false;
        };
        if nav::is_navigational(eff) {
            return true;
        }
        sess.env
            .aliases
            .get(eff)
            .and_then(|e| e.split_whitespace().next())
            .map(nav::is_navigational)
            .unwrap_or(false)
    }

    /// The failure-only recommendation (design note): a Tab-reachable
    /// candidate, never a buffer rewrite, offered ONLY when the typed
    /// target will not resolve from here and exactly one known directory
    /// matches. Success needs no recommendation; ambiguity gets silence.
    fn nav_suggestion(
        &self,
        sess: &Sess,
        pos: &state::Position,
        navctx: Option<&NavContext>,
    ) -> Option<Cue> {
        let ctx = navctx?;
        if pos.pfx.is_empty() || !self.navigational(sess, pos) {
            return None;
        }
        let home = std::env::var("HOME").ok();
        let resolved = nav::resolve_target(
            &pos.pfx,
            &ctx.pwd,
            ctx.oldpwd.as_deref(),
            &ctx.dirstack,
            home.as_deref(),
        );
        // Only a target that fails from here earns a suggestion; a target
        // that resolves (or needs state we lack) gets explanation only.
        match &resolved {
            Some(r) if !r.exists => {}
            _ => return None,
        }
        let rings = {
            let mut sc = self.nav_scanner.lock().unwrap_or_else(|e| e.into_inner());
            sc.rings(std::path::Path::new(&ctx.pwd))
        };
        let hit = nav::did_you_mean(
            &pos.pfx,
            &ctx.pwd,
            &rings,
            ctx.oldpwd.as_deref(),
            &ctx.dirstack,
        )?;
        let display = nav::tilde(&hit, home.as_deref());
        // The inserted spelling must survive the shell: a quiet path
        // rides as-is (`~` expands unquoted); anything else is quoted in
        // absolute form.
        let insert = if display
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '/' | '.' | '_' | '-' | '~' | '+'))
        {
            display.clone()
        } else {
            format!("'{}'", hit.to_string_lossy().replace('\'', r"'\''"))
        };
        Some(Cue {
            insert,
            label: display,
            gloss: format!("did you mean? — ⟨{}⟩ doesn't resolve from here", pos.pfx),
            kind: Kind::Arg,
            suffix: None,
        })
    }

    /// Argument position: the operator's habits lead (tier 1), the
    /// documented parameter set follows — live compsys membership
    /// superseding the cache when Tab has produced one for this buffer.
    fn arg_cues(&self, sess: &Sess, buffer: &str, pos: &state::Position) -> CueSet {
        let words: Vec<&str> = pos.words.iter().map(|s| s.as_str()).collect();
        let ctx = ArgContext {
            corpus: &self.corpus,
            window: &sess.window,
            buffer,
            words,
            prefix: &pos.pfx,
        };
        let mut cues = sources::arg_history_candidates(&ctx, 40);
        let mut seen: std::collections::HashSet<String> =
            cues.iter().map(|c| c.insert.clone()).collect();
        let mut set = CueSet::default();

        // The parameter set is there to arrow into, not only to filter
        // (sources spec): shown on every argument-position card, except a
        // non-flag word being typed (a subcommand name is being narrowed).
        let show_flags = pos.pfx.is_empty() || pos.pfx.starts_with('-') || pos.optctx;
        if !show_flags {
            set.cues = cues;
            return set;
        }
        let resolved = flags::resolve_path(&pos.cmdpath, &sess.env.aliases, &self.flags.emulates);

        // Live harvest for THIS buffer: compsys's membership is the
        // answer; the cache only decorates it with labels and grouping.
        if let Some(live) = sess.live.as_ref().filter(|h| h.pos == buffer) {
            let rel = pos
                .pfx
                .strip_prefix(&live.iprefix)
                .unwrap_or(pos.pfx.as_str());
            for (i, w) in live.words.iter().enumerate() {
                if !rel.is_empty() && !w.starts_with(rel) {
                    continue;
                }
                let norm = if !w.starts_with('-') && live.iprefix.starts_with('-') {
                    format!("{}{w}", live.iprefix)
                } else {
                    w.clone()
                };
                if !seen.insert(norm.clone()) {
                    continue;
                }
                let gloss = live
                    .descs
                    .get(i)
                    .and_then(|d| flags::unpack_desc(w, d))
                    .or_else(|| self.flags.explain(&resolved, &norm).map(|(_, d)| d))
                    .unwrap_or_default();
                let label = self
                    .flags
                    .explain(&resolved, &norm)
                    .map(|(l, _)| l)
                    .unwrap_or_else(|| norm.clone());
                let suffix = live.sfx.get(w).cloned().map(Some).unwrap_or(None);
                set.live_membership = true;
                cues.push(Cue {
                    insert: norm,
                    label,
                    gloss,
                    kind: Kind::Arg,
                    suffix,
                });
            }
            set.cues = cues;
            return set;
        }

        // Cache path: grouped rows, prefix-filtered; a flag prefix that
        // matches nothing is a TYPO — offer the whole set and say so.
        match self.flags.get(&resolved) {
            Some(Some(_)) => {
                let rows = self.flags.rows(&resolved).unwrap_or_default();
                let matched: Vec<_> = rows
                    .iter()
                    .filter(|r| pos.pfx.is_empty() || r.insert.starts_with(&pos.pfx))
                    .collect();
                let (chosen, argnomatch) =
                    if matched.is_empty() && pos.pfx.starts_with('-') && !rows.is_empty() {
                        (rows.iter().collect::<Vec<_>>(), true)
                    } else {
                        (matched, false)
                    };
                set.argnomatch = argnomatch;
                for r in chosen {
                    if !seen.insert(r.insert.clone()) {
                        continue;
                    }
                    cues.push(Cue {
                        insert: r.insert.clone(),
                        label: r.label.clone(),
                        gloss: r.gloss.clone(),
                        kind: Kind::Arg,
                        suffix: r.suffix.clone(),
                    });
                }
                set.cues = cues;
            }
            Some(None) => {
                // Fetched, and the command documents nothing (H3).
                if cues.is_empty() && pos.pfx.starts_with('-') {
                    set.info = true;
                    set.cues = vec![info_cue(&pos.cmd, "no documented options")];
                } else {
                    set.cues = cues;
                }
            }
            None => {
                // Never harvested. A leading dash is never a filename:
                // keep the card and tell the operator how to fill it.
                if pos.pfx.starts_with('-') || (pos.optctx && cues.is_empty()) {
                    if cues.is_empty() {
                        set.info = true;
                        set.cues = vec![info_cue(
                            &pos.cmd,
                            "press Tab to load this command's options",
                        )];
                    } else {
                        set.cues = cues;
                    }
                } else {
                    set.cues = cues;
                }
            }
        }
        set
    }

    /// E-rules: what the operator ALREADY typed, explained. Walks the
    /// tokens left to right maintaining the command path — subcommands
    /// descend, flags do not, values say nothing. For a navigational
    /// command, the typed target additionally resolves against relayed
    /// place — where it lands, and whether that exists (design note
    /// "Resolution and existence").
    fn explain_rows(
        &self,
        sess: &Sess,
        pos: &state::Position,
        navctx: Option<&NavContext>,
    ) -> Vec<crate::model::ExplainRow> {
        if pos.mode != Mode::Arg || pos.words.len() < 2 {
            return Vec::new();
        }
        let mut rows = Vec::new();
        if let Some(ctx) = navctx {
            if !pos.pfx.is_empty() && self.navigational(sess, pos) {
                let home = std::env::var("HOME").ok();
                if let Some(r) = nav::resolve_target(
                    &pos.pfx,
                    &ctx.pwd,
                    ctx.oldpwd.as_deref(),
                    &ctx.dirstack,
                    home.as_deref(),
                ) {
                    let dest = nav::tilde(&r.path, home.as_deref());
                    let desc = if r.exists {
                        format!("→ {dest}")
                    } else {
                        format!("→ {dest} — no such directory")
                    };
                    rows.push(crate::model::ExplainRow {
                        label: pos.pfx.clone(),
                        desc,
                    });
                }
            }
        }
        let mut seen: std::collections::HashSet<String> = std::collections::HashSet::new();
        let mut epath = pos.words[0].clone();
        for tok in &pos.words[1..] {
            let resolved = flags::resolve_path(&epath, &sess.env.aliases, &self.flags.emulates);
            if !tok.starts_with('-') {
                if let Some((label, desc)) = self.flags.explain(&resolved, tok) {
                    if seen.insert(tok.clone()) {
                        rows.push(crate::model::ExplainRow { label, desc });
                    }
                }
                // Descend regardless: an undocumented subcommand still
                // changes what the NEXT token means.
                epath.push(':');
                epath.push_str(tok);
                continue;
            }
            if let Some((label, desc)) = self.flags.explain(&resolved, tok) {
                if seen.insert(tok.clone()) {
                    rows.push(crate::model::ExplainRow { label, desc });
                }
            }
        }
        rows
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
        let set = match &pos {
            Some(p) if req.keymap != "menuselect" && !sess.state.dismissed(buffer) => {
                self.cues_for(sess, buffer, p, now, req.nav.as_ref())
            }
            _ => CueSet::default(),
        };
        let cues = set.cues;
        let info = set.info;
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
            flags: FlagStore::new(
                std::env::temp_dir().join(format!("clicue-engine-test-{}", std::process::id())),
                Vec::new(),
                std::collections::HashMap::new(),
            ),
            theme: theme::base(),
            cfg: LayoutCfg::default(),
            keys: KeyLabels::default(),
            rank: RankMode::Frecency,
            path_commands: ["cargo", "git", "cat"]
                .iter()
                .map(|s| s.to_string())
                .collect(),
            hist_seed: vec!["git status".into(), "cargo build".into()],
            sessions: SharedSessions::default(),
            nav_scanner: Mutex::new(NavScanner::new()),
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
            nav: None,
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
    fn nav_resolution_row_and_failure_only_suggestion() {
        use crate::protocol::NavContext;
        let root = std::env::temp_dir().join(format!("clicue-engine-nav-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(root.join("pwd/crates")).unwrap();
        // Siblings of pwd: the right-name-wrong-place pool. The class of
        // error served is a correct name typed from the wrong directory —
        // typos are deliberately NOT matched (design note: no fuzzy).
        std::fs::create_dir_all(root.join("target-dir")).unwrap();
        std::fs::create_dir_all(root.join("appalpha")).unwrap();
        std::fs::create_dir_all(root.join("appbeta")).unwrap();
        let pwd = root.join("pwd").to_string_lossy().into_owned();
        let navctx = || {
            Some(NavContext {
                pwd: pwd.clone(),
                oldpwd: Some("/tmp".into()),
                dirstack: vec![],
            })
        };
        let e = engine_with(test_corpus());

        // A target that resolves: explanation row with the destination,
        // and NO recommendation — success needs none.
        let mut r1 = req(Event::Redraw, "cd crates");
        r1.cols = 220;
        r1.nav = navctx();
        let r = e.handle(r1);
        assert!(r.card.contains("→"), "resolution row expected: {}", r.card);
        assert!(r.card.contains("crates"));
        assert!(!r.card.contains("did you mean"));

        // The right name typed from the wrong place — target-dir is a
        // sibling, not a child: the honest failure row AND a
        // Tab-reachable suggestion naming where it actually is.
        let mut r2 = req(Event::Redraw, "cd target-dir");
        r2.cols = 220;
        r2.nav = navctx();
        let r = e.handle(r2);
        assert!(r.card.contains("no such"), "{}", r.card);
        assert!(r.card.contains("did you mean"), "{}", r.card);

        // Ambiguity degrades to silence: "app" prefixes two siblings.
        let mut r3 = req(Event::Redraw, "cd app");
        r3.cols = 220;
        r3.nav = navctx();
        let r = e.handle(r3);
        assert!(r.card.contains("no such"), "{}", r.card);
        assert!(!r.card.contains("did you mean"), "{}", r.card);

        // A typo matches nothing — fuzzy matching is rejected by design.
        let mut r3b = req(Event::Redraw, "cd crakes");
        r3b.cols = 220;
        r3b.nav = navctx();
        let r = e.handle(r3b);
        assert!(r.card.contains("no such"), "{}", r.card);
        assert!(!r.card.contains("did you mean"), "{}", r.card);

        // `cd -` resolves through relayed OLDPWD.
        let mut r4 = req(Event::Redraw, "cd -");
        r4.cols = 220;
        r4.nav = navctx();
        let r = e.handle(r4);
        assert!(r.card.contains("/tmp"), "OLDPWD resolution: {}", r.card);

        // Without nav context (older shim), navigation adds nothing.
        let r = e.handle(req(Event::Redraw, "cd crakes"));
        assert!(
            !r.card.contains("did you mean") && !r.card.contains("no such"),
            "no nav context must mean no nav rows: {}",
            r.card
        );
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn nav_suggestion_is_insertable_via_tab_and_enter() {
        use crate::protocol::NavContext;
        let root = std::env::temp_dir().join(format!("clicue-engine-navins-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        // unique-target is a SIBLING of pwd: typing its correct name from
        // inside pwd fails, and the suggestion carries its real location.
        std::fs::create_dir_all(root.join("pwd")).unwrap();
        std::fs::create_dir_all(root.join("unique-target")).unwrap();
        let pwd = root.join("pwd").to_string_lossy().into_owned();
        let e = engine_with(test_corpus());
        let with_nav = |ev: Event, buf: &str| {
            let mut r = req(ev, buf);
            r.cols = 220;
            r.nav = Some(NavContext {
                pwd: pwd.clone(),
                oldpwd: None,
                dirstack: vec![],
            });
            r
        };
        e.handle(with_nav(Event::Redraw, "cd unique-target"));
        let r = e.handle(with_nav(
            Event::Key {
                name: "accept".into(),
            },
            "cd unique-target",
        ));
        // One candidate (the suggestion), prefix not equal to it: first
        // Tab inserts it, replacing the typed word by length.
        match r.action {
            Action::Insert { strip, ref text } => {
                assert_eq!(strip, "unique-target".chars().count());
                assert!(
                    text.contains("unique-target") && text.contains('/'),
                    "suggestion inserted with its real location: {text}"
                );
            }
            Action::Consume => {
                // Or the card engaged first (tab_inserts=false path):
                // Enter must then insert it.
                let r = e.handle(with_nav(
                    Event::Key {
                        name: "enter".into(),
                    },
                    "cd unique-target",
                ));
                match r.action {
                    Action::Insert { ref text, .. } => {
                        assert!(text.contains("unique-target"), "{text}")
                    }
                    other => panic!("expected insert after enter, got {other:?}"),
                }
            }
            other => panic!("expected insert or consume, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(&root);
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
