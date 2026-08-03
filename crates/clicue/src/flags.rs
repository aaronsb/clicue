//! Flag intelligence — the daemon half of the compsys bridge.
//!
//! Contract: spec/compsys-bridge.md §§G (grouping/decomposition), H3–H4
//! (attempt-once, stamping), A (alias resolution), Z3 (storage authority
//! is the daemon's). The shim half lives in shim.zsh and ships raw
//! harvest output across the protocol as `Request.pending`.
//!
//! ## Pending payload schema (spec/protocol.md §4)
//!
//! ```json
//! {"harvests":[{
//!    "pos":     "<buffer text the capture ran against>",
//!    "path":    "<typed colon command path, e.g. gh:org>",
//!    "live":    true,
//!    "iprefix": "-",
//!    "words":   ["A","c","x"],
//!    "descs":   ["A  -- append to an archive", "@", ...],
//!    "sfx":     {"A":"", "--file":"="}
//! }]}
//! ```
//!
//! - `live: true` is the capture at the operator's actual buffer —
//!   compsys's membership answer for THIS position. It is never persisted;
//!   the engine holds it per session. `live: false` is a synthesised
//!   ancestor harvest (`cmd ` + `cmd -`) and feeds the store.
//! - `descs[i]` may be `"@"`: the shim's per-word placeholder when a
//!   compadd call came back misaligned (spec B6). Treated as "no
//!   description".
//! - `sfx` carries spec B4's trichotomy JSON-natively: an ABSENT key means
//!   no `-S` (ordinary trailing space); `""` means `-S ''` (append
//!   nothing); any other value is appended literally. This replaces the
//!   prototype's `\0` / `-` / `_` encodings.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::fs;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use anyhow::{Context, Result};
use serde::{Deserialize, Serialize};

use crate::sources::{FlagInfo, FlagSource};

/// Bumped when the on-disk layout changes — a layout change invalidates
/// what an mtime cannot see (spec H4).
pub const FLAG_FORMAT: u32 = 1;

#[derive(Debug, Clone, Deserialize)]
pub struct Pending {
    #[serde(default)]
    pub harvests: Vec<Harvest>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Harvest {
    pub pos: String,
    pub path: String,
    #[serde(default)]
    pub live: bool,
    #[serde(default)]
    pub iprefix: String,
    #[serde(default)]
    pub words: Vec<String>,
    #[serde(default)]
    pub descs: Vec<String>,
    #[serde(default)]
    pub sfx: HashMap<String, String>,
}

pub fn parse_pending(v: &serde_json::Value) -> Option<Pending> {
    serde_json::from_value(v.clone()).ok()
}

/// One documented token (flag or subcommand) of a command path.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct FlagEntry {
    pub desc: String,
    /// The OTHER spellings of this option (spec G1), empty when ungrouped.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub alt: Vec<String>,
    /// None = trailing space; Some("") = append nothing; Some(s) = s.
    /// The three states mean different things at insertion (spec B4).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub suffix: Option<String>,
}

/// Everything known about one resolved command path.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct PathFlags {
    pub stamp: String,
    /// Normalised token → entry. Flags AND subcommands — `gh org list`
    /// needs `org` explained as much as `--limit` (spec H1).
    pub entries: BTreeMap<String, FlagEntry>,
}

// ── display unpacking (spec B8) ─────────────────────────────────────────

/// compdescribe packs `<word><padding>-- <description>`; unpack against
/// the ORIGINAL word (the packing wrapped `A`, not `-A`). `@` is the
/// shim's misalignment placeholder (B6) and means "no description".
pub fn unpack_desc(original_word: &str, display: &str) -> Option<String> {
    if display == "@" || display.is_empty() {
        return None;
    }
    let mut d = display;
    if let Some(rest) = d.strip_prefix(original_word) {
        d = rest.trim_start();
        if let Some(rest) = d.strip_prefix("--") {
            if rest.is_empty() || rest.starts_with(char::is_whitespace) {
                d = rest.trim_start();
            }
        }
    }
    let d = d.trim_end();
    (!d.is_empty() && d != "@").then(|| d.to_string())
}

/// IPREFIX put-back (spec B5): `_tar` consumes the leading dash and
/// completes bare letters; the stored spelling is what the card offers.
fn normalise(word: &str, iprefix: &str) -> String {
    if !word.starts_with('-') && iprefix.starts_with('-') {
        format!("{iprefix}{word}")
    } else {
        word.to_string()
    }
}

