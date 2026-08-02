//! The corpus: what clicue remembers, and how it stays honest.
//!
//! Contract: spec/corpus.md. Built from shell history and whatis — never
//! instrumented (P1): a space-prefixed line never enters history, so
//! HIST_IGNORE_SPACE stays a free per-command opt-out. One JSON file,
//! inspectable (`clicue data inspect`), atomically written, stamped with
//! its inputs. The daemon is the stamp's single owner (S2).

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

/// Bumped when the layout of [`Corpus`] changes — an added field cannot be
/// noticed by input mtimes (S1).
pub const FORMAT_VERSION: u32 = 1;

/// Cap on ranked argument tokens kept per command (C1).
pub const ARGS_CAP: usize = 40;

/// One whole-invocation habit (K rules): how often, how recently, and how
/// it ranks among everything the operator runs (K7).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct InvocationStat {
    pub count: u64,
    pub last: u64,
    /// Rank percentile among distinct invocations, 1–100 (K7).
    pub pct: u8,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct Corpus {
    /// Input stamp: format version, histfile mtime+size, $PATH dir mtimes
    /// (S1). Compared, never trusted as a feature gate (S3).
    pub stamp: String,
    /// command → one-line gloss from whatis, installed commands only (C2).
    pub gloss: HashMap<String, String>,
    /// command → how many history lines started with it.
    pub freq: HashMap<String, u64>,
    /// command → last-seen epoch (0 = no timestamp recorded).
    pub last: HashMap<String, u64>,
    /// command → ranked argument tokens, count-descending, cap 40 (C1).
    pub args: HashMap<String, Vec<String>>,
    /// command → token → count. Nested maps, not `cmd|token` composite
    /// keys — the prototype's escaping hazard (H10) is unrepresentable.
    pub argn: HashMap<String, HashMap<String, u64>>,
    /// Whole-invocation habits keyed by the SPELLING the operator typed
    /// (K2). BTreeMap so per-command lookup is a range scan, not a walk of
    /// every habit (sources F4).
    pub invoke: BTreeMap<String, InvocationStat>,
    /// Non-winning spelling → the stored key. Kept apart from `invoke` so
    /// alias entries can never surface as proposals (sources.md
    /// contradiction 4 — the prototype buried them by ranking accident).
    pub invoke_alias: HashMap<String, String>,
    /// Commands whose arguments are paths, not reusable cues — one
    /// judgement call, emitted as data, never duplicated (C3).
    pub pathish: HashSet<String>,
}

impl Corpus {
    /// UNKNOWN pathish (empty set) must read as "no data", which callers
    /// fail safe on (sources G3) — distinct from "known non-pathish".
    pub fn has_pathish_data(&self) -> bool {
        !self.pathish.is_empty()
    }
}

// ── the pathish judgement call (C3) ─────────────────────────────────────
// Verbatim from build-corpus.zsh:99–103; changing membership is a
// judgement change, not a refactor.
pub const PATHISH: &[&str] = &[
    "cd", "pushd", "popd", "ls", "ll", "la", "cat", "bat", "less", "more", "head", "tail", "wc",
    "sort", "diff", "vim", "nvim", "nano", "vi", "code", "subl", "emacs", "micro", "cp", "mv",
    "rm", "mkdir", "rmdir", "touch", "chmod", "chown", "chgrp", "ln", "stat", "file", "du", "df",
    "source", ".", "open", "xdg-open", "tar", "zip", "unzip", "gzip", "gunzip", "rsync", "scp",
    "mount", "umount", "dd", "shred", "realpath", "dirname", "basename", "tree",
];

// ── history parsing ─────────────────────────────────────────────────────

/// One history line with its extended-history timestamp (0 when absent).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct HistLine {
    pub ts: u64,
    pub line: String,
}

