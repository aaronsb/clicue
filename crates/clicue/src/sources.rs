//! Candidate resolution: what the card proposes, and in what order.
//!
//! Contract: spec/sources.md. Command position ranks the shell's own
//! namespace by the operator's history; argument position splits on
//! pathish — whole remembered lines where values are worth replaying,
//! flag-only invocation keys where they are not — and always fails safe
//! toward "no proposed path" (G3). The compsys half of argument position
//! enters through [`FlagSource`], stubbed until the bridge lands.

use std::collections::{HashMap, HashSet, VecDeque};

use crate::corpus::Corpus;
use crate::model::{Cue, Kind};
use crate::rank::{partition_rank, RankMode};

/// What the shim reported about the shell's namespace at init — the
/// daemon's substitute for reading `$aliases`/`$functions`/`$builtins`
/// in-process. PATH commands come from the daemon's own scan.
#[derive(Debug, Clone, Default)]
pub struct SessionEnv {
    /// alias name → its expansion (the gloss shows the expansion, A3).
    pub aliases: HashMap<String, String>,
    pub functions: HashSet<String>,
    /// Builtins plus reserved words.
    pub builtins: HashSet<String>,
    pub path_commands: HashSet<String>,
}

// ── command position (spec §A) ──────────────────────────────────────────

/// Candidates for a command-position prefix: precedence alias > function >
/// builtin > system (A1), `_`/`.`-prefixed functions excluded (A2), ranked
/// by partition (A4) under the given mode.
pub fn command_candidates(
    env: &SessionEnv,
    corpus: &Corpus,
    prefix: &str,
    mode: RankMode,
    now: u64,
) -> Vec<Cue> {
    let mut kind: HashMap<&str, Kind> = HashMap::new();
    for name in env.aliases.keys() {
        if name.starts_with(prefix) {
            kind.insert(name, Kind::Alias);
        }
    }
    for name in &env.functions {
        if name.starts_with(prefix) && !name.starts_with('_') && !name.starts_with('.') {
            kind.entry(name).or_insert(Kind::Function);
        }
    }
    for name in &env.builtins {
        if name.starts_with(prefix) {
            kind.entry(name).or_insert(Kind::Builtin);
        }
    }
    for name in &env.path_commands {
        if name.starts_with(prefix) {
            kind.entry(name).or_insert(Kind::System);
        }
    }

    let names: Vec<String> = kind.keys().map(|s| s.to_string()).collect();
    let ordered = partition_rank(
        names,
        |n| {
            (
                corpus.freq.get(n).copied().unwrap_or(0),
                corpus.last.get(n).copied().unwrap_or(0),
            )
        },
        mode,
        now,
    );

    ordered
        .into_iter()
        .map(|name| {
            let k = *kind.get(name.as_str()).unwrap_or(&Kind::System);
            let gloss = match k {
                Kind::Alias => env.aliases.get(&name).cloned().unwrap_or_default(),
                Kind::Function => corpus
                    .gloss
                    .get(&name)
                    .cloned()
                    .unwrap_or_else(|| "shell function".into()),
                Kind::Builtin => corpus
                    .gloss
                    .get(&name)
                    .cloned()
                    .unwrap_or_else(|| "shell builtin".into()),
                _ => corpus.gloss.get(&name).cloned().unwrap_or_default(),
            };
            Cue {
                insert: name.clone(),
                label: name,
                gloss,
                kind: k,
                suffix: None,
            }
        })
        .collect()
}

// ── the effective command (spec §C) ─────────────────────────────────────

/// Wrappers this walk sees through (C1). Deliberately not a general parse.
const WRAPPERS: &[&str] = &[
    "sudo", "doas", "env", "command", "builtin", "exec", "nohup", "nice", "ionice", "setsid",
    "stdbuf", "time",
];

fn is_assignment(w: &str) -> bool {
    let Some(eq) = w.find('=') else { return false };
    let name = &w[..eq];
    let mut chars = name.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic() || c == '_')
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// What the line actually runs. None means UNKNOWN — a wrapper option
/// whose arity we don't know (C3), or a wrapper with nothing after it
/// (C4) — and unknown fails safe at the caller.
pub fn effective_command<'a>(words: &[&'a str]) -> Option<&'a str> {
    for w in words {
        if w.is_empty() || is_assignment(w) {
            continue;
        }
        if WRAPPERS.contains(w) {
            continue;
        }
        if w.starts_with('-') {
            return None;
        }
        return Some(w);
    }
    None
}