/// Build a [`PathFlags`] table from one harvest: unpack, normalise,
/// record suffixes, then pair spellings sharing an identical description
/// — groups of 2 or 3 only; four or more sharing a sentence is a generic
/// description and grouping those would be a guess (spec G1).
pub fn table_from(harvest: &Harvest, stamp: String) -> PathFlags {
    let mut entries: BTreeMap<String, FlagEntry> = BTreeMap::new();
    let mut by_desc: HashMap<String, Vec<String>> = HashMap::new();
    for (i, raw) in harvest.words.iter().enumerate() {
        let Some(desc) = harvest.descs.get(i).and_then(|d| unpack_desc(raw, d)) else {
            continue;
        };
        let word = normalise(raw, &harvest.iprefix);
        // suffix under the raw spelling is how the shim recorded it; the
        // normalised spelling is what insertion uses.
        let suffix = harvest
            .sfx
            .get(raw)
            .or_else(|| harvest.sfx.get(&word))
            .cloned();
        by_desc.entry(desc.clone()).or_default().push(word.clone());
        entries.insert(
            word,
            FlagEntry {
                desc,
                alt: Vec::new(),
                suffix,
            },
        );
    }
    for group in by_desc.values() {
        if !(2..=3).contains(&group.len()) {
            continue;
        }
        for w in group {
            if let Some(e) = entries.get_mut(w) {
                e.alt = group.iter().filter(|x| *x != w).cloned().collect();
                e.alt.sort();
            }
        }
    }
    PathFlags { stamp, entries }
}

// ── spelling rules (spec G2) ────────────────────────────────────────────

fn is_long(s: &str) -> bool {
    s.starts_with("--")
}

/// The INSERTED spelling: shortest short form — it composes into a
/// cluster. All-long groups keep the token itself.
pub fn canonical<'a>(token: &'a str, entry: &'a FlagEntry) -> &'a str {
    std::iter::once(token)
        .chain(entry.alt.iter().map(|s| s.as_str()))
        .filter(|s| !is_long(s))
        .min_by_key(|s| s.chars().count())
        .unwrap_or(token)
}

/// `-l, --long` — short spellings first, then long, comma-joined; the
/// manual-page convention.
pub fn label(token: &str, entry: &FlagEntry) -> String {
    if entry.alt.is_empty() {
        return token.to_string();
    }
    let mut shorts: Vec<&str> = Vec::new();
    let mut longs: Vec<&str> = Vec::new();
    for s in std::iter::once(token).chain(entry.alt.iter().map(|s| s.as_str())) {
        if is_long(s) {
            longs.push(s);
        } else {
            shorts.push(s);
        }
    }
    shorts.sort_unstable();
    longs.sort_unstable();
    shorts.extend(longs);
    shorts.join(", ")
}

/// Decompose a cluster (`-lat`) ONLY when every letter is a documented
/// flag; a partial match means the token is something else (spec G3).
pub fn decompose(table: &PathFlags, token: &str) -> Option<Vec<String>> {
    let letters = token.strip_prefix('-')?;
    if letters.chars().count() < 2 || !letters.chars().all(|c| c.is_ascii_alphanumeric()) {
        return None;
    }
    let mut parts = Vec::new();
    for c in letters.chars() {
        let f = format!("-{c}");
        if !table.entries.contains_key(&f) {
            return None;
        }
        parts.push(f);
    }
    Some(parts)
}

// ── alias resolution (spec A) ───────────────────────────────────────────

/// Declared emulates win (an alias is a deliberate act, and the only
/// answer when it lands on a shell function); otherwise walk the alias
/// map ≤5 hops with a seen-set, first word only, stopping on
/// self-reference (spec A1–A3).
pub fn resolve_cmd(
    head: &str,
    aliases: &HashMap<String, String>,
    emulates: &HashMap<String, String>,
) -> String {
    if let Some(d) = emulates.get(head) {
        return d.split_whitespace().next().unwrap_or(head).to_string();
    }
    let mut c = head.to_string();
    let mut seen: HashSet<String> = HashSet::new();
    for _ in 0..5 {
        let Some(exp) = aliases.get(&c) else { break };
        if !seen.insert(c.clone()) {
            break;
        }
        let Some(first) = exp.split_whitespace().next() else {
            break;
        };
        if first == c {
            break; // alias ls='ls --color' — self-referential
        }
        c = first.to_string();
    }
    c
}