/// Parse HISTFILE text. Extended format is `: <epoch>:<elapsed>;<line>`;
/// anything else is a plain line with no timestamp. Backslash-continued
/// multi-line entries are read line-by-line, as the prototype's builder
/// did — a continuation line simply fails command validation downstream.
pub fn parse_history(text: &str) -> Vec<HistLine> {
    text.lines()
        .filter(|l| !l.is_empty())
        .map(|l| {
            if let Some(rest) = l.strip_prefix(": ") {
                if let Some((ts_part, cmd)) = rest.split_once(';') {
                    if let Some((epoch, _elapsed)) = ts_part.split_once(':') {
                        if let Ok(ts) = epoch.parse::<u64>() {
                            return HistLine {
                                ts,
                                line: cmd.to_string(),
                            };
                        }
                    }
                }
            }
            HistLine {
                ts: 0,
                line: l.to_string(),
            }
        })
        .collect()
}

/// Split a line into command segments on `||`, `&&`, `|`, `;` (K6) — the
/// same rule the runtime uses to find command position, applied once here.
pub fn split_segments(line: &str) -> Vec<&str> {
    let mut segs = Vec::new();
    let mut start = 0;
    let bytes = line.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'|' | b';' | b'&' => {
                segs.push(&line[start..i]);
                // consume the whole operator run (||, &&, |&)
                while i < bytes.len() && matches!(bytes[i], b'|' | b';' | b'&') {
                    i += 1;
                }
                start = i;
            }
            _ => i += 1,
        }
    }
    segs.push(&line[start..]);
    segs
}

/// The prototype's command-word validation: `^[a-zA-Z0-9_.:+-]+$`.
pub fn valid_command_word(w: &str) -> bool {
    !w.is_empty()
        && w.chars()
            .all(|c| c.is_ascii_alphanumeric() || matches!(c, '_' | '.' | ':' | '+' | '-'))
}

// ── invocation keys (K rules) ───────────────────────────────────────────

/// A flag per K1: long option (value dropped, name kept) or short cluster
/// of letters/digits, whole token ≤ 9 chars. A single-dash token with
/// hyphens is NOT a flag — that shape is a mangled path.
fn flag_name(tok: &str) -> Option<&str> {
    if let Some(body) = tok.strip_prefix("--") {
        let name = body.split('=').next().unwrap_or("");
        let mut chars = name.chars();
        match chars.next() {
            Some(c) if c.is_ascii_alphanumeric() => {}
            _ => return None,
        }
        if chars.all(|c| c.is_ascii_alphanumeric() || c == '-') {
            return Some(&tok[..2 + name.len()]);
        }
        return None;
    }
    if let Some(body) = tok.strip_prefix('-') {
        if tok.len() <= 9 && !body.is_empty() && body.chars().all(|c| c.is_ascii_alphanumeric()) {
            return Some(tok);
        }
    }
    None
}

/// Canonicalise a short cluster by sorting its letters (K2): `-lat` and
/// `-alt` are one habit typed two ways. Anything else returns unchanged.
fn canon_flag(tok: &str) -> String {
    if let Some(body) = tok.strip_prefix('-') {
        if body.len() >= 2 && body.chars().all(|c| c.is_ascii_alphanumeric()) {
            let mut cs: Vec<char> = body.chars().collect();
            cs.sort_unstable();
            return format!("-{}", cs.iter().collect::<String>());
        }
    }
    tok.to_string()
}

fn is_word_token(tok: &str) -> bool {
    let mut chars = tok.chars();
    matches!(chars.next(), Some(c) if c.is_ascii_alphabetic())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
}

