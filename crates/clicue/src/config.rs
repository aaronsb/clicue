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
    pub max_width: usize,
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
            max_width: 120,
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
            "max-width" => take_usize(&key, &value, &mut cfg.max_width, &mut warnings, &mut took),
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

fn string_array(v: &toml::Value) -> Option<Vec<String>> {
    v.as_array().map(|a| {
        a.iter()
            .filter_map(|x| x.as_str().map(str::to_string))
            .collect()
    })
}

/// Set one top-level string key in the config file, preserving everything
/// else INCLUDING comments — a line edit, not a table round-trip.
pub fn set_key_line(path: &Path, key: &str, value: &str) -> Result<()> {
    let existing = std::fs::read_to_string(path).unwrap_or_default();
    let line = format!("{key} = {value:?}");
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
        // Top-level keys must precede any [table] section or they change
        // meaning; insert before the first section header.
        let first_section = out.iter().position(|l| l.trim_start().starts_with('['));
        match first_section {
            Some(i) => out.insert(i, line),
            None => out.push(line),
        }
    }
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let mut text = out.join("\n");
    if !text.ends_with('\n') {
        text.push('\n');
    }
    std::fs::write(path, text).with_context(|| format!("writing {}", path.display()))
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
        assert_eq!(l.config.max_width, 120, "untouched default");
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
