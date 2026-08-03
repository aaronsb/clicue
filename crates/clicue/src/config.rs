//! Configuration: TOML at `$XDG_CONFIG_HOME/clicue/config.toml`.
//!
//! ADR-100: this replaces the prototype's "all zstyles must precede the
//! source line" footgun. Loading NEVER fails — a broken or partial file
//! yields defaults plus warnings that say so (design value 1: a silently
//! changed behaviour is worse than a named problem). Unknown keys warn,
//! wrong types warn; nothing is guessed.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use anyhow::{Context, Result};

use crate::layout::WidthBound;

/// Key sequences the shim binds (the prototype's `:clicue:keys` zstyles).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeysCfg {
    pub accept: Vec<String>,
    pub dismiss: Vec<String>,
    pub expand: Vec<String>,
    pub maximize: Vec<String>,
}

impl Default for KeysCfg {
    fn default() -> Self {
        KeysCfg {
            accept: vec!["^I".into()],
            dismiss: vec!["^[".into()],
            expand: vec!["^[e".into()],
            maximize: vec!["^[m".into()],
        }
    }
}

/// Everything the operator can set. Defaults match the built-in behaviour
/// exactly, so an absent file and an empty file are the same tool.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Config {
    pub theme: String,
    /// Parsed by rank::RankMode::parse at the consumer; kept as text here
    /// so an unknown value warns at load and falls back there.
    pub ranking: String,
    pub tier1_rows: usize,
    /// Width bounds: absolute columns or a percentage of the terminal
    /// (layout W2/W4); the literal floor MIN_CARD_COLS lives in layout.
    pub min_width: WidthBound,
    pub max_width: WidthBound,
    /// None = auto (`LINES − 6`).
    pub max_lines: Option<usize>,
    /// None = auto (a third of the window).
    pub tier2_rows: Option<usize>,
    pub history_window: usize,
    /// 0 = familiarity collapse disabled (the prototype's default).
    pub familiar_percentile: u8,
    /// command → what it emulates (`ls = "lsd"`): the declared-emulation
    /// map that alias resolution consults first (compsys-bridge A-rules).
    pub emulates: BTreeMap<String, String>,
    pub keys: KeysCfg,
}

impl Default for Config {
    fn default() -> Self {
        Config {
            theme: "aura".into(),
            ranking: "frecency".into(),
            tier1_rows: 10,
            min_width: WidthBound::Pct(30),
            max_width: WidthBound::Cols(120),
            max_lines: None,
            tier2_rows: None,
            history_window: 2000,
            familiar_percentile: 0,
            emulates: BTreeMap::new(),
            keys: KeysCfg::default(),
        }
    }
}

/// A load result: the effective config, what the file actually set (for
/// provenance display), and everything worth telling the operator.
#[derive(Debug, Clone)]
pub struct Loaded {
    pub config: Config,
    /// Top-level keys the file set successfully.
    pub from_file: BTreeSet<String>,
    pub warnings: Vec<String>,
}

