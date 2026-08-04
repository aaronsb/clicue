use anyhow::Result;
use clap::{Parser, Subcommand};

/// Live, contextual command guidance for zsh.
///
/// One binary: the daemon that answers the shim per keystroke, and the tool
/// surface that installs, checks, and configures it. Boundaries per ADR-100.
#[derive(Parser)]
#[command(name = "clicue", version, about, long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Emit the zsh shim for `eval "$(clicue init zsh)"`
    Init {
        /// Target shell (only zsh is supported)
        shell: String,
    },
    /// Check the live zsh environment, then wire clicue into it
    Install {
        /// Skip the confirmation prompt
        #[arg(long)]
        yes: bool,
        /// Proceed even if the doctor found fighters
        #[arg(long)]
        force: bool,
    },
    /// Remove clicue from the zsh config
    Uninstall {
        /// Skip the confirmation prompt
        #[arg(long)]
        yes: bool,
    },
    /// Probe a live zsh for conflicts and silent degradations
    Doctor,
    /// Show the effective configuration, or set one value
    Config {
        #[command(subcommand)]
        cmd: Option<ConfigCmd>,
    },
    /// List, set, or preview themes
    Theme {
        #[command(subcommand)]
        cmd: Option<ThemeCmd>,
    },
    /// Inspect and manage collected data (corpus, habits)
    Data {
        #[command(subcommand)]
        cmd: Option<DataCmd>,
    },
    /// Run the daemon (normally auto-spawned by the shim)
    Daemon,
}

#[derive(Subcommand)]
enum ThemeCmd {
    /// List available themes (built-in and installed TOML)
    List {
        /// Structured output (ADR-400)
        #[arg(long)]
        json: bool,
    },
    /// Set the theme in config.toml
    Set { name: String },
    /// Render a sample card with a theme
    Preview { name: String },
    /// `clicue theme <name>` — the obvious spelling sets the theme
    #[command(external_subcommand)]
    Bare(Vec<String>),
}

#[derive(Subcommand)]
enum ConfigCmd {
    /// Set a top-level value (theme, ranking, tier1-rows, …) — validated,
    /// applied live by the daemon within a second
    Set { key: String, value: String },
}

#[derive(Subcommand)]
enum DataCmd {
    /// Corpus location, size, and staleness
    Status {
        /// Structured output (ADR-400)
        #[arg(long)]
        json: bool,
    },
    /// Rebuild the corpus from history and whatis
    Rebuild,
    /// Everything clicue knows about one command
    Inspect {
        cmd: String,
        /// Structured output (ADR-400)
        #[arg(long)]
        json: bool,
    },
    /// Remove one command's habits from the corpus (targeted deletion)
    Forget { cmd: String },
    /// Usage statistics: run counts, top commands, harvest coverage
    Stats {
        /// Structured output (ADR-400)
        #[arg(long)]
        json: bool,
    },
}