// ── the bounded history window (spec §D) ────────────────────────────────

/// Newest-N history lines, session-fresh via numbered pushes from the
/// shim (protocol §5a), bounded so a long-lived shell cannot grow back
/// the cost the window removed (D3).
#[derive(Debug, Clone)]
pub struct HistoryWindow {
    cap: usize,
    /// (event number, line); 0 for seeded pre-session lines.
    entries: VecDeque<(u64, String)>,
    ack: u64,
}

pub const DEFAULT_WINDOW: usize = 2000;

impl HistoryWindow {
    pub fn new(cap: usize) -> Self {
        HistoryWindow {
            cap: cap.max(1),
            entries: VecDeque::new(),
            ack: 0,
        }
    }

    /// Seed oldest→newest (e.g. from HISTFILE at daemon start).
    pub fn seed<'a>(&mut self, lines: impl Iterator<Item = &'a str>) {
        for l in lines {
            if !l.is_empty() {
                self.push(0, l.to_string());
            }
        }
    }

    /// One accepted line, with its zsh event number. Sourced from
    /// `$history` relayed by the shim — NEVER from the buffer (D4).
    pub fn push(&mut self, seq: u64, line: String) {
        if line.is_empty() {
            return;
        }
        self.entries.push_back((seq, line));
        while self.entries.len() > self.cap {
            self.entries.pop_front();
        }
        if seq > self.ack {
            self.ack = seq;
        }
    }

    /// Highest event number seen — the reply's `ack` (protocol §5a).
    pub fn ack(&self) -> u64 {
        self.ack
    }

    pub fn newest_first(&self) -> impl Iterator<Item = &str> {
        self.entries.iter().rev().map(|(_, l)| l.as_str())
    }
}

// ── separator truncation (E4) ───────────────────────────────────────────

const SEPARATORS: &[&str] = &["|", "||", ";", "&&", "&", "|&", "(", "{"];

/// Tokenise shell-ishly: split on unquoted whitespace; unquoted runs of
/// `|`/`&`/`;` split as their own operator tokens (so `a&&b` separates);
/// `(`/`{` count only as standalone tokens, so `file{1,2}` survives.
/// Quoting protects everything, which is what leaves a quoted `|` inside
/// an argument alone (E4).
fn tokenize(s: &str) -> Vec<String> {
    let mut toks = Vec::new();
    let mut cur = String::new();
    let mut chars = s.chars().peekable();
    let (mut in_s, mut in_d) = (false, false);
    while let Some(c) = chars.next() {
        match c {
            '\\' if !in_s => {
                cur.push(c);
                if let Some(n) = chars.next() {
                    cur.push(n);
                }
            }
            '\'' if !in_d => {
                in_s = !in_s;
                cur.push(c);
            }
            '"' if !in_s => {
                in_d = !in_d;
                cur.push(c);
            }
            c if c.is_whitespace() && !in_s && !in_d => {
                if !cur.is_empty() {
                    toks.push(std::mem::take(&mut cur));
                }
            }
            '|' | '&' | ';' if !in_s && !in_d => {
                if !cur.is_empty() {
                    toks.push(std::mem::take(&mut cur));
                }
                let mut op = String::from(c);
                while let Some(&n) = chars.peek() {
                    if matches!(n, '|' | '&' | ';') {
                        op.push(n);
                        chars.next();
                    } else {
                        break;
                    }
                }
                toks.push(op);
            }
            _ => cur.push(c),
        }
    }
    if !cur.is_empty() {
        toks.push(cur);
    }
    toks
}

/// One segment only (E4): the candidate stops at the first separator
/// token. Truncated, not rejected — the part before the separator is a
/// genuine cue. None when the segment would be empty.
fn truncate_at_separator(c: &str) -> Option<String> {
    if !c
        .chars()
        .any(|ch| matches!(ch, '|' | '&' | ';' | '(' | '{'))
    {
        return Some(c.trim_end().to_string());
    }
    let toks = tokenize(c);
    let end = toks
        .iter()
        .position(|t| SEPARATORS.contains(&t.as_str()))
        .unwrap_or(toks.len());
    if end == 0 {
        return None;
    }
    Some(toks[..end].join(" "))
}

// ── whole-line history cues (spec §E) ───────────────────────────────────

