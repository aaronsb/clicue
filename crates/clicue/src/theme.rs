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
    /// Card-wide background (`bg=#rrggbb`). Empty = the terminal's own.
    /// When set, the renderer lays it under every span so the card reads
    /// as a solid panel that stands out from the page.
    pub panel: String,
    /// Hex stops interpolated along horizontal borders, per segment —
    /// a lit-from-somewhere metallic sheen. Empty = flat `border`.
    pub border_gradient: Vec<String>,
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
            panel: String::new(),
            border_gradient: Vec::new(),
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
            panel: String::new(),
            border_gradient: Vec::new(),
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
            panel: String::new(),
            border_gradient: Vec::new(),
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
            panel: String::new(),
            border_gradient: Vec::new(),
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
        "monokai" => Some(monokai()),
        "dracula" => Some(dracula()),
        "nord" => Some(nord()),
        "gruvbox" => Some(gruvbox()),
        "agnoster" => Some(agnoster()),
        "chrome" => Some(chrome()),
        "solid-metal" => Some(solid_metal()),
        "solarized" => Some(solarized()),
        "solarized-light" => Some(solarized_light()),
        "tokyo-night" => Some(tokyo_night()),
        "catppuccin" => Some(catppuccin()),
        "valentine" => Some(valentine()),
        "halloween" => Some(halloween()),
        _ => None,
    }
}

pub fn builtin_names() -> &'static [&'static str] {
    &[
        "aura",
        "base",
        "mono",
        "plain",
        "monokai",
        "dracula",
        "nord",
        "gruvbox",
        "solarized",
        "solarized-light",
        "tokyo-night",
        "catppuccin",
        "agnoster",
        "chrome",
        "solid-metal",
        "valentine",
        "halloween",
    ]
}

