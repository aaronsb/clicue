//! clicue — daemon and tool surface behind a generated zsh shim.
//!
//! Module map (mirrors ADR-100's component boundaries; modules land with
//! their spec sections, not before):
//!
//! - `protocol` — request/reply types over the per-user Unix socket
//! - `sources`  — candidate resolution: history habits, flag cache, compsys harvest
//! - `rank`     — frequency / recency / frecency scoring
//! - `layout`   — the card: two boxes, one selection, fixed height budget
//! - `theme`    — palettes and glyph sets, validated with a base fallback
//! - `corpus`   — storage, build, staleness
//! - `doctor`   — live-shell probing and the conflict catalog
//! - `shim`     — the generated zsh source

pub mod corpus;
pub mod daemon;
pub mod layout;
pub mod model;
pub mod protocol;
pub mod rank;
pub mod shim;
pub mod sources;
pub mod state;
pub mod theme;

use anyhow::{bail, Result};

/// Stub marker for subcommands whose spec section has not landed yet.
/// Exits nonzero so scripts cannot mistake a stub for the feature.
pub fn not_yet(what: &str) -> Result<()> {
    bail!("clicue {what}: not implemented yet — see docs/architecture/INDEX.md and spec/")
}