/// The (canonical key, typed display) for one segment, or None when the
/// segment contributes no invocation tokens.
fn invocation_key(segment: &str, pathish: &HashSet<String>) -> Option<(String, String)> {
    let words: Vec<&str> = segment.split_whitespace().collect();
    let cmd = *words.first()?;
    if !valid_command_word(cmd) {
        return None;
    }
    let mut key = cmd.to_string();
    let mut disp = cmd.to_string();
    let mut ntokens = 0usize;
    let mut i = 1;
    // Leading subcommand words, non-pathish only, capped at two (K3).
    if !pathish.contains(cmd) {
        while i < words.len() && ntokens < 2 && is_word_token(words[i]) {
            key.push(' ');
            key.push_str(words[i]);
            disp.push(' ');
            disp.push_str(words[i]);
            ntokens += 1;
            i += 1;
        }
    }
    // Flags anywhere in the rest; `--` ends option collection (K4).
    for w in &words[i..] {
        if *w == "--" {
            break;
        }
        if let Some(name) = flag_name(w) {
            key.push(' ');
            key.push_str(&canon_flag(name));
            disp.push(' ');
            disp.push_str(name);
            ntokens += 1;
        }
    }
    if ntokens == 0 {
        return None;
    }
    Some((key, disp))
}

// ── the builder ─────────────────────────────────────────────────────────

/// Pure build from already-fetched inputs, so every rule is testable
/// without a filesystem. IO lives in [`build`].
pub fn build_from_parts(
    history_text: &str,
    whatis_text: &str,
    installed: &HashSet<String>,
) -> Corpus {
    let pathish: HashSet<String> = PATHISH.iter().map(|s| s.to_string()).collect();
    let hist = parse_history(history_text);

    // §2: per-command frequency and last-seen — first word per line.
    let mut freq: HashMap<String, u64> = HashMap::new();
    let mut last: HashMap<String, u64> = HashMap::new();
    for h in &hist {
        if let Some(cmd) = h.line.split_whitespace().next() {
            if valid_command_word(cmd) {
                *freq.entry(cmd.to_string()).or_default() += 1;
                let e = last.entry(cmd.to_string()).or_default();
                if h.ts > *e {
                    *e = h.ts;
                }
            }
        }
    }

    // §3: per-command argument tokens (skip pathish and path-like tokens).
    let mut argn: HashMap<String, HashMap<String, u64>> = HashMap::new();
    for h in &hist {
        for seg in split_segments(&h.line) {
            let words: Vec<&str> = seg.split_whitespace().collect();
            let Some(cmd) = words.first() else { continue };
            if !valid_command_word(cmd) || pathish.contains(*cmd) {
                continue;
            }
            for tok in &words[1..] {
                let flagish = flag_name(tok).is_some();
                if !(flagish || is_word_token(tok)) {
                    continue;
                }
                if tok.contains('/') || tok.starts_with('~') || tok.starts_with('.') {
                    continue;
                }
                *argn
                    .entry(cmd.to_string())
                    .or_default()
                    .entry(tok.to_string())
                    .or_default() += 1;
            }
        }
    }
    let mut args: HashMap<String, Vec<String>> = HashMap::new();
    for (cmd, toks) in &argn {
        let mut ranked: Vec<(&String, &u64)> = toks.iter().collect();
        ranked.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
        args.insert(
            cmd.clone(),
            ranked
                .into_iter()
                .take(ARGS_CAP)
                .map(|(t, _)| t.clone())
                .collect(),
        );
    }

    // §4: whole invocations. Counted under the CANONICAL key; emitted
    // under the SPELLING typed most recently (K2); every other spelling
    // becomes an alias pointing at the winner. No minimum count (K5).
    struct Acc {
        count: u64,
        last: u64,
        winner: String,
        spellings: HashSet<String>,
    }
    let mut acc: HashMap<String, Acc> = HashMap::new();
    for h in &hist {
        for seg in split_segments(&h.line) {
            if let Some((key, disp)) = invocation_key(seg, &pathish) {
                let a = acc.entry(key).or_insert_with(|| Acc {
                    count: 0,
                    last: 0,
                    winner: disp.clone(),
                    spellings: HashSet::new(),
                });
                a.count += 1;
                a.spellings.insert(disp.clone());
                if h.ts >= a.last {
                    a.last = h.ts;
                    a.winner = disp;
                }
            }
        }
    }
    let mut invoke: BTreeMap<String, InvocationStat> = BTreeMap::new();
    let mut invoke_alias: HashMap<String, String> = HashMap::new();
    for a in acc.into_values() {
        for sp in &a.spellings {
            if *sp != a.winner {
                invoke_alias.insert(sp.clone(), a.winner.clone());
            }
        }
        invoke.insert(
            a.winner,
            InvocationStat {
                count: a.count,
                last: a.last,
                pct: 0,
            },
        );
    }
    // Percentile by rank among distinct invocations, count-descending (K7).
    let n = invoke.len() as u64;
    if n > 0 {
        let mut order: Vec<(String, u64)> =
            invoke.iter().map(|(k, s)| (k.clone(), s.count)).collect();
        order.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
        for (rank0, (key, _)) in order.into_iter().enumerate() {
            let rank = rank0 as u64 + 1;
            if let Some(s) = invoke.get_mut(&key) {
                s.pct = (rank * 100).div_ceil(n) as u8;
            }
        }
    }

    // §1: glosses — sections 1/8/1p, installed only, first wins (C2).
    let mut gloss: HashMap<String, String> = HashMap::new();
    for line in whatis_text.lines() {
        let Some(open) = line.find('(') else { continue };
        let Some(close) = line[open..].find(')') else {
            continue;
        };
        let section = &line[open + 1..open + close];
        if !(section.starts_with('1') || section.starts_with('8')) {
            continue;
        }
        let Some(dash) = line[open + close..].find("- ") else {
            continue;
        };
        let desc = line[open + close + dash + 2..].trim();
        if desc.is_empty() {
            continue;
        }
        for name in line[..open].split(',') {
            let name = name.trim();
            if name.is_empty() || gloss.contains_key(name) || !installed.contains(name) {
                continue;
            }
            gloss.insert(name.to_string(), desc.to_string());
        }
    }

    Corpus {
        stamp: String::new(),
        gloss,
        freq,
        last,
        args,
        argn,
        invoke,
        invoke_alias,
        pathish,
    }
}