/// Whole remembered lines continuing the buffer, newest first (E1). The
/// candidate is the line minus everything left of the word under the
/// cursor (E3), truncated at separators (E4), deduped and capped (E5).
/// All matching is literal — Rust `starts_with` — which is E6 by
/// construction.
pub fn history_line_cues(
    window: &HistoryWindow,
    buffer: &str,
    prefix: &str,
    cap: usize,
) -> Vec<String> {
    if buffer.is_empty() || !buffer.ends_with(prefix) {
        return Vec::new();
    }
    let head_len = buffer.len() - prefix.len();
    let mut seen: HashSet<String> = HashSet::new();
    let mut out = Vec::new();
    for line in window.newest_first() {
        if !line.starts_with(buffer) || line == buffer {
            continue;
        }
        let Some(truncated) = truncate_at_separator(line) else {
            continue;
        };
        if truncated.len() <= head_len || !truncated.starts_with(buffer) {
            continue; // the separator fell inside what is already typed
        }
        let cand = truncated[head_len..].to_string();
        if cand == prefix || !seen.insert(cand.clone()) {
            continue;
        }
        out.push(cand);
        if out.len() >= cap {
            break;
        }
    }
    out
}

/// The ghost's whole-line proposal: newest line continuing the buffer,
/// minus the buffer. ONE function with the cue path — same window, same
/// separator rule (sources.md ambiguity 2: the ghost must never propose a
/// continuation the card would refuse).
pub fn history_stem(window: &HistoryWindow, buffer: &str) -> Option<String> {
    if buffer.is_empty() {
        return None;
    }
    for line in window.newest_first() {
        if !line.starts_with(buffer) || line == buffer {
            continue;
        }
        let truncated = truncate_at_separator(line)?;
        if truncated.len() > buffer.len() && truncated.starts_with(buffer) {
            return Some(truncated[buffer.len()..].to_string());
        }
        // Newest match truncated to nothing new — keep looking.
    }
    None
}

// ── invocation cues (spec §F) ───────────────────────────────────────────

/// Flag-only habits for a pathish command, last-seen descending (F1, F2).
/// Alias entries live in a separate map and structurally cannot surface
/// (F3 + contradiction 4). BTreeMap range scan, not a full-map walk (F4).
pub fn invocation_cues(corpus: &Corpus, cmd: &str, prefix: &str, cap: usize) -> Vec<String> {
    let from = format!("{cmd} ");
    let mut scored: Vec<(u64, String)> = Vec::new();
    for (key, stat) in corpus.invoke.range(from.clone()..) {
        if !key.starts_with(&from) {
            break;
        }
        let rest = &key[from.len()..];
        if rest.is_empty() || (!prefix.is_empty() && !rest.starts_with(prefix)) {
            continue;
        }
        scored.push((stat.last, rest.to_string()));
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    let mut seen = HashSet::new();
    scored
        .into_iter()
        .map(|(_, r)| r)
        .filter(|r| seen.insert(r.clone()))
        .take(cap)
        .collect()
}

// ── the flag set seam (spec §H, stubbed) ────────────────────────────────

/// One documented flag: canonical insert spelling, full label, gloss.
#[derive(Debug, Clone)]
pub struct FlagInfo {
    pub insert: String,
    pub label: String,
    pub gloss: String,
    pub suffix: Option<String>,
}

/// Where the documented parameter set comes from. The compsys bridge
/// implements this against the harvest relay; until then [`NoFlags`]
/// keeps the seam honest — None means "no data", which renders as the
/// prototype's "press Tab to load" state, never as an empty set.
pub trait FlagSource {
    fn flags(&self, resolved_path: &str) -> Option<Vec<FlagInfo>>;
}

pub struct NoFlags;

impl FlagSource for NoFlags {
    fn flags(&self, _resolved_path: &str) -> Option<Vec<FlagInfo>> {
        None
    }
}

// ── source selection in argument position (spec §G, history half) ───────

pub struct ArgContext<'a> {
    pub corpus: &'a Corpus,
    pub window: &'a HistoryWindow,
    /// The left-of-cursor buffer, for whole-line matching.
    pub buffer: &'a str,
    /// The current segment's words (command first).
    pub words: Vec<&'a str>,
    /// The partial word being completed ("" right after a space).
    pub prefix: &'a str,
}

