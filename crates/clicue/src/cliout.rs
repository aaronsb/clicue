//! CLI output helper — ADR-400.
//!
//! Three modes, chosen without a flag: themed when stdout is a tty (the
//! ACTIVE theme's palette through the same [`theme::style_to_ansi`] the
//! swatch uses), plain when piped, and `--json` handled by the callers —
//! this module only answers "how do I paint this string right now".
//! Palette roles map exactly as the card maps them: accent for names,
//! gloss for descriptions, hint for labels, matched for emphasis.

use crate::theme::{self, Theme};
use std::io::IsTerminal;

pub struct Out {
    themed: bool,
    theme: Theme,
}

impl Out {
    /// Themed iff stdout is a terminal. Loads the operator's configured
    /// theme; a broken theme file falls back exactly as the daemon does.
    pub fn auto() -> Out {
        let themed = std::io::stdout().is_terminal();
        let theme = if themed {
            let loaded = crate::config::load();
            let (t, _msgs) = theme::load(&loaded.config.theme, crate::config::themes_dir().as_deref());
            t
        } else {
            theme::base()
        };
        Out { themed, theme }
    }

    fn paint(&self, style: &str, s: &str) -> String {
        if !self.themed || style.is_empty() {
            return s.to_string();
        }
        let sgr = theme::style_to_ansi(style);
        if sgr.is_empty() {
            s.to_string()
        } else {
            format!("{sgr}{s}\x1b[0m")
        }
    }

    /// Names: commands, paths, theme names.
    pub fn accent(&self, s: &str) -> String {
        self.paint(&self.theme.palette.accent, s)
    }
    /// Descriptions and secondary prose.
    pub fn gloss(&self, s: &str) -> String {
        self.paint(&self.theme.palette.gloss, s)
    }
    /// Labels, keys, section headers.
    pub fn hint(&self, s: &str) -> String {
        self.paint(&self.theme.palette.hint, s)
    }
    /// Emphasis: warnings, the thing that changed.
    pub fn matched(&self, s: &str) -> String {
        self.paint(&self.theme.palette.matched, s)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_mode_paints_nothing() {
        let out = Out {
            themed: false,
            theme: theme::base(),
        };
        assert_eq!(out.accent("git"), "git");
        assert_eq!(out.matched("STALE"), "STALE");
    }

    #[test]
    fn themed_mode_wraps_with_sgr_and_reset() {
        let out = Out {
            themed: true,
            theme: theme::base(),
        };
        let painted = out.accent("git");
        // The base theme's accent is a real style: SGR in, reset out.
        assert!(painted.starts_with("\x1b["), "{painted:?}");
        assert!(painted.ends_with("git\x1b[0m"), "{painted:?}");
    }
}