fn theme_cmd(cmd: Option<ThemeCmd>) -> Result<()> {
    use clicue::theme;
    let dir = clicue::config::themes_dir();
    match cmd.unwrap_or(ThemeCmd::List { json: false }) {
        ThemeCmd::List { json } => {
            let loaded = clicue::config::load();
            if json {
                let themes: Vec<_> = theme::available(dir.as_deref())
                    .into_iter()
                    .map(|name| {
                        let (_, msgs) = theme::load(&name, dir.as_deref());
                        serde_json::json!({ "name": name, "broken": !msgs.is_empty() })
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::json!({ "current": loaded.config.theme, "themes": themes })
                );
                return Ok(());
            }
            let out = clicue::cliout::Out::auto();
            println!(
                "{} {} {}",
                out.hint("theme:"),
                out.accent(&loaded.config.theme),
                out.gloss("(current)")
            );
            for name in theme::available(dir.as_deref()) {
                let (t, msgs) = theme::load(&name, dir.as_deref());
                if msgs.is_empty() {
                    println!("{}", theme::swatch(&t));
                } else {
                    // The swatch shows the FALLBACK — say so, or the list
                    // hides exactly the breakage doctor reports.
                    println!(
                        "{}  {}",
                        theme::swatch(&t),
                        out.matched("← file broken; fallback shown")
                    );
                }
            }
            println!("\n{}      clicue theme <name>", out.hint("set:"));
            println!("{}  clicue theme preview <name>", out.hint("preview:"));
            Ok(())
        }
        ThemeCmd::Set { name } => {
            let names = theme::available(dir.as_deref());
            if !names.contains(&name) {
                anyhow::bail!("no theme named {name:?} — available: {}", names.join("  "));
            }
            let (t, msgs) = theme::load_or_seed(&name, dir.as_deref());
            for m in &msgs {
                eprintln!("warning: {m}");
            }
            if t.name != name {
                anyhow::bail!("theme {name:?} failed validation — not set");
            }
            let path = clicue::config::config_path()?;
            clicue::config::set_key_line(&path, "theme", &name)?;
            if msgs.is_empty() {
                println!(
                    "theme is now {name} ({}) — applied live; the daemon reloads within a second",
                    path.display()
                );
            } else {
                // A broken file for a shipped name resolves to the shipped
                // theme, so the guard above passes — but claiming plain
                // success would hide what the warnings just said.
                println!(
                    "theme is now {name} — but its file is broken (warnings above): cards render \
                     the shipped fallback until it loads cleanly. `clicue doctor` tracks it."
                );
            }
            Ok(())
        }
        ThemeCmd::Bare(words) => {
            let known = theme::available(dir.as_deref());
            match words.as_slice() {
                [one] if known.contains(one) => {
                    theme_cmd(Some(ThemeCmd::Set { name: one.clone() }))
                }
                [one] => anyhow::bail!("no theme named {one:?} — available: {}", known.join("  ")),
                _ => anyhow::bail!(
                    "usage: clicue theme [<name> | list | set <name> | preview <name>]"
                ),
            }
        }
        ThemeCmd::Preview { name } => {
            let (t, msgs) = theme::load_or_seed(&name, dir.as_deref());
            for m in &msgs {
                eprintln!("warning: {m}");
            }
            let cols = std::env::var("COLUMNS")
                .ok()
                .and_then(|c| c.parse().ok())
                .unwrap_or(80);
            print!("{}", theme::preview(&t, cols));
            Ok(())
        }
    }
}

/// The CLI's view of the harvested-flag store: same construction as the
/// engine's, minus live aliases (only a shell session knows those).
fn flag_store() -> Result<clicue::flags::FlagStore> {
    use clicue::flags::FlagStore;
    Ok(FlagStore::new(
        FlagStore::default_dir()?,
        clicue::corpus::path_dirs(),
        clicue::config::load().config.emulates.into_iter().collect(),
    ))
}

fn data(cmd: Option<DataCmd>) -> Result<()> {
    use clicue::corpus;
    let cache = corpus::cache_path()?;
    match cmd.unwrap_or(DataCmd::Status { json: false }) {
        DataCmd::Status { json } => {
            match corpus::load(&cache) {
                Ok(c) => {
                    let current = corpus::stamp(&corpus::default_histfile()?, &corpus::path_dirs());
                    if json {
                        let state = match corpus::staleness(&c, &current) {
                            corpus::Staleness::Current => "current",
                            corpus::Staleness::TrailingHistory => "trailing-history",
                            corpus::Staleness::Structural => "stale",
                        };
                        println!(
                            "{}",
                            serde_json::json!({
                                "corpus": cache.display().to_string(),
                                "glosses": c.gloss.len(),
                                "invocations": c.invoke.len(),
                                "state": state,
                            })
                        );
                        return Ok(());
                    }
                    let out = clicue::cliout::Out::auto();
                    println!("{}  {}", out.hint("corpus:"), out.accent(&cache.display().to_string()));
                    println!("  {}      {}", out.hint("glosses"), c.gloss.len());
                    println!("  {}  {}", out.hint("invocations"), c.invoke.len());
                    // A live shell appends every command to history as it
                    // runs — `clicue data` itself moved the file before this
                    // check. Trailing history is the working state of derived
                    // data, not something to alarm about (S6).
                    let state = match corpus::staleness(&c, &current) {
                        corpus::Staleness::Current => "current".to_string(),
                        corpus::Staleness::TrailingHistory => {
                            "current (trailing live history — folds in at the next daemon start, or now via `clicue data rebuild`)".to_string()
                        }
                        corpus::Staleness::Structural => {
                            out.matched("STALE — corpus format or installed commands changed; run `clicue data rebuild`")
                        }
                    };
                    println!("  {}        {state}", out.hint("state"));
                }
                Err(_) if json => println!(
                    "{}",
                    serde_json::json!({
                        "corpus": cache.display().to_string(),
                        "state": "absent",
                    })
                ),
                Err(_) => println!(
                    "corpus:  {} — absent; run `clicue data rebuild`",
                    cache.display()
                ),
            }
            Ok(())
        }
        DataCmd::Rebuild => {
            let c = corpus::build()?;
            corpus::save(&c, &cache)?;
            println!(
                "corpus built: {} ({} glosses, {} invocations) — applied live; \
                 the daemon reloads within a second",
                cache.display(),
                c.gloss.len(),
                c.invoke.len()
            );
            Ok(())
        }
        DataCmd::Inspect { cmd, json } => {
            let c = match corpus::load(&cache) {
                Ok(c) => c,
                Err(_) if json => {
                    println!(
                        "{}",
                        serde_json::json!({
                            "cmd": cmd,
                            "corpus": { "path": cache.display().to_string() },
                            "state": "absent",
                        })
                    );
                    return Ok(());
                }
                Err(e) => return Err(e),
            };
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            if json {
                let prefix = format!("{cmd} ");
                let invocations: Vec<_> = c
                    .invoke
                    .iter()
                    .filter(|(k, _)| **k == cmd || k.starts_with(&prefix))
                    .map(|(k, st)| {
                        // `pct` is the K7 rank percentile (lower = nearer the
                        // top), not a share — stats calls its share `share_pct`
                        serde_json::json!({ "invocation": k, "count": st.count, "pct": st.pct })
                    })
                    .collect();
                let store = flag_store()?;
                let resolved =
                    clicue::flags::resolve_path(&cmd, &Default::default(), &store.emulates);
                let flags: Vec<_> = store
                    .rows(&resolved)
                    .unwrap_or_default()
                    .into_iter()
                    .map(|r| {
                        serde_json::json!({ "insert": r.insert, "label": r.label, "gloss": r.gloss })
                    })
                    .collect();
                println!(
                    "{}",
                    serde_json::json!({
                        "cmd": cmd,
                        "gloss": c.gloss.get(&cmd),
                        "runs": c.freq.get(&cmd).copied().unwrap_or(0),
                        "last_days": c.last.get(&cmd).filter(|l| **l > 0)
                            .map(|l| now.saturating_sub(*l) / 86400),
                        "args": c.args.get(&cmd),
                        "invocations": invocations,
                        "flags": flags,
                        "subcommand_tables": store.subcommand_tables(&resolved),
                    })
                );
                return Ok(());
            }
            let out = clicue::cliout::Out::auto();
            println!("{}:", out.accent(&cmd));
            match c.gloss.get(&cmd) {
                Some(g) => println!("  {}     {}", out.hint("gloss"), out.gloss(g)),
                None => println!("  {}     (none)", out.hint("gloss")),
            }
            let count = c.freq.get(&cmd).copied().unwrap_or(0);
            println!("  {}      {count}", out.hint("runs"));
            if let Some(last) = c.last.get(&cmd).filter(|l| **l > 0) {
                println!("  {}      {}d ago", out.hint("last"), now.saturating_sub(*last) / 86400);
            }
            if let Some(toks) = c.args.get(&cmd) {
                println!("  {}      {}", out.hint("args"), toks.join(" "));
            }
            let prefix = format!("{cmd} ");
            let mut invocations: Vec<_> = c
                .invoke
                .iter()
                .filter(|(k, _)| **k == cmd || k.starts_with(&prefix))
                .collect();
            invocations.sort_by(|a, b| b.1.count.cmp(&a.1.count));
            if !invocations.is_empty() {
                println!("  {}:", out.hint("invocations"));
                for (k, s) in invocations.iter().take(10) {
                    println!("    {:<40} {}×  top {}%", k, s.count, s.pct);
                }
                if invocations.len() > 10 {
                    println!("    … {} total", invocations.len());
                }
            }
            // Harvested flags live in their own store, not the corpus —
            // inspect covers ALL collected data or it misleads.
            let store = flag_store()?;
            let resolved = clicue::flags::resolve_path(&cmd, &Default::default(), &store.emulates);
            if let Some(mut rows) = store.rows(&resolved) {
                rows.sort_by(|a, b| a.insert.cmp(&b.insert));
                println!("  {}     {} harvested", out.hint("flags"), rows.len());
                for r in rows.iter().take(8) {
                    println!("    {:<24} {}", r.label, out.gloss(&r.gloss));
                }
                if rows.len() > 8 {
                    println!("    … `clicue data inspect` shows 8; the card shows all");
                }
            }
            for sub in store.subcommand_tables(&resolved) {
                println!("  {}     {sub} (subcommand table)", out.hint("flags"));
            }
            Ok(())
        }
        DataCmd::Forget { cmd } => {
            let mut c = corpus::load(&cache)?;
            let prefix = format!("{cmd} ");
            let hit = |k: &str| k == cmd || k.starts_with(&prefix);
            let mut removed = 0usize;
            removed += c.freq.remove(&cmd).map(|_| 1).unwrap_or(0);
            removed += c.last.remove(&cmd).map(|_| 1).unwrap_or(0);
            removed += c.args.remove(&cmd).map(|_| 1).unwrap_or(0);
            removed += c.argn.remove(&cmd).map(|_| 1).unwrap_or(0);
            let before = c.invoke.len();
            c.invoke.retain(|k, _| !hit(k));
            removed += before - c.invoke.len();
            let before = c.invoke_alias.len();
            c.invoke_alias.retain(|k, v| !hit(k) && !hit(v));
            removed += before - c.invoke_alias.len();
            // The gloss stays: it is whatis-derived public data, not a habit.
            // Flag tables go FIRST: the corpus save is what the daemon's
            // reloader watches, so by the time the swap fires the tables
            // are already gone.
            let store = flag_store()?;
            let resolved = clicue::flags::resolve_path(&cmd, &Default::default(), &store.emulates);
            let flags_removed = store.forget(&resolved);
            corpus::save(&c, &cache)?;
            println!(
                "forgot {removed} entr{} and {flags_removed} flag table{} for {cmd}. \
                 Note: the next rebuild re-learns from history — prefix the command \
                 with a space (HIST_IGNORE_SPACE) to keep it out for good.",
                if removed == 1 { "y" } else { "ies" },
                if flags_removed == 1 { "" } else { "s" }
            );
            // The daemon watches the corpus cache: the swap builds a fresh
            // flag store too, so the memoised tables go with it.
            println!("applied live; the daemon reloads within a second");
            Ok(())
        }
        DataCmd::Stats { json } => {
            let c = match corpus::load(&cache) {
                Ok(c) => c,
                Err(_) if json => {
                    // Same nesting as the populated shape: `.corpus.path`
                    // must resolve in both (review #33 finding 1).
                    println!(
                        "{}",
                        serde_json::json!({
                            "corpus": { "path": cache.display().to_string() },
                            "state": "absent",
                        })
                    );
                    return Ok(());
                }
                Err(_) => {
                    println!(
                        "corpus:  {} — absent; run `clicue data rebuild`",
                        cache.display()
                    );
                    return Ok(());
                }
            };
            let total_runs: u64 = c.freq.values().sum();
            let mut top: Vec<_> = c.freq.iter().collect();
            top.sort_by(|a, b| b.1.cmp(a.1).then(a.0.cmp(b.0)));
            let mut inv: Vec<_> = c.invoke.iter().collect();
            inv.sort_by(|a, b| b.1.count.cmp(&a.1.count).then(a.0.cmp(b.0)));
            // Full command lines only: a bare head duplicates the top table.
            inv.retain(|(k, _)| k.contains(' '));
            // Recency buckets from last-used stamps.
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs())
                .unwrap_or(0);
            let (mut day, mut week, mut older) = (0usize, 0usize, 0usize);
            for last in c.last.values().filter(|l| **l > 0) {
                match now.saturating_sub(*last) {
                    0..=86_399 => day += 1,
                    86_400..=604_799 => week += 1,
                    _ => older += 1,
                }
            }
            let store = flag_store()?;
            let mut stored = store.stored();
            stored.sort_by(|a, b| b.1.cmp(&a.1).then(a.0.cmp(&b.0)));
            let flags_total: usize = stored.iter().map(|(_, n)| n).sum();

            if json {
                let current = corpus::stamp(&corpus::default_histfile()?, &corpus::path_dirs());
                let state = match corpus::staleness(&c, &current) {
                    corpus::Staleness::Current => "current",
                    corpus::Staleness::TrailingHistory => "trailing-history",
                    corpus::Staleness::Structural => "stale",
                };
                println!(
                    "{}",
                    serde_json::json!({
                        "state": state,
                        "corpus": {
                            "path": cache.display().to_string(),
                            "distinct_commands": c.freq.len(),
                            "total_runs": total_runs,
                            "glosses": c.gloss.len(),
                        },
                        "top_commands": top.iter().take(10).map(|(cmd, runs)| {
                            serde_json::json!({
                                "cmd": cmd,
                                "runs": runs,
                                // share of all runs — NOT inspect's `pct`,
                                // which is the K7 rank percentile
                                "share_pct": (**runs * 100) / total_runs.max(1),
                            })
                        }).collect::<Vec<_>>(),
                        "top_invocations": inv.iter().take(10).map(|(k, st)| {
                            serde_json::json!({ "invocation": k, "count": st.count })
                        }).collect::<Vec<_>>(),
                        "recency": { "today": day, "this_week": week, "older": older },
                        "flags": {
                            "tables": stored.len(),
                            "flags_stored": flags_total,
                            "largest": stored.iter().take(5).map(|(p, n)| {
                                serde_json::json!({ "path": p, "entries": n })
                            }).collect::<Vec<_>>(),
                        },
                    })
                );
                return Ok(());
            }

            let out = clicue::cliout::Out::auto();
            println!("{}  {}", out.hint("corpus:"), out.accent(&cache.display().to_string()));
            println!("  {}  {}", out.hint("distinct commands"), c.freq.len());
            println!("  {}         {total_runs}", out.hint("total runs"));
            println!("  {}            {}", out.hint("glosses"), c.gloss.len());

            let max = top.first().map(|(_, n)| **n).unwrap_or(0).max(1);
            if !top.is_empty() {
                println!("\n{}", out.hint("top commands:"));
                for (cmd, runs) in top.iter().take(10) {
                    // Bar scaled to the leader; ▪ is the card's own mark.
                    let w = ((**runs * 24) / max).max(1) as usize;
                    let pct = (**runs * 100) / total_runs.max(1);
                    // Pad BEFORE painting: format widths count ANSI bytes.
                    println!(
                        "  {} {:>6}  {} {:>2}%",
                        out.accent(&format!("{cmd:<14}")),
                        runs,
                        out.gloss(&format!("{:<24}", "▪".repeat(w))),
                        pct
                    );
                }
            }

            if !inv.is_empty() {
                println!("\n{}", out.hint("top invocations:"));
                for (k, st) in inv.iter().take(10) {
                    println!("  {} {:>5}×", out.accent(&format!("{k:<40}")), st.count);
                }
            }

            if day + week + older > 0 {
                println!("\n{}", out.hint("recency (distinct commands):"));
                println!("  {}              {day}", out.hint("today"));
                println!("  {}          {week}", out.hint("this week"));
                println!("  {}              {older}", out.hint("older"));
            }

            println!("\n{}", out.hint("flags (Tab-harvested):"));
            println!("  {}             {}", out.hint("tables"), stored.len());
            println!("  {}       {flags_total}", out.hint("flags stored"));
            if !stored.is_empty() {
                let biggest: Vec<String> = stored
                    .iter()
                    .take(5)
                    .map(|(p, n)| format!("{} ({n})", out.accent(p)))
                    .collect();
                println!("  {}            {}", out.hint("largest"), biggest.join(", "));
            }
            Ok(())
        }
    }
}