/// Resolve a colon path's HEAD only: `ls` may be an alias, `org` never is.
pub fn resolve_path(
    path: &str,
    aliases: &HashMap<String, String>,
    emulates: &HashMap<String, String>,
) -> String {
    match path.split_once(':') {
        Some((head, rest)) => format!("{}:{rest}", resolve_cmd(head, aliases, emulates)),
        None => resolve_cmd(path, aliases, emulates),
    }
}

// ── the store (spec H3/H4, Z3) ──────────────────────────────────────────

pub struct FlagStore {
    dir: PathBuf,
    path_dirs: Vec<PathBuf>,
    pub emulates: HashMap<String, String>,
    /// Resolved path → table; `None` records "fetched, and there is
    /// nothing" — distinct from "not fetched yet" (spec H3).
    mem: Mutex<HashMap<String, Option<Arc<PathFlags>>>>,
}

impl FlagStore {
    pub fn new(dir: PathBuf, path_dirs: Vec<PathBuf>, emulates: HashMap<String, String>) -> Self {
        FlagStore {
            dir,
            path_dirs,
            emulates,
            mem: Mutex::new(HashMap::new()),
        }
    }

    pub fn default_dir() -> Result<PathBuf> {
        let cache = std::env::var_os("XDG_CACHE_HOME")
            .filter(|d| !d.is_empty())
            .map(PathBuf::from)
            .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
            .context("neither XDG_CACHE_HOME nor HOME is set")?;
        Ok(cache.join("clicue").join("flags"))
    }

    /// The command's own mtime plus format version (spec H4). A rebuilt
    /// binary may document new flags; an unchanged one cannot.
    pub fn stamp(&self, resolved_path: &str) -> String {
        let head = resolved_path.split(':').next().unwrap_or(resolved_path);
        for dir in &self.path_dirs {
            let p = dir.join(head);
            if let Ok(meta) = fs::metadata(&p) {
                use std::os::unix::fs::MetadataExt;
                return format!("v{FLAG_FORMAT}:{}", meta.mtime());
            }
        }
        format!("v{FLAG_FORMAT}:builtin")
    }

    fn file_for(&self, resolved_path: &str) -> PathBuf {
        // ':' is legal in filenames; '/' cannot appear in a valid command
        // word, but sanitise anyway — this is a cache, not a parser.
        self.dir
            .join(resolved_path.replace('/', "%"))
            .with_extension("json")
    }

    /// Ingest a SYNTHESISED harvest for its resolved path: group, stamp,
    /// persist atomically (the corpus write pattern), memoise.
    pub fn ingest(&self, harvest: &Harvest, aliases: &HashMap<String, String>) -> Result<()> {
        debug_assert!(!harvest.live, "live harvests are per-session, not stored");
        let resolved = resolve_path(&harvest.path, aliases, &self.emulates);
        let table = table_from(harvest, self.stamp(&resolved));
        let record = if table.entries.is_empty() {
            None // fetched-and-empty (spec H3)
        } else {
            Some(Arc::new(table))
        };
        if let Some(t) = &record {
            fs::create_dir_all(&self.dir)?;
            let f = self.file_for(&resolved);
            let tmp = f.with_extension("json.tmp");
            fs::write(&tmp, serde_json::to_vec(t.as_ref())?)?;
            fs::rename(&tmp, &f)?;
        }
        self.mem
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .insert(resolved, record);
        Ok(())
    }

    /// The table for a RESOLVED path: memory, then disk (stamp-checked —
    /// a stale table reads as absent, which is what triggers a fresh
    /// harvest), then unknown.
    ///
    /// `Some(None)` = fetched-and-empty; `None` = never fetched.
    pub fn get(&self, resolved_path: &str) -> Option<Option<Arc<PathFlags>>> {
        let mut mem = self.mem.lock().unwrap_or_else(|e| e.into_inner());
        if let Some(hit) = mem.get(resolved_path) {
            return Some(hit.clone());
        }
        let f = self.file_for(resolved_path);
        let table: PathFlags = serde_json::from_slice(&fs::read(f).ok()?).ok()?;
        if table.stamp != self.stamp(resolved_path) {
            return None; // binary moved on — re-harvest
        }
        let table = Arc::new(table);
        mem.insert(resolved_path.to_string(), Some(table.clone()));
        Some(Some(table))
    }