// ── IO: stamp, scan, build, persist ─────────────────────────────────────

/// Input stamp (S1): format version, histfile mtime+size, `$PATH` dir
/// mtimes. Computed in exactly one place — this function (S2).
pub fn stamp(histfile: &Path, path_dirs: &[PathBuf]) -> String {
    use std::os::unix::fs::MetadataExt;
    let mut s = format!("v{FORMAT_VERSION}");
    if let Ok(meta) = fs::metadata(histfile) {
        s.push_str(&format!(":h{}.{}", meta.mtime(), meta.len()));
    }
    for d in path_dirs {
        if let Ok(meta) = fs::metadata(d) {
            s.push_str(&format!(":{}", meta.mtime()));
        }
    }
    s
}

/// A stale corpus is still served (S3); staleness only schedules a rebuild.
pub fn is_stale(corpus: &Corpus, current_stamp: &str) -> bool {
    corpus.stamp != current_stamp
}

/// Names present in the given directories — the "installed" filter (C2).
pub fn scan_path(path_dirs: &[PathBuf]) -> HashSet<String> {
    let mut names = HashSet::new();
    for d in path_dirs {
        if let Ok(rd) = fs::read_dir(d) {
            for entry in rd.flatten() {
                if let Ok(name) = entry.file_name().into_string() {
                    names.insert(name);
                }
            }
        }
    }
    names
}

pub fn default_histfile() -> Result<PathBuf> {
    if let Some(h) = std::env::var_os("HISTFILE").filter(|v| !v.is_empty()) {
        return Ok(PathBuf::from(h));
    }
    let home = std::env::var_os("HOME").context("HOME is not set")?;
    Ok(PathBuf::from(home).join(".zsh_history"))
}

pub fn path_dirs() -> Vec<PathBuf> {
    std::env::var_os("PATH")
        .map(|p| std::env::split_paths(&p).collect())
        .unwrap_or_default()
}

