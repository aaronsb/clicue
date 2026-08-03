//! Themes — two vocabularies (palette, glyphs), validated at load.
//!
//! Contract: spec/themes.md. Themes are an accessibility surface, not a
//! skin: a glyph the font cannot draw reads as a malfunction, so widths
//! are measured in terminal COLUMNS (unicode-width), which is the real
//! invariant the prototype policed by character count (T6). A theme that
//! fails validation falls back ENTIRELY to the base with messages naming
//! the problems — a half-applied theme is worse than the default (T3).
//! The base is genuinely terminal-default (T4): ASCII glyphs, no hex.

use std::path::Path;

use serde::Deserialize;
use unicode_width::UnicodeWidthStr;

/// Style strings in the form the highlight mechanism accepts
/// (`fg=#a277ff`, `fg=blue`, `bold`, `fg=white,bg=#444444`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Palette {
    pub border: String,
    pub accent: String,
    pub text: String,
    pub gloss: String,
    pub hint: String,
    pub ghost: String,
    /// Whole style for the selected row / cell (fg and bg together).
    pub selected: String,
    /// Emphasis for the typed prefix within a matching name.
    pub matched: String,
}

/// Box drawing, markers, and the source gutter. Dead vocabulary from the
/// prototype (badge, k_history) is dropped per T11.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Glyphs {
    pub tl: String,
    pub tr: String,
    pub bl: String,
    pub br: String,
    pub jl: String,
    pub jr: String,
    pub v: String,
    pub h: String,
    pub sel: String,
    pub nosel: String,
    pub k_alias: String,
    pub k_function: String,
    pub k_builtin: String,
    pub k_system: String,
    pub k_flag: String,
    pub k_sub: String,
    pub k_none: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Theme {
    pub name: String,
    pub palette: Palette,
    pub glyphs: Glyphs,
}

/// One glyph SET per encoding, referenced by themes, so adding a glyph key
/// touches one place, not five (T10).
fn glyphs_ascii() -> Glyphs {
    Glyphs {
        tl: "+".into(),
        tr: "+".into(),
        bl: "+".into(),
        br: "+".into(),
        jl: "+".into(),
        jr: "+".into(),
        v: "|".into(),
        h: "-".into(),
        sel: ">".into(),
        nosel: " ".into(),
        k_alias: "=".into(),
        k_function: "f".into(),
        k_builtin: "*".into(),
        k_system: "$".into(),
        k_flag: "-".into(),
        k_sub: ">".into(),
        k_none: " ".into(),
    }
}

fn glyphs_unicode_rounded() -> Glyphs {
    Glyphs {
        tl: "╭".into(),
        tr: "╮".into(),
        bl: "╰".into(),
        br: "╯".into(),
        jl: "├".into(),
        jr: "┤".into(),
        v: "│".into(),
        h: "─".into(),
        sel: "▸".into(),
        nosel: " ".into(),
        k_alias: "≈".into(),
        k_function: "ƒ".into(),
        k_builtin: "◆".into(),
        k_system: "▪".into(),
        k_flag: "·".into(),
        k_sub: "›".into(),
        k_none: " ".into(),
    }
}

/// The contract: renders anywhere, assumes nothing about font or palette.
pub fn base() -> Theme {
    Theme {
        name: "base".into(),
        palette: Palette {
            border: "fg=default".into(),
            accent: "bold".into(),
            text: "fg=default".into(),
            gloss: "fg=default".into(),
            hint: "fg=default".into(),
            ghost: "fg=default".into(),
            selected: "standout".into(),
            matched: "bold".into(),
        },
        glyphs: glyphs_ascii(),
    }
}