    /// Grouped rows for the card: one row per option group, canonical
    /// insert spelling, full label, description, declared suffix.
    pub fn rows(&self, resolved_path: &str) -> Option<Vec<FlagInfo>> {
        let table = self.get(resolved_path)??;
        let mut out = Vec::new();
        let mut seen: HashSet<String> = HashSet::new();
        for (token, entry) in &table.entries {
            if seen.contains(token) {
                continue;
            }
            let canon = canonical(token, entry).to_string();
            seen.insert(token.clone());
            for a in &entry.alt {
                seen.insert(a.clone());
            }
            let suffix = table
                .entries
                .get(&canon)
                .and_then(|e| e.suffix.clone())
                .or_else(|| entry.suffix.clone());
            out.push(FlagInfo {
                insert: canon,
                label: label(token, entry),
                gloss: entry.desc.clone(),
                suffix,
            });
        }
        Some(out)
    }

    /// Stored subcommand tables under a path (`git` → `git:stash`, …) —
    /// the inspect/forget surface; the engine itself always asks by
    /// exact resolved path.
    pub fn subcommand_tables(&self, resolved_path: &str) -> Vec<String> {
        let prefix = format!("{resolved_path}:");
        let mut out = Vec::new();
        if let Ok(rd) = fs::read_dir(&self.dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let Some(stem) = name.strip_suffix(".json") else {
                    continue;
                };
                let stem = stem.replace('%', "/");
                if stem.starts_with(&prefix) {
                    out.push(stem);
                }
            }
        }
        out.sort();
        out
    }

    /// Remove every stored table for a path and its subcommands.
    /// `clicue data forget` — retroactive removal is the privacy contract,
    /// and harvested flags are collected data like any other.
    pub fn forget(&self, resolved_path: &str) -> usize {
        let prefix = format!("{resolved_path}:");
        self.mem
            .lock()
            .unwrap_or_else(|e| e.into_inner())
            .retain(|k, _| k != resolved_path && !k.starts_with(&prefix));
        let mut removed = 0;
        if let Ok(rd) = fs::read_dir(&self.dir) {
            for e in rd.flatten() {
                let name = e.file_name().to_string_lossy().into_owned();
                let Some(stem) = name.strip_suffix(".json") else {
                    continue;
                };
                let stem = stem.replace('%', "/");
                if (stem == resolved_path || stem.starts_with(&prefix))
                    && fs::remove_file(e.path()).is_ok()
                {
                    removed += 1;
                }
            }
        }
        removed
    }

    /// One typed token explained: `(label, description)` — a documented
    /// token directly, or a cluster decomposed into labelled parts.
    pub fn explain(&self, resolved_path: &str, token: &str) -> Option<(String, String)> {
        let table = self.get(resolved_path)??;
        if let Some(e) = table.entries.get(token) {
            return Some((label(token, e), e.desc.clone()));
        }
        let parts = decompose(&table, token)?;
        let labels: Vec<String> = parts
            .iter()
            .map(|p| {
                table
                    .entries
                    .get(p)
                    .map(|e| label(p, e))
                    .unwrap_or_else(|| p.clone())
            })
            .collect();
        Some((token.to_string(), labels.join(" · ")))
    }
}