fn monokai() -> Theme {
    Theme {
        name: "monokai".into(),
        palette: Palette {
            border: "fg=#75715e".into(),
            accent: "fg=#a6e22e".into(),
            text: "fg=#f8f8f2".into(),
            gloss: "fg=#75715e".into(),
            hint: "fg=#75715e".into(),
            ghost: "fg=#75715e".into(),
            selected: "fg=#f8f8f2,bg=#49483e".into(),
            matched: "fg=#f92672,bold".into(),
            panel: String::new(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn dracula() -> Theme {
    Theme {
        name: "dracula".into(),
        palette: Palette {
            border: "fg=#bd93f9".into(),
            accent: "fg=#50fa7b".into(),
            text: "fg=#f8f8f2".into(),
            gloss: "fg=#6272a4".into(),
            hint: "fg=#6272a4".into(),
            ghost: "fg=#6272a4".into(),
            selected: "fg=#f8f8f2,bg=#44475a".into(),
            matched: "fg=#ff79c6,bold".into(),
            panel: String::new(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn nord() -> Theme {
    Theme {
        name: "nord".into(),
        palette: Palette {
            border: "fg=#81a1c1".into(),
            accent: "fg=#88c0d0".into(),
            text: "fg=#eceff4".into(),
            gloss: "fg=#616e88".into(),
            hint: "fg=#616e88".into(),
            ghost: "fg=#616e88".into(),
            selected: "fg=#eceff4,bg=#434c5e".into(),
            matched: "fg=#a3be8c,bold".into(),
            panel: String::new(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn gruvbox() -> Theme {
    Theme {
        name: "gruvbox".into(),
        palette: Palette {
            border: "fg=#d79921".into(),
            accent: "fg=#b8bb26".into(),
            text: "fg=#ebdbb2".into(),
            gloss: "fg=#928374".into(),
            hint: "fg=#928374".into(),
            ghost: "fg=#928374".into(),
            selected: "fg=#ebdbb2,bg=#504945".into(),
            matched: "fg=#fabd2f,bold".into(),
            panel: String::new(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// The panel showcase: powerline-segment blues, card on its own ground.
fn agnoster() -> Theme {
    Theme {
        name: "agnoster".into(),
        palette: Palette {
            border: "fg=#8ad0f0".into(),
            accent: "fg=#ffd700".into(),
            text: "fg=#ffffff".into(),
            gloss: "fg=#a8d8ee".into(),
            hint: "fg=#74b4d4".into(),
            ghost: "fg=#74b4d4".into(),
            selected: "fg=#ffffff,bg=#0a84c1".into(),
            matched: "fg=#ffd700,bold".into(),
            panel: "bg=#00506e".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// The gradient showcase: horizontal borders sweep dark→bright→dark,
/// which the eye reads as brushed metal under a light.
fn chrome() -> Theme {
    Theme {
        name: "chrome".into(),
        palette: Palette {
            border: "fg=#9ca3af".into(),
            accent: "fg=#ffffff,bold".into(),
            text: "fg=#e5e7eb".into(),
            gloss: "fg=#9ca3af".into(),
            hint: "fg=#6b7280".into(),
            ghost: "fg=#6b7280".into(),
            selected: "fg=#f9fafb,bg=#374151".into(),
            matched: "fg=#ffffff,bold".into(),
            panel: String::new(),
            border_gradient: vec![
                "#4b5563".into(),
                "#d1d5db".into(),
                "#f9fafb".into(),
                "#9ca3af".into(),
                "#374151".into(),
            ],
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// Panel + gradient together: gunmetal ground, brushed-steel borders.
/// The name is an affectionate genre nod; every colour is generic
/// military-industrial, nothing borrowed.
fn solid_metal() -> Theme {
    Theme {
        name: "solid-metal".into(),
        palette: Palette {
            border: "fg=#8b949e".into(),
            accent: "fg=#7ee787".into(),
            text: "fg=#e6edf3".into(),
            gloss: "fg=#8b949e".into(),
            hint: "fg=#6e7681".into(),
            ghost: "fg=#6e7681".into(),
            selected: "fg=#ffffff,bg=#37414f".into(),
            matched: "fg=#f0b849,bold".into(),
            panel: "bg=#23272e".into(),
            border_gradient: vec![
                "#3d434b".into(),
                "#aeb6bf".into(),
                "#e6e9ec".into(),
                "#7d858f".into(),
                "#2c3138".into(),
            ],
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// Solarized dark on its own base03 ground — the palette was designed
/// against that background, so the card carries it along.
fn solarized() -> Theme {
    Theme {
        name: "solarized".into(),
        palette: Palette {
            border: "fg=#586e75".into(),
            accent: "fg=#268bd2".into(),
            text: "fg=#93a1a1".into(),
            gloss: "fg=#586e75".into(),
            hint: "fg=#586e75".into(),
            ghost: "fg=#586e75".into(),
            selected: "fg=#fdf6e3,bg=#073642".into(),
            matched: "fg=#b58900,bold".into(),
            panel: "bg=#002b36".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// A light card that works on a dark terminal: the panel supplies the
/// paper, so the theme is usable anywhere (the point of panels).
fn solarized_light() -> Theme {
    Theme {
        name: "solarized-light".into(),
        palette: Palette {
            border: "fg=#93a1a1".into(),
            accent: "fg=#268bd2".into(),
            text: "fg=#073642".into(),
            gloss: "fg=#93a1a1".into(),
            hint: "fg=#93a1a1".into(),
            ghost: "fg=#93a1a1".into(),
            selected: "fg=#002b36,bg=#eee8d5".into(),
            matched: "fg=#cb4b16,bold".into(),
            panel: "bg=#fdf6e3".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

fn tokyo_night() -> Theme {
    Theme {
        name: "tokyo-night".into(),
        palette: Palette {
            border: "fg=#3b4261".into(),
            accent: "fg=#7aa2f7".into(),
            text: "fg=#c0caf5".into(),
            gloss: "fg=#565f89".into(),
            hint: "fg=#565f89".into(),
            ghost: "fg=#565f89".into(),
            selected: "fg=#c0caf5,bg=#283457".into(),
            matched: "fg=#bb9af7,bold".into(),
            panel: "bg=#1a1b26".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// Catppuccin mocha.
fn catppuccin() -> Theme {
    Theme {
        name: "catppuccin".into(),
        palette: Palette {
            border: "fg=#585b70".into(),
            accent: "fg=#89b4fa".into(),
            text: "fg=#cdd6f4".into(),
            gloss: "fg=#6c7086".into(),
            hint: "fg=#6c7086".into(),
            ghost: "fg=#6c7086".into(),
            selected: "fg=#cdd6f4,bg=#313244".into(),
            matched: "fg=#f5c2e7,bold".into(),
            panel: "bg=#1e1e2e".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// Because why not: deep-wine ground, ribbon-gradient borders.
fn valentine() -> Theme {
    Theme {
        name: "valentine".into(),
        palette: Palette {
            border: "fg=#f472b6".into(),
            accent: "fg=#fb7185".into(),
            text: "fg=#ffe4e6".into(),
            gloss: "fg=#c48b9f".into(),
            hint: "fg=#a06b80".into(),
            ghost: "fg=#a06b80".into(),
            selected: "fg=#fff1f2,bg=#9f1239".into(),
            matched: "fg=#fda4af,bold".into(),
            panel: "bg=#3a1b29".into(),
            border_gradient: vec![
                "#9f1239".into(),
                "#fda4af".into(),
                "#fecdd3".into(),
                "#fb7185".into(),
                "#be185d".into(),
            ],
        },
        glyphs: glyphs_unicode_rounded(),
    }
}

/// Pumpkin on midnight purple; the selection inverts into the pumpkin.
fn halloween() -> Theme {
    Theme {
        name: "halloween".into(),
        palette: Palette {
            border: "fg=#f97316".into(),
            accent: "fg=#a78bfa".into(),
            text: "fg=#f4ecd8".into(),
            gloss: "fg=#7c6f9f".into(),
            hint: "fg=#7c6f9f".into(),
            ghost: "fg=#7c6f9f".into(),
            selected: "fg=#1c1025,bg=#f97316".into(),
            matched: "fg=#84cc16,bold".into(),
            panel: "bg=#1c1025".into(),
            border_gradient: Vec::new(),
        },
        glyphs: glyphs_unicode_rounded(),
    }
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
    panel: Option<String>,
    #[serde(rename = "border-gradient")]
    border_gradient: Option<Vec<String>>,
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
    if !t.palette.panel.is_empty() && !t.palette.panel.contains("bg=") {
        errs.push("palette.panel must carry a bg= (it is the card's ground)".into());
    }
    if !t.palette.border_gradient.is_empty() {
        if t.palette.border_gradient.len() < 2 {
            errs.push("palette.border-gradient needs at least two stops".into());
        }
        for stop in &t.palette.border_gradient {
            if parse_hex(stop).is_none() {
                errs.push(format!(
                    "palette.border-gradient stop {stop:?} is not #rrggbb"
                ));
            }
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
            panel: p.panel.unwrap_or_default(),
            border_gradient: p.border_gradient.unwrap_or_default(),
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

/// Serialize a theme as the full template contract file (T14): every
/// palette key present so the file teaches its own schema; glyphs by set
/// name when they match a shipped set, spelled out otherwise. `from_toml`
/// of this output must reproduce the theme exactly — pinned by test.
pub fn to_toml(t: &Theme) -> String {
    let mut s = String::new();
    s.push_str(&format!(
        "# clicue theme \"{}\" — regenerated from the built-in when this file\n\
         # is missing, so DELETING it restores the default. Edits apply live.\n\
         # Partial files are legal: absent keys fall back to the base theme.\n\n",
        t.name
    ));
    if t.glyphs == glyphs_unicode_rounded() {
        s.push_str("glyph-set = \"unicode-rounded\"\n");
    } else if t.glyphs == glyphs_ascii() {
        s.push_str("glyph-set = \"ascii\"\n");
    } else {
        s.push_str("[glyphs]\n");
        let g = &t.glyphs;
        for (k, v) in [
            ("tl", &g.tl),
            ("tr", &g.tr),
            ("bl", &g.bl),
            ("br", &g.br),
            ("jl", &g.jl),
            ("jr", &g.jr),
            ("v", &g.v),
            ("h", &g.h),
            ("sel", &g.sel),
            ("nosel", &g.nosel),
            ("k_alias", &g.k_alias),
            ("k_function", &g.k_function),
            ("k_builtin", &g.k_builtin),
            ("k_system", &g.k_system),
            ("k_flag", &g.k_flag),
            ("k_sub", &g.k_sub),
            ("k_none", &g.k_none),
        ] {
            s.push_str(&format!("{k} = {v:?}\n"));
        }
    }
    s.push_str("\n[palette]\n");
    let p = &t.palette;
    for (k, v) in [
        ("border", &p.border),
        ("accent", &p.accent),
        ("text", &p.text),
        ("gloss", &p.gloss),
        ("hint", &p.hint),
        ("ghost", &p.ghost),
        ("selected", &p.selected),
        ("match", &p.matched),
    ] {
        s.push_str(&format!("{k} = {v:?}\n"));
    }
    if !p.panel.is_empty() {
        s.push_str(&format!("panel = {:?}\n", p.panel));
    }
    if !p.border_gradient.is_empty() {
        let stops: Vec<String> = p.border_gradient.iter().map(|c| format!("{c:?}")).collect();
        s.push_str(&format!("border-gradient = [{}]\n", stops.join(", ")));
    }
    s
}

/// Resolve a theme by name — the FILE first (T14): `<dir>/<name>.toml` is
/// what the operator edits and what install seeded; the compiled-in
/// builtin is the fallback and regeneration template, never a shadow over
/// an edit. Never fails: any problem returns a working theme plus
/// messages naming it — the operator must be able to tell WHICH theme
/// they are looking at (T3). A broken FILE for a builtin name falls back
/// to that builtin (closer to intent than base), and is never rewritten:
/// mid-edit is its normal cause and live reload its normal observer.
pub fn load(name: &str, themes_dir: Option<&Path>) -> (Theme, Vec<String>) {
    if let Some(dir) = themes_dir {
        let path = dir.join(format!("{name}.toml"));
        if let Ok(src) = std::fs::read_to_string(&path) {
            return match from_toml(name, &src) {
                Ok(t) => (t, Vec::new()),
                Err(mut errs) => match builtin(name) {
                    Some(t) => {
                        errs.push(format!(
                            "theme '{name}': {} rejected — using the built-in (delete the file to regenerate it)",
                            path.display()
                        ));
                        (t, errs)
                    }
                    None => {
                        errs.push(format!("theme '{name}' rejected — using base"));
                        (base(), errs)
                    }
                },
            };
        }
    }
    if let Some(t) = builtin(name) {
        return (t, Vec::new());
    }
    (
        base(),
        vec![format!("theme '{name}' not found — using base")],
    )
}

/// Atomic template write (tmp + rename, the corpus writer's rule): the
/// daemon's reloader and another process's CLI may read while a seed
/// lands, and a torn TOML would parse as a broken theme.
fn seed_file(dir: &Path, t: &Theme) -> bool {
    let _ = std::fs::create_dir_all(dir);
    let tmp = dir.join(format!(".{}.toml.tmp.{}", t.name, std::process::id()));
    if std::fs::write(&tmp, to_toml(t)).is_err() {
        return false;
    }
    std::fs::rename(&tmp, dir.join(format!("{}.toml", t.name))).is_ok()
}

/// `load`, plus the regeneration half of T14: a MISSING file whose name
/// is a builtin is written back from the template before loading, so the
/// file is always the thing actually read and deleting it is the
/// reset-to-default gesture. An existing file is never written, however
/// broken. Best-effort: an unwritable directory just means the builtin
/// serves directly.
pub fn load_or_seed(name: &str, themes_dir: Option<&Path>) -> (Theme, Vec<String>) {
    if let Some(dir) = themes_dir {
        if let Some(t) = builtin(name) {
            if !dir.join(format!("{name}.toml")).exists() {
                seed_file(dir, &t);
            }
        }
    }
    load(name, themes_dir)
}

/// Write every builtin that has no file yet; returns how many were
/// written. `clicue install` calls this so the themes directory is
/// browsable and editable from day one.
pub fn seed_all(dir: &Path) -> usize {
    let mut written = 0;
    for name in builtin_names() {
        if !dir.join(format!("{name}.toml")).exists() {
            if let Some(t) = builtin(name) {
                if seed_file(dir, &t) {
                    written += 1;
                }
            }
        }
    }
    written
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

// ── border gradients ─────────────────────────────────────────────────────

fn parse_hex(s: &str) -> Option<(f32, f32, f32)> {
    let h = s.strip_prefix('#')?;
    if h.len() != 6 {
        return None;
    }
    Some((
        u8::from_str_radix(&h[0..2], 16).ok()? as f32,
        u8::from_str_radix(&h[2..4], 16).ok()? as f32,
        u8::from_str_radix(&h[4..6], 16).ok()? as f32,
    ))
}

/// Piecewise-linear interpolation of the stops across `width` characters,
/// coalesced into ~3-char segments — per-CHARACTER spans would triple the
/// frame for no visible gain at card widths. Offsets are relative to the
/// row start; the caller shifts them. Invalid stops yield no spans (the
/// flat border style stays underneath).
pub fn gradient_segments(stops: &[String], width: usize) -> Vec<(usize, usize, String)> {
    if width == 0 || stops.len() < 2 {
        return Vec::new();
    }
    // Segment size scales with the row so a wide card costs ~24 spans of
    // border, not width/3 — the shim pays ~15µs per span (spec §7a era).
    let seg = (width / 24).max(3);
    let rgb: Option<Vec<(f32, f32, f32)>> = stops.iter().map(|s| parse_hex(s)).collect();
    let Some(rgb) = rgb else { return Vec::new() };
    let mut out: Vec<(usize, usize, String)> = Vec::new();
    let mut start = 0usize;
    while start < width {
        let end = (start + seg).min(width);
        let mid = (start + end - 1) as f32 / 2.0;
        // position in [0,1] along the row, then into the stop list
        let t = if width == 1 {
            0.0
        } else {
            mid / (width - 1) as f32
        };
        let x = t * (rgb.len() - 1) as f32;
        let i = (x.floor() as usize).min(rgb.len() - 2);
        let f = x - i as f32;
        let (r0, g0, b0) = rgb[i];
        let (r1, g1, b1) = rgb[i + 1];
        let (r, g, b) = (
            (r0 + (r1 - r0) * f).round() as u8,
            (g0 + (g1 - g0) * f).round() as u8,
            (b0 + (b1 - b0) * f).round() as u8,
        );
        let style = format!("fg=#{r:02x}{g:02x}{b:02x}");
        // coalesce equal neighbours (flat stretches of the gradient)
        match out.last_mut() {
            Some(last) if last.2 == style => last.1 = end,
            _ => out.push((start, end, style)),
        }
        start = end;
    }
    out
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
/// a list without running a full preview per name. Drawn in the theme's
/// FULL ground (T13): a panel theme's swatch sits on its panel and a
/// gradient theme's border glyphs sweep, exactly as the card will — a
/// black swatch for a solid-blue theme misinforms the one choice the
/// swatch exists to serve.
pub fn swatch(t: &Theme) -> String {
    let p = &t.palette;
    let g = &t.glyphs;
    // (text, style, is_border) — border chars take the per-char gradient.
    let segs: Vec<(String, &str, bool)> = vec![
        (format!("{}{}{}", g.tl, g.h, g.h), &p.border, true),
        (" ".into(), "", false),
        (g.sel.clone(), &p.accent, false),
        (" ".into(), "", false),
        ("gi".into(), &p.matched, false),
        ("t".into(), &p.text, false),
        ("  ".into(), "", false),
        ("the stupid content tracker".into(), &p.gloss, false),
        ("  ".into(), "", false),
        ("t status".into(), &p.ghost, false),
        ("  ".into(), "", false),
        ("Tab cycle".into(), &p.hint, false),
        (" ".into(), "", false),
        (format!("{}{}{}", g.h, g.h, g.tr), &p.border, true),
    ];
    let total: usize = segs.iter().map(|(s, _, _)| s.chars().count()).sum();
    let grads = gradient_segments(&p.border_gradient, total);
    // The renderer's own grounding rule (layout panel merge): the panel's
    // bg under every style that lacks one, and under the bare gaps.
    let bg = p
        .panel
        .split(',')
        .find(|part| part.trim_start().starts_with("bg="))
        .unwrap_or(&p.panel)
        .trim();
    let ground = |style: &str| -> String {
        if p.panel.is_empty() {
            style.to_string()
        } else if style.is_empty() {
            bg.to_string()
        } else if style.contains("bg=") {
            style.to_string()
        } else {
            format!("{style},{bg}")
        }
    };
    let mut out = format!("  {:<16} ", t.name);
    let mut at = 0usize;
    for (text, style, is_border) in &segs {
        if *is_border && !grads.is_empty() {
            for ch in text.chars() {
                let st = grads
                    .iter()
                    .find(|(s, e, _)| at >= *s && at < *e)
                    .map(|(_, _, st)| st.as_str())
                    .unwrap_or(style);
                out.push_str("\x1b[0m");
                out.push_str(&style_to_ansi(&ground(st)));
                out.push(ch);
                at += 1;
            }
        } else {
            out.push_str("\x1b[0m");
            out.push_str(&style_to_ansi(&ground(style)));
            out.push_str(text);
            at += text.chars().count();
        }
    }
    out.push_str("\x1b[0m");
    out
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

    fn temp_themes(tag: &str) -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("clicue-themes-{}-{tag}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        // Parallel tests race bind()'s process-global umask window, which
        // can strip the search bit from a dir created inside it. Assert
        // the mode explicitly rather than trusting creation-time.
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        dir
    }

    #[test]
    fn every_builtin_round_trips_through_its_file() {
        // T14: the file IS the theme — serialization that drops or warps a
        // key would ship every operator a subtly different default.
        for name in builtin_names() {
            let t = builtin(name).unwrap();
            let back = from_toml(name, &to_toml(&t)).unwrap_or_else(|e| {
                panic!("{name}: serialized file failed to parse: {e:?}");
            });
            assert_eq!(back, t, "{name} changed through its own file");
        }
    }

    #[test]
    fn the_file_shadows_the_builtin() {
        let dir = temp_themes("shadow");
        std::fs::write(
            dir.join("aura.toml"),
            "glyph-set = \"unicode-rounded\"\n[palette]\naccent = \"fg=#123456\"\n",
        )
        .unwrap();
        let (t, msgs) = load("aura", Some(&dir));
        assert!(msgs.is_empty());
        assert_eq!(t.palette.accent, "fg=#123456", "edit must win over builtin");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_broken_file_falls_back_to_the_builtin_untouched() {
        // Mid-edit is the broken file's normal cause: fall back to the
        // BUILTIN (closer to intent than base), never rewrite the file.
        let dir = temp_themes("broken");
        let garbage = "glyph-set = \"unicode-rounded\"\n[palette]\naccent = \"\"\n";
        std::fs::write(dir.join("dracula.toml"), garbage).unwrap();
        let (t, msgs) = load("dracula", Some(&dir));
        assert_eq!(t, builtin("dracula").unwrap());
        assert!(!msgs.is_empty(), "the problem must be named");
        assert_eq!(
            std::fs::read_to_string(dir.join("dracula.toml")).unwrap(),
            garbage,
            "a broken file must never be rewritten"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn a_missing_file_regenerates_and_a_second_seed_writes_nothing() {
        let dir = temp_themes("seed");
        let (t, msgs) = load_or_seed("nord", Some(&dir));
        assert!(msgs.is_empty());
        assert_eq!(t, builtin("nord").unwrap());
        let path = dir.join("nord.toml");
        assert!(path.exists(), "deleting the file is reset — it comes back");
        // seed_all tops up the rest and never touches what exists
        let n = seed_all(&dir);
        assert_eq!(n, builtin_names().len() - 1);
        assert_eq!(seed_all(&dir), 0, "second seed writes nothing");
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn swatch_draws_in_the_themes_ground() {
        // T13: agnoster's panel is #00506e — the swatch must carry that bg,
        // and a panel-less theme must carry none.
        let s = swatch(&builtin("agnoster").unwrap());
        assert!(s.contains("48;2;0;80;110"), "panel bg missing: {s:?}");
        let s = swatch(&builtin("aura").unwrap());
        assert!(
            !s.contains("48;2;"),
            "aura has no panel, swatch invented one"
        );
    }

    #[test]
    fn swatch_borders_sweep_when_the_theme_has_a_gradient() {
        let s = swatch(&builtin("chrome").unwrap());
        let fgs: std::collections::HashSet<&str> = s
            .split("38;2;")
            .skip(1)
            .map(|rest| rest.split('m').next().unwrap_or(""))
            .collect();
        assert!(
            fgs.len() >= 5,
            "gradient swatch should carry many distinct fg colours, got {fgs:?}"
        );
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
    #[test]
    fn gradient_segments_interpolate_and_cap() {
        let stops: Vec<String> = vec!["#000000".into(), "#ffffff".into()];
        let segs = gradient_segments(&stops, 30);
        assert!(!segs.is_empty());
        // contiguous, in order, covering the row exactly
        assert_eq!(segs.first().unwrap().0, 0);
        assert_eq!(segs.last().unwrap().1, 30);
        for w in segs.windows(2) {
            assert_eq!(w[0].1, w[1].0, "segments must tile without gaps");
        }
        // dark at the left end, bright at the right
        assert!(segs.first().unwrap().2 < segs.last().unwrap().2);
        // span budget: ~width/3, never per-character
        assert!(segs.len() <= 30 / 3 + 1, "{} segments", segs.len());
        // degenerate inputs stay silent
        assert!(gradient_segments(&[], 30).is_empty());
        assert!(gradient_segments(&["#000000".into()], 30).is_empty());
        assert!(gradient_segments(&["nope".into(), "#ffffff".into()], 30).is_empty());
    }

    #[test]
    fn panel_and_gradient_validate() {
        let mut t = builtin("agnoster").unwrap();
        assert!(validate(&t).is_empty(), "{:?}", validate(&t));
        t.palette.panel = "fg=#ffffff".into();
        assert!(validate(&t).iter().any(|e| e.contains("panel")));
        let mut c = builtin("chrome").unwrap();
        assert!(validate(&c).is_empty(), "{:?}", validate(&c));
        c.palette.border_gradient = vec!["#123".into(), "#ffffff".into()];
        assert!(validate(&c).iter().any(|e| e.contains("border-gradient")));
    }

    #[test]
    fn every_builtin_loads_clean_and_previews() {
        for name in builtin_names() {
            let t = builtin(name).expect(name);
            assert!(validate(&t).is_empty(), "{name}: {:?}", validate(&t));
            assert!(!preview(&t, 80).is_empty(), "{name} preview");
        }
    }
}