/// Tier-1 habits for argument position (G1/G3/G4): pathish → invocation
/// cues; non-pathish → whole history lines; unknown → invocation cues
/// (fail safe); neither answers → the per-token argument map.
pub fn arg_history_candidates(ctx: &ArgContext, cap: usize) -> Vec<Cue> {
    let Some(cmd) = ctx.words.first().copied() else {
        return Vec::new();
    };
    let eff = effective_command(&ctx.words);
    let flags_only = match eff {
        None => true,                                      // C3/C4: unknown fails safe
        Some(_) if !ctx.corpus.has_pathish_data() => true, // G3: no data = unknown
        Some(e) => ctx.corpus.pathish.contains(e),         // the split itself
    };

    let mut items: Vec<String> = if flags_only {
        invocation_cues(ctx.corpus, cmd, ctx.prefix, cap)
    } else {
        history_line_cues(ctx.window, ctx.buffer, ctx.prefix, cap)
    };

    // G4: the per-token argument map still answers when history does not.
    if items.is_empty() {
        if let Some(toks) = ctx.corpus.args.get(cmd) {
            items = toks
                .iter()
                .filter(|t| ctx.prefix.is_empty() || t.starts_with(ctx.prefix))
                .take(cap)
                .cloned()
                .collect();
        }
    }

    items
        .into_iter()
        .map(|item| {
            let gloss = ctx
                .corpus
                .argn
                .get(cmd)
                .and_then(|m| m.get(&item))
                .map(|n| format!("used {n}×"))
                .unwrap_or_default();
            Cue {
                insert: item.clone(),
                label: item,
                gloss,
                kind: Kind::Arg,
                suffix: None,
            }
        })
        .collect()
}

// ── the ghost (spec/card-layout.md GH, one definition) ──────────────────

/// The stem the highlighted cue would add to the line: the remainder past
/// the typed prefix, or the whole cue on an empty prefix.
pub fn cue_stem(pick: &str, prefix: &str) -> Option<String> {
    if prefix.is_empty() {
        return (!pick.is_empty()).then(|| pick.to_string());
    }
    let rest = pick.strip_prefix(prefix)?;
    (!rest.is_empty()).then(|| rest.to_string())
}