pub fn config_path() -> Result<PathBuf> {
    let base = std::env::var_os("XDG_CONFIG_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".config")))
        .context("neither XDG_CONFIG_HOME nor HOME is set")?;
    Ok(base.join("clicue").join("config.toml"))
}

/// Load from the default path. Absent file = defaults, no warnings.
pub fn load() -> Loaded {
    match config_path() {
        Ok(p) => load_path(&p),
        Err(e) => Loaded {
            config: Config::default(),
            from_file: BTreeSet::new(),
            warnings: vec![format!("config location unresolvable: {e}")],
        },
    }
}

pub fn load_path(path: &Path) -> Loaded {
    match std::fs::read_to_string(path) {
        Ok(src) => load_str(&src),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Loaded {
            config: Config::default(),
            from_file: BTreeSet::new(),
            warnings: Vec::new(),
        },
        Err(e) => Loaded {
            config: Config::default(),
            from_file: BTreeSet::new(),
            warnings: vec![format!(
                "{}: unreadable ({e}) — using defaults",
                path.display()
            )],
        },
    }
}

/// The real loader: walk a toml table by hand so every deviation becomes
/// a warning instead of a failure or a silent skip.
pub fn load_str(src: &str) -> Loaded {
    let mut cfg = Config::default();
    let mut from_file = BTreeSet::new();
    let mut warnings = Vec::new();

    let table: toml::Table = match src.parse() {
        Ok(t) => t,
        Err(e) => {
            return Loaded {
                config: cfg,
                from_file,
                warnings: vec![format!("config.toml does not parse ({e}) — using defaults")],
            }
        }
    };

    for (key, value) in table {
        let mut took = true;
        match key.as_str() {
            "theme" => take_string(&key, &value, &mut cfg.theme, &mut warnings, &mut took),
            "ranking" => {
                take_string(&key, &value, &mut cfg.ranking, &mut warnings, &mut took);
                if took && !matches!(cfg.ranking.as_str(), "frequency" | "recency" | "frecency") {
                    warnings.push(format!(
                        "ranking = {:?} is not frequency|recency|frecency — treated as frecency",
                        cfg.ranking
                    ));
                }
            }
            "tier1-rows" => take_usize(&key, &value, &mut cfg.tier1_rows, &mut warnings, &mut took),
            "min-width" => take_width(&key, &value, &mut cfg.min_width, &mut warnings, &mut took),
            "max-width" => take_width(&key, &value, &mut cfg.max_width, &mut warnings, &mut took),
            "max-lines" => {
                let mut v = 0usize;
                take_usize(&key, &value, &mut v, &mut warnings, &mut took);
                if took {
                    cfg.max_lines = Some(v);
                }
            }
            "tier2-rows" => {
                let mut v = 0usize;
                take_usize(&key, &value, &mut v, &mut warnings, &mut took);
                if took {
                    cfg.tier2_rows = Some(v);
                }
            }
            "history-window" => take_usize(
                &key,
                &value,
                &mut cfg.history_window,
                &mut warnings,
                &mut took,
            ),
            "familiar-percentile" => {
                let mut v = 0usize;
                take_usize(&key, &value, &mut v, &mut warnings, &mut took);
                if took {
                    if v > 100 {
                        warnings.push(format!("familiar-percentile = {v} exceeds 100 — clamped"));
                        v = 100;
                    }
                    cfg.familiar_percentile = v as u8;
                }
            }
            "emulates" => match value.as_table() {
                Some(t) => {
                    for (cmd, target) in t {
                        match target.as_str() {
                            Some(s) => {
                                cfg.emulates.insert(cmd.clone(), s.to_string());
                            }
                            None => {
                                warnings.push(format!("emulates.{cmd} must be a string — ignored"))
                            }
                        }
                    }
                }
                None => {
                    warnings.push("emulates must be a table of command = \"target\"".into());
                    took = false;
                }
            },
            "keys" => match value.as_table() {
                Some(t) => {
                    for (action, seqs) in t {
                        let dest = match action.as_str() {
                            "accept" => &mut cfg.keys.accept,
                            "dismiss" => &mut cfg.keys.dismiss,
                            "expand" => &mut cfg.keys.expand,
                            "maximize" => &mut cfg.keys.maximize,
                            other => {
                                warnings.push(format!(
                                    "keys.{other} is not an action (accept|dismiss|expand|maximize) — ignored"
                                ));
                                continue;
                            }
                        };
                        match string_array(seqs) {
                            Some(v) if !v.is_empty() => *dest = v,
                            _ => warnings.push(format!(
                                "keys.{action} must be a non-empty array of strings — keeping default"
                            )),
                        }
                    }
                }
                None => {
                    warnings.push("keys must be a table of action = [sequences]".into());
                    took = false;
                }
            },
            unknown => {
                warnings.push(format!("unknown key {unknown:?} — ignored"));
                took = false;
            }
        }
        if took {
            from_file.insert(key);
        }
    }

    // Statically comparable bounds only — Cols vs Pct depends on the
    // terminal and is resolved (max wins) at render.
    let inverted = match (cfg.min_width, cfg.max_width) {
        (WidthBound::Cols(a), WidthBound::Cols(b)) => a > b,
        (WidthBound::Pct(a), WidthBound::Pct(b)) => a > b,
        _ => false,
    };
    if inverted {
        warnings.push(format!(
            "min-width = {} exceeds max-width = {} — max-width wins at render",
            cfg.min_width, cfg.max_width
        ));
    }

    Loaded {
        config: cfg,
        from_file,
        warnings,
    }
}

fn take_string(
    key: &str,
    v: &toml::Value,
    dest: &mut String,
    warns: &mut Vec<String>,
    took: &mut bool,
) {
    match v.as_str() {
        Some(s) => *dest = s.to_string(),
        None => {
            warns.push(format!("{key} must be a string — keeping default"));
            *took = false;
        }
    }
}

fn take_usize(
    key: &str,
    v: &toml::Value,
    dest: &mut usize,
    warns: &mut Vec<String>,
    took: &mut bool,
) {
    match v.as_integer().filter(|n| *n >= 0) {
        Some(n) => *dest = n as usize,
        None => {
            warns.push(format!(
                "{key} must be a non-negative integer — keeping default"
            ));
            *took = false;
        }
    }
}

/// A width bound: TOML integer = columns, TOML string = `"60%"` of the
/// terminal (or columns spelled as a string).
fn take_width(
    key: &str,
    v: &toml::Value,
    dest: &mut WidthBound,
    warns: &mut Vec<String>,
    took: &mut bool,
) {
    let parsed = match v {
        toml::Value::Integer(n) if *n >= 1 => Some(WidthBound::Cols(*n as usize)),
        toml::Value::String(s) => WidthBound::parse(s),
        _ => None,
    };
    match parsed {
        Some(w) => *dest = w,
        None => {
            warns.push(format!(
                "{key} must be columns (a positive integer) or a percentage like \"60%\" — keeping default"
            ));
            *took = false;
        }
    }
}

fn string_array(v: &toml::Value) -> Option<Vec<String>> {
    v.as_array().map(|a| {
        a.iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect()
    })
}

/// Set one top-level string key in the config file, preserving everything
/// else INCLUDING comments — a line edit, not a table round-trip.
/// Top-level scalar keys `config set` may write. Tables ([keys],
/// [emulates]) are edited in the file — a k=v verb cannot express them.
pub const SCALAR_KEYS: &[&str] = &[
    "theme",
    "ranking",
    "tier1-rows",
    "tier2-rows",
    "min-width",
    "max-width",
    "max-lines",
];

/// Validated scalar write: unknown keys and values the parser would
/// reject are refused BEFORE the file changes — the daemon hot-reloads
/// whatever is on disk, so a bad line must never land there.
pub fn set_scalar(path: &Path, key: &str, value: &str) -> Result<()> {
    if !SCALAR_KEYS.contains(&key) {
        anyhow::bail!(
            "unknown key {key:?} — settable: {}. Tables ([keys], [emulates]) are edited in {}",
            SCALAR_KEYS.join(", "),
            path.display()
        );
    }
    // numbers unquoted, everything else a TOML string
    let rendered = if value.parse::<i64>().is_ok() {
        value.to_string()
    } else {
        format!("{value:?}")
    };
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let candidate = set_key_in(&existing, key, &rendered);
    // Refuse on warnings NEW relative to the current file — key-agnostic,
    // so a pre-existing unrelated warning (or one that happens to contain
    // the key as a substring) neither blocks a valid write nor lets an
    // invalid one through.
    let before: std::collections::HashSet<String> =
        load_str(&existing).warnings.into_iter().collect();
    if let Some(w) = load_str(&candidate)
        .warnings
        .iter()
        .find(|w| !before.contains(*w))
    {
        anyhow::bail!("refusing to write: {w}");
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, candidate).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// The pure edit: replace `key = …` in place or insert before the first
/// [table] section (top-level keys after a header change meaning).
fn set_key_in(existing: &str, key: &str, rendered_value: &str) -> String {
    let line = format!("{key} = {rendered_value}");
    let mut out = Vec::new();
    let mut replaced = false;
    for l in existing.lines() {
        let trimmed = l.trim_start();
        if !replaced
            && trimmed.starts_with(key)
            && trimmed[key.len()..].trim_start().starts_with('=')
        {
            out.push(line.clone());
            replaced = true;
        } else {
            out.push(l.to_string());
        }
    }
    if !replaced {
        let first_section = out.iter().position(|l| l.trim_start().starts_with('['));
        match first_section {
            Some(i) => out.insert(i, line),
            None => out.push(line),
        }
    }
    let mut text = out.join("\n");
    if !text.ends_with('\n') {
        text.push('\n');
    }
    text
}

pub fn set_key_line(path: &Path, key: &str, value: &str) -> Result<()> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let text = set_key_in(&existing, key, &format!("{value:?}"));
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))?;
    Ok(())
}

