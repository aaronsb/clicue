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
    Data,
    /// Run the daemon (normally auto-spawned by the shim)
    Daemon,
}

fn main() -> Result<()> {
    let cli = Cli::parse();
    match cli.command {
        Command::Init { shell } => clicue::not_yet(&format!("init {shell}")),
        Command::Install => clicue::not_yet("install"),
        Command::Uninstall => clicue::not_yet("uninstall"),
        Command::Doctor => clicue::not_yet("doctor"),
        Command::Config => clicue::not_yet("config"),
        Command::Theme => clicue::not_yet("theme"),
        Command::Data => clicue::not_yet("data"),
        Command::Daemon => clicue::daemon::run(),
    }
}