/// Read HISTFILE with zsh's metafication undone. zsh escapes bytes it
/// considers special with 0x83 and XORs the next byte with 0x20, so the
/// file is routinely NOT valid UTF-8 — `read_to_string` fails on a real
/// history and `unwrap_or_default` silently built an empty corpus from a
/// 74KB file. [MEASURED 2026-08-02]
pub fn read_histfile(path: &Path) -> String {
    let bytes = fs::read(path).unwrap_or_default();
    let mut out = Vec::with_capacity(bytes.len());
    let mut it = bytes.into_iter();
    while let Some(b) = it.next() {
        if b == 0x83 {
            if let Some(n) = it.next() {
                out.push(n ^ 0x20);
            }
        } else {
            out.push(b);
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Full build with IO: read HISTFILE, run whatis, scan PATH, stamp.
pub fn build() -> Result<Corpus> {
    let histfile = default_histfile()?;
    let dirs = path_dirs();
    let history_text = read_histfile(&histfile);
    let installed = scan_path(&dirs);
    let whatis_text = std::process::Command::new("whatis")
        .args(["-w", "*"])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    let mut corpus = build_from_parts(&history_text, &whatis_text, &installed);
    corpus.stamp = stamp(&histfile, &dirs);
    Ok(corpus)
}

/// `$XDG_CACHE_HOME/clicue/corpus.json`, falling back to `~/.cache`.
pub fn cache_path() -> Result<PathBuf> {
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .context("neither XDG_CACHE_HOME nor HOME is set")?;
    Ok(cache.join("clicue").join("corpus.json"))
}

/// Atomic write (S4): tmp + rename, parent created 0700. A reader
/// mid-rebuild sees the old corpus or the new one, never a partial.
pub fn save(corpus: &Corpus, path: &Path) -> Result<()> {
    if let Some(parent) = path.parent() {
        use std::os::unix::fs::DirBuilderExt;
        if !parent.exists() {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
    }
    let tmp = path.with_extension(format!("tmp.{}", std::process::id()));
    fs::write(&tmp, serde_json::to_vec(corpus)?)
        .with_context(|| format!("writing {}", tmp.display()))?;
    fs::rename(&tmp, path).with_context(|| format!("renaming into {}", path.display()))?;
    Ok(())
}

/// Load, versioned: an unreadable or older-format corpus is an error the
/// caller treats as "rebuild", never a crash (L2's replacement).
pub fn load(path: &Path) -> Result<Corpus> {
    let bytes = fs::read(path).with_context(|| format!("reading {}", path.display()))?;
    let corpus: Corpus =
        serde_json::from_slice(&bytes).with_context(|| format!("parsing {}", path.display()))?;
    Ok(corpus)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn installed(names: &[&str]) -> HashSet<String> {
        names.iter().map(|s| s.to_string()).collect()
    }

    const HIST: &str = "\
: 1700000000:0;git status
: 1700000100:0;git status && rm -rf node_modules
: 1700000200:0;ls -lat
: 1700000300:0;ls -alt
: 1700000400:0;grep -- -x file
: 1700000500:0;gh org list --limit 10
plain-format-line -v
: 1700000600:0;tar -home-aaron-Projects-x
";

    #[test]
    fn parses_extended_and_plain_history() {
        let h = parse_history(HIST);
        assert_eq!(h[0].ts, 1700000000);
        assert_eq!(h[0].line, "git status");
        let plain = h.iter().find(|l| l.line.starts_with("plain")).unwrap();
        assert_eq!(plain.ts, 0);
    }

    #[test]
    fn multi_segment_lines_split_before_processing() {
        let segs = split_segments("git status && rm -rf node_modules");
        assert_eq!(segs.len(), 2);
        assert_eq!(segs[1].trim(), "rm -rf node_modules");
        assert_eq!(split_segments("a || b").len(), 2);
        assert_eq!(split_segments("a |& b").len(), 2);
    }

    #[test]
    fn cluster_spellings_are_one_habit_with_alias_map() {
        let c = build_from_parts(HIST, "", &installed(&[]));
        // -lat and -alt canonicalise to one key; winner is the most
        // recently typed spelling (-alt at t=1700000300).
        let stat = c
            .invoke
            .get("ls -alt")
            .expect("winner under typed spelling");
        assert_eq!(stat.count, 2);
        assert!(
            !c.invoke.contains_key("ls -lat"),
            "loser is not a habit key"
        );
        assert_eq!(c.invoke_alias.get("ls -lat").unwrap(), "ls -alt");
    }

    #[test]
    fn double_dash_stops_flag_collection() {
        let c = build_from_parts(HIST, "", &installed(&[]));
        // K4: `grep -- -x file` must not claim -x.
        assert!(!c.invoke.keys().any(|k| k.starts_with("grep")));
    }

    #[test]
    fn mangled_path_is_not_a_flag() {
        let c = build_from_parts(HIST, "", &installed(&[]));
        // K1: `-home-aaron-Projects-x` is not a flag, so tar has no habit.
        assert!(!c.invoke.keys().any(|k| k.starts_with("tar")));
    }

    #[test]
    fn leading_subcommands_join_for_non_pathish_only() {
        let c = build_from_parts(HIST, "", &installed(&[]));
        assert!(c.invoke.contains_key("git status"));
        let gh = c
            .invoke
            .get("gh org list --limit")
            .expect("two words + flag");
        assert_eq!(gh.count, 1);
        // pathish rm: flags only, no subcommand words, no paths.
        assert!(c.invoke.contains_key("rm -rf") || c.invoke.contains_key("rm -fr"));
    }

    #[test]
    fn no_minimum_count_and_percentile_by_rank() {
        let c = build_from_parts(HIST, "", &installed(&[]));
        assert!(c.invoke.values().all(|s| (1..=100).contains(&s.pct)));
        assert!(c.invoke.values().any(|s| s.count == 1));
        // The lowest percentile belongs to a habit with the highest count
        // (ties broken by name, so assert on the count class, not one key).
        let max_count = c.invoke.values().map(|s| s.count).max().unwrap();
        let low = c.invoke.values().map(|s| s.pct).min().unwrap();
        let holder = c.invoke.values().find(|s| s.pct == low).unwrap();
        assert_eq!(holder.count, max_count);
    }

    #[test]
    fn glosses_filter_sections_and_installed() {
        let whatis = "\
git (1)              - the stupid content tracker
gitk (1)             - not installed here
printf (3)           - C library function
sshd (8)             - OpenSSH daemon
";
        let c = build_from_parts("", whatis, &installed(&["git", "printf", "sshd"]));
        assert_eq!(c.gloss.get("git").unwrap(), "the stupid content tracker");
        assert!(!c.gloss.contains_key("gitk"), "not installed");
        assert!(!c.gloss.contains_key("printf"), "section 3 excluded");
        assert!(c.gloss.contains_key("sshd"), "section 8 included");
    }

    #[test]
    fn save_load_round_trip_and_staleness() {
        let dir = std::env::temp_dir().join(format!("clicue-corpus-test-{}", std::process::id()));
        let _ = fs::create_dir_all(&dir);
        // Explicit perms: daemon::bind()'s umask window is process-global,
        // and a dir created inside it loses its search bit under parallel
        // test threads.
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        let p = dir.join("corpus.json");
        let mut c = build_from_parts(HIST, "", &installed(&[]));
        c.stamp = "v1:h1.2:3".into();
        save(&c, &p).unwrap();
        let back = load(&p).unwrap();
        assert_eq!(back.invoke, c.invoke);
        assert!(!is_stale(&back, "v1:h1.2:3"));
        assert!(is_stale(&back, "v1:h9.9:3"));
        let _ = fs::remove_dir_all(&dir);
    }
}