/// The `clicue config` display: every field, with provenance.
pub fn render_effective(loaded: &Loaded, path_shown: &str) -> String {
    let c = &loaded.config;
    let prov = |k: &str| {
        if loaded.from_file.contains(k) {
            "config.toml"
        } else {
            "default"
        }
    };
    let opt = |v: &Option<usize>| match v {
        Some(n) => n.to_string(),
        None => "auto".to_string(),
    };
    let mut s = format!("config:  {path_shown}\n");
    s += &format!(
        "  theme                {:<12} ({})\n",
        c.theme,
        prov("theme")
    );
    s += &format!(
        "  ranking              {:<12} ({})\n",
        c.ranking,
        prov("ranking")
    );
    s += &format!(
        "  tier1-rows           {:<12} ({})\n",
        c.tier1_rows,
        prov("tier1-rows")
    );
    s += &format!(
        "  min-width            {:<12} ({})\n",
        c.min_width,
        prov("min-width")
    );
    s += &format!(
        "  max-width            {:<12} ({})\n",
        c.max_width,
        prov("max-width")
    );
    s += &format!(
        "  max-lines            {:<12} ({})\n",
        opt(&c.max_lines),
        prov("max-lines")
    );
    s += &format!(
        "  tier2-rows           {:<12} ({})\n",
        opt(&c.tier2_rows),
        prov("tier2-rows")
    );
    s += &format!(
        "  history-window       {:<12} ({})\n",
        c.history_window,
        prov("history-window")
    );
    s += &format!(
        "  familiar-percentile  {:<12} ({})\n",
        c.familiar_percentile,
        prov("familiar-percentile")
    );
    if c.emulates.is_empty() {
        s += &format!(
            "  emulates             {:<12} ({})\n",
            "—",
            prov("emulates")
        );
    } else {
        for (k, v) in &c.emulates {
            s += &format!("  emulates.{k:<12}{v:<12} (config.toml)\n");
        }
    }
    for (action, seqs) in [
        ("accept", &c.keys.accept),
        ("dismiss", &c.keys.dismiss),
        ("expand", &c.keys.expand),
        ("maximize", &c.keys.maximize),
    ] {
        s += &format!(
            "  keys.{action:<15}{:<12} ({})\n",
            seqs.join(" "),
            prov("keys")
        );
    }
    for w in &loaded.warnings {
        s += &format!("  warning: {w}\n");
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn absent_and_empty_are_pure_defaults() {
        let l = load_str("");
        assert_eq!(l.config, Config::default());
        assert!(l.warnings.is_empty());
        assert!(l.from_file.is_empty());
    }

    #[test]
    fn partial_file_sets_only_what_it_names() {
        let l = load_str("theme = \"mono\"\ntier1-rows = 6\n");
        assert_eq!(l.config.theme, "mono");
        assert_eq!(l.config.tier1_rows, 6);
        assert_eq!(
            l.config.max_width,
            WidthBound::Cols(120),
            "untouched default"
        );
        assert!(l.from_file.contains("theme"));
        assert!(!l.from_file.contains("max-width"));
        assert!(l.warnings.is_empty());
    }

    #[test]
    fn unknown_keys_and_wrong_types_warn_and_keep_defaults() {
        let l = load_str("them = \"oops\"\ntier1-rows = \"ten\"\n");
        assert_eq!(l.config, Config::default());
        assert_eq!(l.warnings.len(), 2, "{:?}", l.warnings);
        assert!(l.warnings.iter().any(|w| w.contains("them")));
        assert!(l.warnings.iter().any(|w| w.contains("tier1-rows")));
    }

    #[test]
    fn unparseable_file_is_defaults_plus_one_warning() {
        let l = load_str("theme = [unclosed");
        assert_eq!(l.config, Config::default());
        assert_eq!(l.warnings.len(), 1);
        assert!(l.warnings[0].contains("does not parse"));
    }

    #[test]
    fn keys_and_emulates_tables() {
        let l = load_str(
            "[emulates]\nls = \"lsd\"\nk = 3\n\n[keys]\naccept = [\"^I\", \"^[j\"]\nbogus = [\"x\"]\n",
        );
        assert_eq!(l.config.emulates.get("ls").unwrap(), "lsd");
        assert_eq!(l.config.keys.accept, vec!["^I", "^[j"]);
        assert_eq!(l.config.keys.dismiss, KeysCfg::default().dismiss);
        assert_eq!(l.warnings.len(), 2, "{:?}", l.warnings); // k=3, keys.bogus
    }

    #[test]
    fn ranking_validated_but_kept_as_text() {
        let l = load_str("ranking = \"chaos\"\n");
        assert_eq!(l.config.ranking, "chaos");
        assert!(l.warnings[0].contains("frecency"));
    }

    #[test]
    fn set_scalar_validates_before_writing() {
        let dir = std::env::temp_dir().join(format!("clicue-scalar-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(&p, "theme = \"aura\"\n").unwrap();
        // numbers land unquoted and parse back
        set_scalar(&p, "tier1-rows", "7").unwrap();
        let t = std::fs::read_to_string(&p).unwrap();
        assert!(t.contains("tier1-rows = 7"), "{t}");
        assert_eq!(load_str(&t).config.tier1_rows, 7);
        // a value the parser would warn about never lands
        let before = std::fs::read_to_string(&p).unwrap();
        assert!(set_scalar(&p, "tier1-rows", "banana").is_err());
        assert_eq!(
            std::fs::read_to_string(&p).unwrap(),
            before,
            "file untouched"
        );
        // unknown keys are named, tables are pointed at the file
        let err = set_scalar(&p, "keys", "x").unwrap_err().to_string();
        assert!(err.contains("settable"), "{err}");
        // a PRE-EXISTING warning must not block a valid write — the
        // reviewer's case: a stray key containing the target as substring
        std::fs::write(&p, "tier1-rows-legacy = 5\ntheme = \"aura\"\n").unwrap();
        set_scalar(&p, "tier1-rows", "6").expect("old warnings are not new warnings");
        assert!(std::fs::read_to_string(&p)
            .unwrap()
            .contains("tier1-rows = 6"));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn width_bounds_parse_both_spellings() {
        let l = load_str("min-width = \"45%\"\nmax-width = 96\n");
        assert!(l.warnings.is_empty(), "{:?}", l.warnings);
        assert_eq!(l.config.min_width, WidthBound::Pct(45));
        assert_eq!(l.config.max_width, WidthBound::Cols(96));
        // Out-of-range percentage warns and keeps the default.
        let l = load_str("min-width = \"150%\"\n");
        assert!(l.warnings.iter().any(|w| w.contains("min-width")));
        assert_eq!(l.config.min_width, WidthBound::Pct(30));
    }

    #[test]
    fn set_key_line_preserves_comments_and_replaces_in_place() {
        let dir = std::env::temp_dir().join(format!("clicue-cfg-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let p = dir.join("config.toml");
        std::fs::write(
            &p,
            "# my settings\ntheme = \"aura\"\n\n[keys]\naccept = [\"^I\"]\n",
        )
        .unwrap();
        set_key_line(&p, "theme", "plain").unwrap();
        let out = std::fs::read_to_string(&p).unwrap();
        assert!(out.contains("# my settings"), "comment survives");
        assert!(out.contains("theme = \"plain\""));
        assert!(!out.contains("theme = \"aura\""));
        // new key lands BEFORE the [keys] section
        set_key_line(&p, "ranking", "recency").unwrap();
        let out = std::fs::read_to_string(&p).unwrap();
        let ri = out.find("ranking =").unwrap();
        let ki = out.find("[keys]").unwrap();
        assert!(ri < ki, "top-level key must precede sections:\n{out}");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
