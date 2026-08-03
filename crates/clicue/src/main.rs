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
    List,
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
    Status,
    /// Rebuild the corpus from history and whatis
    Rebuild,
    /// Everything clicue knows about one command
    Inspect { cmd: String },
    /// Remove one command's habits from the corpus (targeted deletion)
    Forget { cmd: String },
}

fn theme_cmd(cmd: Option<ThemeCmd>) -> Result<()> {
    use clicue::theme;
    let dir = clicue::config::themes_dir();
    match cmd.unwrap_or(ThemeCmd::List) {
        ThemeCmd::List => {
            let loaded = clicue::config::load();
            println!("theme: {} (current)", loaded.config.theme);
            for name in theme::available(dir.as_deref()) {
                let (t, _) = theme::load(&name, dir.as_deref());
                println!("{}", theme::swatch(&t));
            }
            println!("\nset:      clicue theme <name>");
            println!("preview:  clicue theme preview <name>");
            Ok(())
        }
        ThemeCmd::Set { name } => {
            let names = theme::available(dir.as_deref());
            if !names.contains(&name) {
                anyhow::bail!("no theme named {name:?} — available: {}", names.join("  "));
            }
            let (t, msgs) = theme::load(&name, dir.as_deref());
            for m in &msgs {
                eprintln!("warning: {m}");
            }
            if t.name != name {
                anyhow::bail!("theme {name:?} failed validation — not set");
            }
            let path = clicue::config::config_path()?;
            clicue::config::set_key_line(&path, "theme", &name)?;
            println!(
                "theme is now {name} ({}) — applied live; the daemon reloads within a second",
                path.display()
            );
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
            let (t, msgs) = theme::load(&name, dir.as_deref());
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
    match cmd.unwrap_or(DataCmd::Status) {
        DataCmd::Status => {
            match corpus::load(&cache) {
                Ok(c) => {
                    let current = corpus::stamp(&corpus::default_histfile()?, &corpus::path_dirs());
                    println!("corpus:  {}", cache.display());
                    println!("  glosses      {}", c.gloss.len());
                    println!("  invocations  {}", c.invoke.len());
                    // A live shell appends every command to history as it
                    // runs — `clicue data` itself moved the file before this
                    // check. Trailing history is the working state of derived
                    // data, not something to alarm about (S6).
                    let state = match corpus::staleness(&c, &current) {
                        corpus::Staleness::Current => "current",
                        corpus::Staleness::TrailingHistory => {
                            "current (trailing live history — folds in at the next daemon start, or now via `clicue data rebuild`)"
                        }
                        corpus::Staleness::Structural => {
                            "STALE — corpus format or installed commands changed; run `clicue data rebuild`"
                        }
                    };
                    println!("  state        {state}");
                }
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
        DataCmd::Inspect { cmd } => {
            let c = corpus::load(&cache)?;
            println!("{cmd}:");
            match c.gloss.get(&cmd) {
                Some(g) => println!("  gloss     {g}"),
                None => println!("  gloss     (none)"),
            }
            let count = c.freq.get(&cmd).copied().unwrap_or(0);
            println!("  runs      {count}");
            if let Some(last) = c.last.get(&cmd).filter(|l| **l > 0) {
                let now = std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_secs())
                    .unwrap_or(0);
                println!("  last      {}d ago", now.saturating_sub(*last) / 86400);
            }
            if let Some(toks) = c.args.get(&cmd) {
                println!("  args      {}", toks.join(" "));
            }
            let prefix = format!("{cmd} ");
            let mut invocations: Vec<_> = c
                .invoke
                .iter()
                .filter(|(k, _)| **k == cmd || k.starts_with(&prefix))
                .collect();
            invocations.sort_by(|a, b| b.1.count.cmp(&a.1.count));
            if !invocations.is_empty() {
                println!("  invocations:");
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
                println!("  flags     {} harvested", rows.len());
                for r in rows.iter().take(8) {
                    println!("    {:<24} {}", r.label, r.gloss);
                }
                if rows.len() > 8 {
                    println!("    … `clicue data inspect` shows 8; the card shows all");
                }
            }
            for sub in store.subcommand_tables(&resolved) {
                println!("  flags     {sub} (subcommand table)");
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
