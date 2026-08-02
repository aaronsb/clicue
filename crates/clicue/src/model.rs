//! Shared vocabulary between sources (what to show) and layout (how to
//! show it). Deliberately small: each side owns its own internals and
//! meets the other here.

/// Where a cue came from. Only kinds determinable RELIABLY get a gutter
/// glyph (spec/card-layout.md — a wrong source marker is a confident lie).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Alias,
    Function,
    Builtin,
    System,
    /// Argument position: option vs subcommand is decided by spelling.
    Arg,
}

/// One candidate row.
#[derive(Debug, Clone)]
pub struct Cue {
    /// The exact token insertion uses — never the display label
    /// (prototype: `_clicue_disp` keyed by real token).
    pub insert: String,
    /// What the row SHOWS (`-d, --dir` for a grouped flag); equals
    /// `insert` when no grouping applies.
    pub label: String,
    pub gloss: String,
    pub kind: Kind,
    /// What follows insertion, as compsys declared it: None = ordinary
    /// trailing space; Some("") = nothing (clusters/attached values);
    /// Some(s) = that string (spec/compsys-bridge.md, -S trichotomy).
    pub suffix: Option<String>,
}

/// One row of the "typed" explanation box: label + description.
#[derive(Debug, Clone)]
pub struct ExplainRow {
    pub label: String,
    pub desc: String,
}

/// Command position or argument position (prototype `_clicue_mode`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    Cmd,
    Arg,
}