fn aura() -> Theme {
    Theme {
        name: "aura".into(),
        palette: Palette {
            border: "fg=#a277ff".into(),
            accent: "fg=#61ffca".into(),
            text: "fg=#edecee".into(),
            gloss: "fg=#9692a8".into(),
            hint: "fg=#6d6a7f".into(),
            ghost: "fg=#6d6a7f".into(),
            selected: "fg=#ffffff,bg=#3d375e".into(),
            matched: "fg=#61ffca,bold".into(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn mono() -> Theme {
    Theme {
        name: "mono".into(),
        palette: Palette {
            border: "fg=default".into(),
            accent: "bold".into(),
            text: "fg=default".into(),
            gloss: "fg=#808080".into(),
            hint: "fg=#808080".into(),
            ghost: "fg=#808080".into(),
            selected: "fg=white,bg=#444444".into(),
            matched: "bold".into(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn plain() -> Theme {
    Theme {
        name: "plain".into(),
        palette: Palette {
            border: "fg=blue".into(),
            accent: "fg=cyan".into(),
            text: "fg=default".into(),
            gloss: "fg=default".into(),
            hint: "fg=default".into(),
            ghost: "fg=default".into(),
            selected: "fg=white,bg=blue".into(),
            matched: "fg=cyan,bold".into(),
        },
        glyphs: glyphs_ascii(),
    }
}

pub fn builtin(name: &str) -> Option<Theme> {
    match name {
        "base" => Some(base()),
        "aura" => Some(aura()),
        "mono" => Some(mono()),
        "plain" => Some(plain()),
        _ => None,
    }
}

pub fn builtin_names() -> &'static [&'static str] {
    &["aura", "base", "mono", "plain"]
}

// ── TOML theme files ─────────────────────────────────────────────────────
// Every field optional: a partial theme is legal and merges over the base
// (T2). deny_unknown_fields turns a typo'd key into a named error instead
// of a silently ignored one.

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct ThemeFile {
    #[allow(dead_code)]
    name: Option<String>,
    /// `ascii` (default) or `unicode-rounded`.
    #[serde(rename = "glyph-set")]
    glyph_set: Option<String>,
    #[serde(default)]
    palette: PaletteFile,
    #[serde(default)]
    glyphs: GlyphsFile,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct PaletteFile {
    border: Option<String>,
    accent: Option<String>,
    text: Option<String>,
    gloss: Option<String>,
    hint: Option<String>,
    ghost: Option<String>,
    selected: Option<String>,
    #[serde(rename = "match")]
    matched: Option<String>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct GlyphsFile {
    tl: Option<String>,
    tr: Option<String>,
    bl: Option<String>,
    br: Option<String>,
    jl: Option<String>,
    jr: Option<String>,
    v: Option<String>,
    h: Option<String>,
    sel: Option<String>,
    nosel: Option<String>,
    k_alias: Option<String>,
    k_function: Option<String>,
    k_builtin: Option<String>,
    k_system: Option<String>,
    k_flag: Option<String>,
    k_sub: Option<String>,
    k_none: Option<String>,
}

fn cols(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Every key the renderer reads, checked in COLUMNS (T3, T5, T6). The
/// border/marker arithmetic in layout assumes one column per glyph.
pub fn validate(t: &Theme) -> Vec<String> {
    let mut errs = Vec::new();
    let boxes: [(&str, &str); 10] = [
        ("tl", &t.glyphs.tl),
        ("tr", &t.glyphs.tr),
        ("bl", &t.glyphs.bl),
        ("br", &t.glyphs.br),
        ("jl", &t.glyphs.jl),
        ("jr", &t.glyphs.jr),
        ("v", &t.glyphs.v),
        ("h", &t.glyphs.h),
        ("sel", &t.glyphs.sel),
        ("nosel", &t.glyphs.nosel),
    ];
    for (k, g) in boxes {
        if cols(g) != 1 {
            errs.push(format!("glyphs.{k} must be exactly one column wide"));
        }
    }
    let gutter: [(&str, &str); 7] = [
        ("k_alias", &t.glyphs.k_alias),
        ("k_function", &t.glyphs.k_function),
        ("k_builtin", &t.glyphs.k_builtin),
        ("k_system", &t.glyphs.k_system),
        ("k_flag", &t.glyphs.k_flag),
        ("k_sub", &t.glyphs.k_sub),
        ("k_none", &t.glyphs.k_none),
    ];
    for (k, g) in gutter {
        if cols(g) != 1 {
            errs.push(format!("glyphs.{k} must be exactly one column wide"));
        }
    }
    let pal: [(&str, &str); 8] = [
        ("border", &t.palette.border),
        ("accent", &t.palette.accent),
        ("text", &t.palette.text),
        ("gloss", &t.palette.gloss),
        ("hint", &t.palette.hint),
        ("ghost", &t.palette.ghost),
        ("selected", &t.palette.selected),
        ("match", &t.palette.matched),
    ];
    for (k, v) in pal {
        if v.is_empty() {
            errs.push(format!(
                "palette.{k} is empty — the host rejects empty styles"
            ));
        }
    }
    errs
}

fn merge(name: &str, file: ThemeFile) -> Result<Theme, Vec<String>> {
    let glyph_base = match file.glyph_set.as_deref() {
        None | Some("ascii") => glyphs_ascii(),
        Some("unicode-rounded") => glyphs_unicode_rounded(),
        Some(other) => {
            return Err(vec![format!(
                "glyph-set '{other}' is not one of: ascii, unicode-rounded"
            )])
        }
    };
    let b = base();
    let p = file.palette;
    let g = file.glyphs;
    let theme = Theme {
        name: name.to_string(),
        palette: Palette {
            border: p.border.unwrap_or(b.palette.border),
            accent: p.accent.unwrap_or(b.palette.accent),
            text: p.text.unwrap_or(b.palette.text),
            gloss: p.gloss.unwrap_or(b.palette.gloss),
            hint: p.hint.unwrap_or(b.palette.hint),
            ghost: p.ghost.unwrap_or(b.palette.ghost),
            selected: p.selected.unwrap_or(b.palette.selected),
            matched: p.matched.unwrap_or(b.palette.matched),
        },
        glyphs: Glyphs {
            tl: g.tl.unwrap_or(glyph_base.tl),
            tr: g.tr.unwrap_or(glyph_base.tr),
            bl: g.bl.unwrap_or(glyph_base.bl),
            br: g.br.unwrap_or(glyph_base.br),
            jl: g.jl.unwrap_or(glyph_base.jl),
            jr: g.jr.unwrap_or(glyph_base.jr),
            v: g.v.unwrap_or(glyph_base.v),
            h: g.h.unwrap_or(glyph_base.h),
            sel: g.sel.unwrap_or(glyph_base.sel),
            nosel: g.nosel.unwrap_or(glyph_base.nosel),
            k_alias: g.k_alias.unwrap_or(glyph_base.k_alias),
            k_function: g.k_function.unwrap_or(glyph_base.k_function),
            k_builtin: g.k_builtin.unwrap_or(glyph_base.k_builtin),
            k_system: g.k_system.unwrap_or(glyph_base.k_system),
            k_flag: g.k_flag.unwrap_or(glyph_base.k_flag),
            k_sub: g.k_sub.unwrap_or(glyph_base.k_sub),
            k_none: g.k_none.unwrap_or(glyph_base.k_none),
        },
    };
    let errs = validate(&theme);
    if errs.is_empty() {
        Ok(theme)
    } else {
        Err(errs)
    }
}

/// Parse and validate one TOML theme source. Exposed for tests and for
/// previewing a theme file that is not installed yet.
pub fn from_toml(name: &str, src: &str) -> Result<Theme, Vec<String>> {
    let file: ThemeFile = toml::from_str(src).map_err(|e| vec![e.to_string()])?;
    merge(name, file)
}

/// Resolve a theme by name: builtins first, then `<dir>/<name>.toml`.
/// Never fails: any problem returns the base plus messages naming it —
/// the operator must be able to tell WHICH theme they are looking at (T3).
pub fn load(name: &str, themes_dir: Option<&Path>) -> (Theme, Vec<String>) {
    if let Some(t) = builtin(name) {
        return (t, Vec::new());
    }
    let Some(dir) = themes_dir else {
        return (
            base(),
            vec![format!(
                "theme '{name}' not found (no themes directory) — using base"
            )],
        );
    };
    let path = dir.join(format!("{name}.toml"));
    let src = match std::fs::read_to_string(&path) {
        Ok(s) => s,
        Err(_) => {
            return (
                base(),
                vec![format!(
                    "theme '{name}' not found at {} — using base",
                    path.display()
                )],
            )
        }
    };
    match from_toml(name, &src) {
        Ok(t) => (t, Vec::new()),
        Err(mut errs) => {
            errs.push(format!("theme '{name}' rejected — using base"));
            (base(), errs)
        }
    }
}

/// Names an operator can switch to: builtins plus installed TOML files.
pub fn available(themes_dir: Option<&Path>) -> Vec<String> {
    let mut names: Vec<String> = builtin_names().iter().map(|s| s.to_string()).collect();
    if let Some(dir) = themes_dir {
        if let Ok(entries) = std::fs::read_dir(dir) {
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) == Some("toml") {
                    if let Some(stem) = p.file_stem().and_then(|x| x.to_str()) {
                        if !names.iter().any(|n| n == stem) {
                            names.push(stem.to_string());
                        }
                    }
                }
            }
        }
    }
    names.sort();
    names
}

// ── preview: a sample card on stdout ─────────────────────────────────────
// `clicue theme preview <name>` renders fake cues through the REAL layout
// engine so what the operator sees is what a card will look like, colours
// included — region_highlight styles translated to ANSI.

/// One region_highlight style string → ANSI SGR sequence ("" = default).
fn style_to_ansi(style: &str) -> String {
    let mut codes: Vec<String> = Vec::new();
    for part in style.split(',') {
        let part = part.trim();
        let (attr, val) = match part.split_once('=') {
            Some((a, v)) => (a, v),
            None => (part, ""),
        };
        match attr {
            "bold" => codes.push("1".into()),
            "underline" => codes.push("4".into()),
            "standout" => codes.push("7".into()),
            "fg" | "bg" => {
                let base = if attr == "fg" { 38 } else { 48 };
                if let Some(hex) = val.strip_prefix('#') {
                    if hex.len() == 6 {
                        if let (Ok(r), Ok(g), Ok(b)) = (
                            u8::from_str_radix(&hex[0..2], 16),
                            u8::from_str_radix(&hex[2..4], 16),
                            u8::from_str_radix(&hex[4..6], 16),
                        ) {
                            codes.push(format!("{base};2;{r};{g};{b}"));
                        }
                    }
                } else if let Ok(n) = val.parse::<u8>() {
                    codes.push(format!("{base};5;{n}"));
                } else {
                    let named = match val {
                        "black" => Some(0),
                        "red" => Some(1),
                        "green" => Some(2),
                        "yellow" => Some(3),
                        "blue" => Some(4),
                        "magenta" => Some(5),
                        "cyan" => Some(6),
                        "white" => Some(7),
                        _ => None, // "default" and unknowns: no code
                    };
                    if let Some(n) = named {
                        // Basic SGR: 30–37 foreground, 40–47 background.
                        codes.push(format!("{}", if attr == "fg" { 30 + n } else { 40 + n }));
                    }
                }
            }
            _ => {}
        }
    }
    if codes.is_empty() {
        String::new()
    } else {
        format!("\x1b[{}m", codes.join(";"))
    }
}

/// One line of theme, in the theme's own colours: enough to choose from
/// a list without running a full preview per name.
pub fn swatch(t: &Theme) -> String {
    let r = "\x1b[0m";
    let a = |s: &str| style_to_ansi(s);
    let g = &t.glyphs;
    let p = &t.palette;
    format!(
        "  {:<8} {}{}{}{}{r} {}{}{r} {}gi{r}{}t{r}  {}the stupid content tracker{r}  {}t status{r}  {}Tab cycle{r} {}{}{}{}{r}",
        t.name,
        a(&p.border), g.tl, g.h, g.h,
        a(&p.accent), g.sel,
        a(&p.matched), a(&p.text),
        a(&p.gloss),
        a(&p.ghost),
        a(&p.hint),
        a(&p.border), g.h, g.h, g.tr,
        r = r,
    )
}

/// Render a sample card with this theme at the given width, ANSI-coloured.
pub fn preview(theme: &Theme, cols: u16) -> String {
    use crate::layout::{CardInput, Dims, KeyLabels, LayoutCfg, View};
    use crate::model::{Cue, Kind, Mode};

    let cue = |insert: &str, gloss: &str, kind: Kind| Cue {
        insert: insert.into(),
        label: insert.into(),
        gloss: gloss.into(),
        kind,
        suffix: None,
    };
    let cues = vec![
        cue("git", "the stupid content tracker", Kind::System),
        cue("gitui", "blazing fast terminal-ui for git", Kind::System),
        cue("gib", "git wrapper of mine", Kind::Alias),
        cue("gimme", "fetch a file", Kind::Function),
        cue("gist", "upload code to gist", Kind::System),
    ];
    let cfg = LayoutCfg {
        tier1_rows: 4,
        ..LayoutCfg::default()
    };
    let input = CardInput {
        cues: &cues,
        explain: &[],
        mode: Mode::Cmd,
        prefix: "gi",
        info: false,
        argnomatch: false,
        engaged: true,
        familiar: false,
        expanded: false,
        tab_inserts: false,
        ghost: "t status",
        invnote: "",
        dims: Dims { cols, lines: 24 },
        cfg: &cfg,
        keys: &KeyLabels::default(),
    };
    let mut view = View::default();
    let Some(card) = crate::layout::render(&input, &mut view, theme) else {
        return format!("theme {}: nothing to preview\n", theme.name);
    };

    // Last span wins per character, exactly as region_highlight stacks.
    let chars: Vec<char> = card.text.chars().collect();
    let mut styles: Vec<String> = vec![String::new(); chars.len()];
    for s in &card.spans {
        let ansi = style_to_ansi(&s.style);
        for slot in styles.iter_mut().take(s.end.min(chars.len())).skip(s.start) {
            *slot = ansi.clone();
        }
    }
    let mut out = String::with_capacity(card.text.len() * 2);
    let mut current = String::new();
    for (c, style) in chars.iter().zip(&styles) {
        if *style != current {
            out.push_str("\x1b[0m");
            out.push_str(style);
            current = style.clone();
        }
        out.push(*c);
    }
    out.push_str("\x1b[0m\n");
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn builtins_validate_clean() {
        for name in builtin_names() {
            let t = builtin(name).unwrap();
            assert!(validate(&t).is_empty(), "{name} failed validation");
        }
    }

    #[test]
    fn base_is_terminal_default_not_aura() {
        // T4: the prototype shipped a base byte-identical to aura's hexes.
        let b = base();
        assert!(!b.palette.border.contains('#'));
        assert_ne!(b.palette, aura().palette);
    }

    #[test]
    fn partial_theme_merges_over_base() {
        let t = from_toml("accent-only", "[palette]\naccent = \"fg=red\"\n").unwrap();
        assert_eq!(t.palette.accent, "fg=red");
        assert_eq!(t.palette.border, base().palette.border);
        assert_eq!(t.glyphs, glyphs_ascii());
    }

    #[test]
    fn glyph_set_reference_and_override() {
        let t = from_toml(
            "rounded-red",
            "glyph-set = \"unicode-rounded\"\n[palette]\nborder = \"fg=red\"\n[glyphs]\nsel = \"»\"\n",
        )
        .unwrap();
        assert_eq!(t.glyphs.tl, "╭");
        assert_eq!(t.glyphs.sel, "»");
    }

    #[test]
    fn wide_gutter_glyph_is_rejected_with_named_key() {
        // T6: emoji is two columns in most terminals.
        let err = from_toml("bad", "[glyphs]\nk_alias = \"🚀\"\n").unwrap_err();
        assert!(err.iter().any(|e| e.contains("k_alias")), "{err:?}");
    }

    #[test]
    fn wide_sel_marker_is_rejected() {
        // T5/C3: the marker arithmetic assumes one column.
        let err = from_toml("bad", "[glyphs]\nsel = \"->\"\n").unwrap_err();
        assert!(err.iter().any(|e| e.contains("sel")), "{err:?}");
    }

    #[test]
    fn unknown_key_is_an_error_not_a_silence() {
        let err = from_toml("typo", "[palette]\nbordr = \"fg=red\"\n").unwrap_err();
        assert!(
            err[0].contains("bordr") || err[0].contains("unknown"),
            "{err:?}"
        );
    }

    #[test]
    fn load_falls_back_to_base_with_message() {
        let (t, msgs) = load("no-such-theme", None);
        assert_eq!(t.name, "base");
        assert!(msgs[0].contains("no-such-theme"));
    }

    #[test]
    fn empty_palette_value_is_rejected() {
        // T3: an empty colour produces a highlight spec the host rejects.
        let err = from_toml("bad", "[palette]\ngloss = \"\"\n").unwrap_err();
        assert!(err.iter().any(|e| e.contains("gloss")), "{err:?}");
    }
}