fn main() -> Result<()> {
    // Die quietly on a closed pipe (`clicue data inspect x | head`), like
    // every other Unix CLI — Rust's default turns SIGPIPE into a panic.
    unsafe {
        libc::signal(libc::SIGPIPE, libc::SIG_DFL);
    }
    let cli = Cli::parse();
    match cli.command {
        Command::Init { shell } => {
            if shell != "zsh" {
                anyhow::bail!("only zsh is supported (got {shell})");
            }
            print!("{}", clicue::shim::emit_zsh());
            // clicue supports itself through the same universal path as
            // every other command: a compsys completer the Tab-harvest
            // reads. clap generates it from the real CLI definition, so
            // the card can never drift from the binary. compdef exists
            // only after compinit; without it, skip silently — the doctor
            // already reports the missing compsys as a degradation.
            let mut comp = Vec::new();
            clap_complete::generate(
                clap_complete::shells::Zsh,
                &mut <Cli as clap::CommandFactory>::command(),
                "clicue",
                &mut comp,
            );
            println!(
                "if (( ${{+functions[compdef]}} )); then\n{}\nfi",
                String::from_utf8_lossy(&comp)
            );
            Ok(())
        }
        Command::Install { yes, force } => {
            let code = clicue::install::install(&clicue::install::InstallOpts { yes, force })?;
            std::process::exit(code);
        }
        Command::Uninstall { yes } => {
            let code = clicue::install::uninstall(yes)?;
            std::process::exit(code);
        }
        Command::Doctor => {
            let code = clicue::doctor::run()?;
            std::process::exit(code);
        }
        Command::Config {
            cmd: Some(ConfigCmd::Set { key, value }),
        } => {
            // theme names get the same validation the theme verb applies
            if key == "theme" {
                return theme_cmd(Some(ThemeCmd::Set { name: value }));
            }
            let path = clicue::config::config_path()?;
            clicue::config::set_scalar(&path, &key, &value)?;
            println!(
                "{key} = {value} ({}) — applied live; the daemon reloads within a second",
                path.display()
            );
            Ok(())
        }
        Command::Config { cmd: None } => {
            let loaded = clicue::config::load();
            let shown = clicue::config::config_path()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|_| "(unresolvable)".into());
            print!("{}", clicue::config::render_effective(&loaded, &shown));
            Ok(())
        }
        Command::Theme { cmd } => theme_cmd(cmd),
        Command::Data { cmd } => data(cmd),
        Command::Daemon => clicue::daemon::run(),
    }
}