/// Ghost precedence — one definition, consumed by both the painter and
/// the legend, because two copies would let the legend lie about `→`:
/// 1. the cue being navigated (engaged only — the operator is choosing it)
/// 2. the newest matching history line
/// 3. the top-ranked cue.
pub fn ghost_stem(
    engaged: bool,
    selected_stem: Option<String>,
    hist_stem: Option<String>,
    top_stem: Option<String>,
) -> Option<String> {
    if engaged {
        if let Some(s) = selected_stem {
            return Some(s);
        }
    }
    hist_stem.or(top_stem)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::corpus::build_from_parts;

    const NOW: u64 = 1_700_100_000;

    fn corpus() -> Corpus {
        build_from_parts(
            "\
: 1700000000:0;git status
: 1700000100:0;ssh aaron@buildbox -p 2222
: 1700000200:0;rm -rf node_modules
: 1700000300:0;rm -f stray.log
: 1700000400:0;git status && rm -rf node_modules
",
            "git (1) - the stupid content tracker\n",
            &["git", "ssh", "rm"].iter().map(|s| s.to_string()).collect(),
        )
    }

    fn env() -> SessionEnv {
        SessionEnv {
            aliases: [("g".to_string(), "git".to_string())].into(),
            functions: ["gpull".to_string(), "_private".to_string()].into(),
            builtins: ["cd".to_string()].into(),
            path_commands: ["git".to_string(), "grep".to_string()].into(),
        }
    }

    #[test]
    fn command_position_precedence_and_exclusions() {
        let cues = command_candidates(&env(), &corpus(), "g", RankMode::Frecency, NOW);
        let names: Vec<&str> = cues.iter().map(|c| c.insert.as_str()).collect();
        assert!(names.contains(&"g") && names.contains(&"gpull") && names.contains(&"grep"));
        assert!(
            !names.contains(&"_private"),
            "underscore functions excluded"
        );
        // git has history; it ranks ahead of the never-run grep.
        let git = names.iter().position(|n| *n == "git").unwrap();
        let grep = names.iter().position(|n| *n == "grep").unwrap();
        assert!(git < grep);
        // alias gloss is its expansion
        let g = cues.iter().find(|c| c.insert == "g").unwrap();
        assert_eq!(g.gloss, "git");
        assert_eq!(g.kind, Kind::Alias);
    }

    #[test]
    fn wrapper_walk_and_fail_safes() {
        assert_eq!(effective_command(&["sudo", "rm", "-rf"]), Some("rm"));
        assert_eq!(effective_command(&["env", "FOO=1", "rm"]), Some("rm"));
        assert_eq!(
            effective_command(&["nice", "-n", "10", "rm"]),
            None,
            "wrapper option arity is unknown (C3)"
        );
        assert_eq!(effective_command(&["sudo"]), None, "bare wrapper (C4)");
        assert_eq!(
            effective_command(&["unknownwrap", "rm"]),
            Some("unknownwrap"),
            "unknown stops the walk (C5)"
        );
    }

    #[test]
    fn pathish_command_offers_flags_never_lines() {
        let c = corpus();
        let w = HistoryWindow::new(100);
        let ctx = ArgContext {
            corpus: &c,
            window: &w,
            buffer: "rm ",
            words: vec!["rm"],
            prefix: "",
        };
        let cues = arg_history_candidates(&ctx, 40);
        assert!(!cues.is_empty());
        assert!(
            cues.iter().all(|c| !c.insert.contains("node_modules")),
            "a remembered path must never be proposed (F1): {cues:?}"
        );
        assert!(cues
            .iter()
            .any(|c| c.insert.contains("-rf") || c.insert.contains("-f")));
    }

    #[test]
    fn non_pathish_command_replays_whole_lines_newest_first() {
        let c = corpus();
        let mut w = HistoryWindow::new(100);
        w.seed(
            ["ssh aaron@buildbox -p 2222", "ssh aaron@oldhost"]
                .iter()
                .copied(),
        );
        let ctx = ArgContext {
            corpus: &c,
            window: &w,
            buffer: "ssh a",
            words: vec!["ssh", "a"],
            prefix: "a",
        };
        let cues = arg_history_candidates(&ctx, 40);
        assert_eq!(cues[0].insert, "aaron@oldhost", "newest first");
        assert!(cues.iter().any(|c| c.insert == "aaron@buildbox -p 2222"));
    }

    #[test]
    fn separator_truncation_protects_the_next_command() {
        let mut w = HistoryWindow::new(100);
        w.seed(["git status && rm -rf node_modules"].iter().copied());
        let cues = history_line_cues(&w, "git s", "s", 40);
        assert_eq!(cues, ["status"], "the rm tail must not ride along (E4)");
        // Quoted separators are arguments, not separators.
        let mut w2 = HistoryWindow::new(100);
        w2.seed(["echo 'a && b' done"].iter().copied());
        let cues = history_line_cues(&w2, "echo ", "", 40);
        assert_eq!(cues, ["'a && b' done"]);
    }

    #[test]
    fn glob_in_buffer_matches_literally() {
        let mut w = HistoryWindow::new(100);
        w.seed(["rg *.rs src", "rg pattern src"].iter().copied());
        // E3: the candidate still begins with the typed prefix.
        let cues = history_line_cues(&w, "rg *", "*", 40);
        assert_eq!(cues, ["*.rs src"], "E6: literal, never a pattern");
    }

    #[test]
    fn window_is_bounded_and_acks() {
        let mut w = HistoryWindow::new(3);
        for i in 1..=5u64 {
            w.push(i, format!("cmd {i}"));
        }
        assert_eq!(w.ack(), 5);
        assert_eq!(w.newest_first().count(), 3);
        assert_eq!(w.newest_first().next().unwrap(), "cmd 5");
    }

    #[test]
    fn ghost_precedence_and_unified_separator_rule() {
        // Engaged selection wins.
        assert_eq!(
            ghost_stem(true, Some("tus".into()), Some("hist".into()), None),
            Some("tus".into())
        );
        // Not engaged: history over top cue.
        assert_eq!(
            ghost_stem(false, Some("tus".into()), Some("hist".into()), None),
            Some("hist".into())
        );
        // The ghost refuses the continuation the card would refuse.
        let mut w = HistoryWindow::new(100);
        w.seed(["git status && rm -rf node_modules"].iter().copied());
        assert_eq!(history_stem(&w, "git s"), Some("tatus".into()));
    }

    #[test]
    fn cue_stem_arithmetic() {
        assert_eq!(cue_stem("status", "sta"), Some("tus".into()));
        assert_eq!(cue_stem("status", ""), Some("status".into()));
        assert_eq!(cue_stem("status", "status"), None);
        assert_eq!(cue_stem("log", "sta"), None);
    }
}
