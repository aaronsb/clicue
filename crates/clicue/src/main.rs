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
    Install,
    /// Remove clicue from the zsh config and restore original bindings
    Uninstall,
    /// Probe a live zsh for conflicts and silent degradations
    Doctor,
    /// Show or edit configuration
    Config,
    /// List, set, or preview themes
    Theme,
    /// Inspect and manage collected data (corpus, flag cache, habits)
    Data {
        #[command(subcommand)]
        cmd: Option<DataCmd>,
    },
    /// Run the daemon (normally auto-spawned by the shim)
    Daemon,
}

#[derive(Subcommand)]
enum DataCmd {
    /// Corpus location, size, and staleness
    Status,
    /// Rebuild the corpus from history and whatis
    Rebuild,
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
                    let state = if corpus::is_stale(&c, &current) {
                        "STALE — history or installed commands changed; run `clicue data rebuild`"
                    } else {
                        "current"
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
                "corpus built: {} ({} glosses, {} invocations)",
                cache.display(),
                c.gloss.len(),
                c.invoke.len()
            );
            Ok(())
        }
    }
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Init { shell } => {
            if shell != "zsh" {
                anyhow::bail!("only zsh is supported (got {shell})");
            }
            print!("{}", clicue::shim::emit_zsh());
            Ok(())
        }
        Command::Install => clicue::not_yet("install"),
        Command::Uninstall => clicue::not_yet("uninstall"),
        Command::Doctor => clicue::not_yet("doctor"),
        Command::Config => clicue::not_yet("config"),
        Command::Theme => {
            println!("built-in: {}", clicue::theme::builtin_names().join("  "));
            Ok(())
        }
        Command::Data { cmd } => data(cmd),
        Command::Daemon => clicue::daemon::run(),
    }
}