impl FlagSource for FlagStore {
    fn flags(&self, resolved_path: &str) -> Option<Vec<FlagInfo>> {
        self.rows(resolved_path)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn harvest(words: &[&str], descs: &[&str], iprefix: &str, sfx: &[(&str, &str)]) -> Harvest {
        Harvest {
            pos: "cmd -".into(),
            path: "cmd".into(),
            live: false,
            iprefix: iprefix.into(),
            words: words.iter().map(|s| s.to_string()).collect(),
            descs: descs.iter().map(|s| s.to_string()).collect(),
            sfx: sfx
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
        }
    }

    #[test]
    fn payload_parses_from_wire_shape() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"harvests":[{"pos":"tar -","path":"tar","live":false,
                "iprefix":"-","words":["A","c"],
                "descs":["A  -- append to an archive","c  -- create"],
                "sfx":{"A":""}}]}"#,
        )
        .unwrap();
        let p = parse_pending(&v).unwrap();
        assert_eq!(p.harvests.len(), 1);
        assert_eq!(p.harvests[0].sfx.get("A").map(|s| s.as_str()), Some(""));
        assert!(!p.harvests[0].sfx.contains_key("c"));
    }

    #[test]
    fn unpacking_honours_original_word_and_placeholder() {
        assert_eq!(
            unpack_desc("A", "A     -- append to an archive"),
            Some("append to an archive".into())
        );
        assert_eq!(unpack_desc("-a", "-a  -- all"), Some("all".into()));
        // description that does not embed the word survives untouched
        assert_eq!(
            unpack_desc("-x", "extract files"),
            Some("extract files".into())
        );
        assert_eq!(unpack_desc("-x", "@"), None);
        assert_eq!(unpack_desc("-x", ""), None);
        // `--` inside prose survives once the word prefix is off
        assert_eq!(
            unpack_desc("-y", "-y  -- yes -- really"),
            Some("yes -- really".into())
        );
    }

    #[test]
    fn iprefix_put_back_stores_the_offered_spelling() {
        let h = harvest(
            &["A", "c"],
            &["A  -- append to an archive", "c  -- create an archive"],
            "-",
            &[("A", "")],
        );
        let t = table_from(&h, "v1:test".into());
        assert!(t.entries.contains_key("-A"), "normalised under -A");
        assert_eq!(t.entries["-A"].suffix.as_deref(), Some(""));
        assert_eq!(t.entries["-c"].suffix, None, "no -S = trailing space");
    }

    #[test]
    fn pairing_groups_two_or_three_and_refuses_generic() {
        let h = harvest(
            &[
                "-f",
                "--force",
                "-r",
                "-R",
                "--recursive",
                "-a",
                "-b",
                "-c",
                "-d",
            ],
            &[
                "-f  -- force",
                "--force  -- force",
                "-r  -- recurse",
                "-R  -- recurse",
                "--recursive  -- recurse",
                "-a  -- display help information",
                "-b  -- display help information",
                "-c  -- display help information",
                "-d  -- display help information",
            ],
            "",
            &[],
        );
        let t = table_from(&h, "s".into());
        assert_eq!(t.entries["-f"].alt, vec!["--force"]);
        assert_eq!(t.entries["-r"].alt.len(), 2, "three spellings, one option");
        assert!(
            t.entries["-a"].alt.is_empty(),
            "4+ sharing a sentence is generic"
        );
    }

    #[test]
    fn canonical_and_label_rules() {
        let e = FlagEntry {
            desc: "recurse".into(),
            alt: vec!["-R".into(), "--recursive".into()],
            suffix: None,
        };
        assert_eq!(canonical("-r", &e), "-r");
        assert_eq!(label("-r", &e), "-R, -r, --recursive");
        let long_only = FlagEntry {
            desc: "x".into(),
            alt: vec![],
            suffix: None,
        };
        assert_eq!(canonical("--only", &long_only), "--only");
        assert_eq!(label("--only", &long_only), "--only");
    }

    #[test]
    fn cluster_decomposition_refuses_partial_matches() {
        let h = harvest(
            &["-l", "-a", "-t"],
            &["-l  -- long", "-a  -- all", "-t  -- time"],
            "",
            &[],
        );
        let t = table_from(&h, "s".into());
        assert_eq!(
            decompose(&t, "-lat"),
            Some(vec!["-l".into(), "-a".into(), "-t".into()])
        );
        assert_eq!(decompose(&t, "-lxz"), None, "x undocumented — refuse");
        assert_eq!(decompose(&t, "-l"), None, "single letter is not a cluster");
        assert_eq!(decompose(&t, "lat"), None);
    }

    #[test]
    fn suffix_trichotomy_survives_the_cache_round_trip() {
        let dir = std::env::temp_dir().join(format!("clicue-flagstore-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let store = FlagStore::new(dir.clone(), vec![], HashMap::new());
        let h = harvest(
            &["-A", "--file", "-c"],
            &["-A  -- append", "--file  -- archive file", "-c  -- create"],
            "",
            &[("-A", ""), ("--file", "=")],
        );
        store.ingest(&h, &HashMap::new()).unwrap();
        // fresh store, same dir: forces the disk path
        let store2 = FlagStore::new(dir.clone(), vec![], HashMap::new());
        let t = store2.get("cmd").unwrap().unwrap();
        assert_eq!(t.entries["-A"].suffix.as_deref(), Some(""), "-S ''");
        assert_eq!(t.entries["--file"].suffix.as_deref(), Some("="), "-S =");
        assert_eq!(t.entries["-c"].suffix, None, "no -S");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn stale_stamp_reads_as_absent() {
        let dir = std::env::temp_dir().join(format!("clicue-flagstale-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let store = FlagStore::new(dir.clone(), vec![], HashMap::new());
        let h = harvest(&["-x"], &["-x  -- extract"], "", &[]);
        store.ingest(&h, &HashMap::new()).unwrap();
        // Sabotage the stamp on disk: a rebuilt binary.
        let f = dir.join("cmd.json");
        let mut t: PathFlags = serde_json::from_slice(&fs::read(&f).unwrap()).unwrap();
        t.stamp = "v1:9999999".into();
        fs::write(&f, serde_json::to_vec(&t).unwrap()).unwrap();
        let store2 = FlagStore::new(dir.clone(), vec![], HashMap::new());
        assert!(
            store2.get("cmd").is_none(),
            "stale table triggers re-harvest"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn fetched_and_empty_is_distinct_from_unknown() {
        let dir = std::env::temp_dir().join(format!("clicue-flagempty-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let store = FlagStore::new(dir.clone(), vec![], HashMap::new());
        assert!(store.get("nothing").is_none(), "never fetched");
        let h = harvest(&[], &[], "", &[]);
        store.ingest(&h, &HashMap::new()).unwrap();
        assert_eq!(
            store.get("cmd"),
            Some(None),
            "fetched, and there is nothing"
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn alias_resolution_rules() {
        let mut aliases = HashMap::new();
        aliases.insert("g".to_string(), "git".to_string());
        aliases.insert("ls".to_string(), "ls --color".to_string());
        aliases.insert("a".to_string(), "b".to_string());
        aliases.insert("b".to_string(), "a".to_string());
        aliases.insert("ll".to_string(), "ls -lah".to_string());
        let none = HashMap::new();
        assert_eq!(resolve_cmd("g", &aliases, &none), "git");
        assert_eq!(
            resolve_cmd("ls", &aliases, &none),
            "ls",
            "self-referential stops"
        );
        assert_eq!(
            resolve_cmd("ll", &aliases, &none),
            "ls",
            "first word, then self-ref stops"
        );
        // mutual recursion terminates via the seen-set
        let r = resolve_cmd("a", &aliases, &none);
        assert!(r == "a" || r == "b");
        // declared emulates wins, first word only
        let mut emu = HashMap::new();
        emu.insert("ls".to_string(), "lsd --long".to_string());
        assert_eq!(resolve_cmd("ls", &aliases, &emu), "lsd");
        // resolution applies to the head of a path only
        assert_eq!(resolve_path("g:org", &aliases, &none), "git:org");
    }

    #[test]
    fn rows_group_and_carry_canonical_suffix() {
        let dir = std::env::temp_dir().join(format!("clicue-flagrows-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let store = FlagStore::new(dir.clone(), vec![], HashMap::new());
        let h = harvest(
            &["-f", "--force", "-x"],
            &["-f  -- force", "--force  -- force", "-x  -- extract"],
            "",
            &[],
        );
        store.ingest(&h, &HashMap::new()).unwrap();
        let rows = store.rows("cmd").unwrap();
        assert_eq!(rows.len(), 2, "one row per option group");
        let f = rows.iter().find(|r| r.insert == "-f").unwrap();
        assert_eq!(f.label, "-f, --force");
        assert_eq!(f.gloss, "force");
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn explain_documents_tokens_and_clusters() {
        let dir = std::env::temp_dir().join(format!("clicue-flagexp-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let store = FlagStore::new(dir.clone(), vec![], HashMap::new());
        let h = harvest(
            &["-l", "-a", "--all", "-t", "list"],
            &[
                "-l  -- long listing",
                "-a  -- all entries",
                "--all  -- all entries",
                "-t  -- sort by time",
                "list  -- list things",
            ],
            "",
            &[],
        );
        store.ingest(&h, &HashMap::new()).unwrap();
        let (lbl, desc) = store.explain("cmd", "-a").unwrap();
        assert_eq!(lbl, "-a, --all");
        assert_eq!(desc, "all entries");
        let (lbl, desc) = store.explain("cmd", "list").unwrap();
        assert_eq!(lbl, "list");
        assert_eq!(desc, "list things");
        let (_, desc) = store.explain("cmd", "-lat").unwrap();
        assert!(desc.contains("·"), "cluster explains as its parts: {desc}");
        assert!(store.explain("cmd", "-z").is_none());
        let _ = fs::remove_dir_all(&dir);
    }
}
