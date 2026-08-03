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

/// Every shipped theme except `base`, authored as the SAME TOML the
/// operator edits and embedded at compile time — one representation per
/// theme (T14). `base` alone stays in code: the fallback contract cannot
/// depend on the parser it backstops. A test pins every entry as parsing
/// and validating clean.
const EMBEDDED: &[(&str, &str)] = &[
    ("aura", include_str!("../themes/aura.toml")),
    ("base", include_str!("../themes/base.toml")),
    ("mono", include_str!("../themes/mono.toml")),
    ("plain", include_str!("../themes/plain.toml")),
    ("monokai", include_str!("../themes/monokai.toml")),
    ("dracula", include_str!("../themes/dracula.toml")),
    ("nord", include_str!("../themes/nord.toml")),
    ("gruvbox", include_str!("../themes/gruvbox.toml")),
    ("solarized", include_str!("../themes/solarized.toml")),
    (
        "solarized-light",
        include_str!("../themes/solarized-light.toml"),
    ),
    ("tokyo-night", include_str!("../themes/tokyo-night.toml")),
    ("catppuccin", include_str!("../themes/catppuccin.toml")),
    ("agnoster", include_str!("../themes/agnoster.toml")),
    ("chrome", include_str!("../themes/chrome.toml")),
    ("solid-metal", include_str!("../themes/solid-metal.toml")),
    ("valentine", include_str!("../themes/valentine.toml")),
    ("halloween", include_str!("../themes/halloween.toml")),
];

/// The embedded template text for a shipped theme name.
pub fn template(name: &str) -> Option<&'static str> {
    EMBEDDED.iter().find(|(n, _)| *n == name).map(|(_, t)| *t)
}

/// A shipped theme, parsed from its embedded template. `base` is special:
/// the coded contract answers even if parsing itself were broken.
pub fn builtin(name: &str) -> Option<Theme> {
    if name == "base" {
        return Some(base());
    }
    template(name).and_then(|src| from_toml(name, src).ok())
}

pub fn builtin_names() -> Vec<&'static str> {
    let mut names: Vec<&'static str> = EMBEDDED.iter().map(|(n, _)| *n).collect();
    names.sort_unstable();
    names
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

/// Resolve a theme by name — the FILE first (T14): `<dir>/<name>.toml` is
/// what the operator edits and what install seeded; the embedded template
/// is the fallback and regeneration source, never a shadow over an edit.
/// Never fails: any problem returns a working theme plus messages naming
/// it — the operator must be able to tell WHICH theme they are looking at
/// (T3). A broken FILE for a shipped name falls back to that shipped
/// theme (closer to intent than base), and is never rewritten: mid-edit
/// is its normal cause and live reload its normal observer.
pub fn load(name: &str, themes_dir: Option<&Path>) -> (Theme, Vec<String>) {
    if let Some(dir) = themes_dir {
        let path = dir.join(format!("{name}.toml"));
        match std::fs::read_to_string(&path) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                // An unreadable file (EACCES, EISDIR…) is broken in every
                // sense that matters to the operator: the edits they make
                // to it have no effect, so the fallback must be NAMED
                // exactly like a parse failure (review #21).
                let mut errs = vec![format!(
                    "theme '{name}': {} unreadable ({e})",
                    path.display()
                )];
                return match builtin(name) {
                    Some(t) => {
                        errs.push(format!("'{name}': using the built-in"));
                        (t, errs)
                    }
                    None => {
                        errs.push(format!("'{name}': using base"));
                        (base(), errs)
                    }
                };
            }
            Ok(src) => {
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
                }
            }
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

/// Provenance line a seeded file opens with, and the fingerprint line it
/// closes with. The fingerprint (FNV-1a over everything above it) is the
/// pristine test: intact means never hand-edited, WHATEVER clicue version
/// wrote it — which is what lets `clicue install` update old unedited
/// files without being able to reconstruct old templates. The version is
/// for humans and reporting; it decides nothing.
const SEED_PREFIX: &str = "# seeded by clicue v";
const FINGERPRINT_PREFIX: &str = "# template-fingerprint: ";

fn fnv64(bytes: &[u8]) -> u64 {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    h
}

/// What a seeded file contains for this template, today.
fn seeded_content(template: &str) -> String {
    let body = format!("{SEED_PREFIX}{}\n{template}", env!("CARGO_PKG_VERSION"));
    format!(
        "{body}{FINGERPRINT_PREFIX}{:016x}\n",
        fnv64(body.as_bytes())
    )
}

/// Everything above the fingerprint line, and the fingerprint if present.
fn split_fingerprint(content: &str) -> (String, Option<u64>) {
    let mut body = String::new();
    let mut fp = None;
    for line in content.lines() {
        if let Some(hex) = line.strip_prefix(FINGERPRINT_PREFIX) {
            fp = u64::from_str_radix(hex.trim(), 16).ok();
        } else {
            body.push_str(line);
            body.push('\n');
        }
    }
    (body, fp)
}

/// Intact fingerprint = never hand-edited. Version-independent: an old
/// binary's seed passes under a new binary, which is the whole point.
pub fn is_pristine(content: &str) -> bool {
    let (body, fp) = split_fingerprint(content);
    fp == Some(fnv64(body.as_bytes()))
}

/// The template portion of a seeded file: body minus the seed header.
fn seeded_template(content: &str) -> String {
    let (body, _) = split_fingerprint(content);
    body.lines()
        .filter(|l| !l.starts_with(SEED_PREFIX))
        .map(|l| format!("{l}\n"))
        .collect()
}

/// Atomic seed write (tmp + rename, the corpus writer's rule): the
/// daemon's reloader and another process's CLI may read while a seed
/// lands, and a torn TOML would parse as a broken theme.
fn seed_file(dir: &Path, name: &str, template: &str) -> bool {
    let _ = std::fs::create_dir_all(dir);
    let tmp = dir.join(format!(".{name}.toml.tmp.{}", std::process::id()));
    if std::fs::write(&tmp, seeded_content(template)).is_err() {
        return false;
    }
    let ok = std::fs::rename(&tmp, dir.join(format!("{name}.toml"))).is_ok();
    if !ok {
        // Debris in a directory operators browse and the reloader watches.
        let _ = std::fs::remove_file(&tmp);
    }
    ok
}

/// `load`, plus the regeneration half of T14: a MISSING file whose name
/// is a shipped theme is written back from the template before loading,
/// so the file is always the thing actually read and deleting it is the
/// reset-to-default gesture. An existing file is never written, however
/// broken. Best-effort: an unwritable directory just means the embedded
/// template serves directly.
pub fn load_or_seed(name: &str, themes_dir: Option<&Path>) -> (Theme, Vec<String>) {
    if let Some(dir) = themes_dir {
        if let Some(tpl) = template(name) {
            if !dir.join(format!("{name}.toml")).exists() {
                seed_file(dir, name, tpl);
            }
        }
    }
    load(name, themes_dir)
}

/// What one `clicue install` (or reinstall) did to the themes directory.
#[derive(Debug, Default, PartialEq, Eq)]
pub struct SyncReport {
    /// Written where no file existed (first install, or restoring a
    /// mistaken deletion — reinstall is the recovery gesture).
    pub seeded: usize,
    /// Unedited files rewritten to the current template.
    pub updated: usize,
    /// Hand-edited files left exactly as they are.
    pub kept: usize,
}

/// Bring the themes directory up to this binary's templates: seed what is
/// missing, update what is pristine, keep every edit (T14).
pub fn sync_all(dir: &Path) -> SyncReport {
    let mut r = SyncReport::default();
    for (name, tpl) in EMBEDDED {
        let path = dir.join(format!("{name}.toml"));
        match std::fs::read_to_string(&path) {
            Err(_) => {
                if seed_file(dir, name, tpl) {
                    r.seeded += 1;
                }
            }
            Ok(existing) => {
                if !is_pristine(&existing) {
                    r.kept += 1;
                } else if seeded_template(&existing) != *tpl && seed_file(dir, name, tpl) {
                    // Template changed (not merely the version line):
                    // an unedited file follows the binary.
                    r.updated += 1;
                }
            }
        }
    }
    r
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
                        // Editor artifacts are dotfiles with our extension
                        // (emacs lock `.#aura.toml` stems to `.#aura`) —
                        // live editing must not mint themes (review #21).
                        if stem.starts_with('.') {
                            continue;
                        }
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
/// Piecewise-linear interpolation along parsed stops at t ∈ [0,1].
fn lerp_stops(rgb: &[(f32, f32, f32)], t: f32) -> String {
    let x = t.clamp(0.0, 1.0) * (rgb.len() - 1) as f32;
    let i = (x.floor() as usize).min(rgb.len() - 2);
    let f = x - i as f32;
    let (r0, g0, b0) = rgb[i];
    let (r1, g1, b1) = rgb[i + 1];
    let (r, g, b) = (
        (r0 + (r1 - r0) * f).round() as u8,
        (g0 + (g1 - g0) * f).round() as u8,
        (b0 + (b1 - b0) * f).round() as u8,
    );
    format!("fg=#{r:02x}{g:02x}{b:02x}")
}

/// Colour at position t along the stop list — the same interpolation
/// gradient_segments applies, exposed for consumers that sample by
/// ordinal rather than row position (the swatch, T13: six border glyphs
/// carry the whole sweep compressed, or they carry only its dark ends).
pub(crate) fn gradient_at(stops: &[String], t: f32) -> Option<String> {
    if stops.len() < 2 {
        return None;
    }
    let rgb: Option<Vec<(f32, f32, f32)>> = stops.iter().map(|s| parse_hex(s)).collect();
    Some(lerp_stops(&rgb?, t))
}

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
        let style = lerp_stops(&rgb, t);
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
    // The gradient sampled by BORDER ORDINAL, not row position (T13): the
    // swatch's border is six glyphs in a sixty-column line, and indexing
    // by row position samples only t≈0 and t≈1 — three near-identical
    // dark greys where the theme's whole point is the bright mid-sweep
    // (review #21, measured). Six glyphs carry the sweep compressed; the
    // card's own border rows span the full width and need no compression.
    let nborder: usize = segs
        .iter()
        .filter(|(_, _, b)| *b)
        .map(|(s, _, _)| s.chars().count())
        .sum();
    // The renderer's own grounding rule (layout panel merge): the panel's
    // bg under every style that lacks one, and under the bare gaps. (The
    // renderer lays the WHOLE panel string as the base span; only the
    // bg= part matters here because every shipped panel is a lone bg= —
    // a panel carrying extra attributes would ground the card, not the
    // swatch gaps.)
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
    // Operator file stems become theme names: strip control characters
    // (an escape sequence in a filename must not reach the terminal raw)
    // and pad by COLUMNS, the T6 discipline.
    let name: String = t.name.chars().filter(|c| !c.is_control()).collect();
    let pad = 17usize.saturating_sub(cols(&name)).max(1);
    let mut out = format!("  {name}{}", " ".repeat(pad));
    let mut bi = 0usize;
    for (text, style, is_border) in &segs {
        if *is_border && p.border_gradient.len() >= 2 {
            for ch in text.chars() {
                let tpos = if nborder <= 1 {
                    0.0
                } else {
                    bi as f32 / (nborder - 1) as f32
                };
                let st = gradient_at(&p.border_gradient, tpos).unwrap_or_else(|| style.to_string());
                out.push_str("\x1b[0m");
                out.push_str(&style_to_ansi(&ground(&st)));
                out.push(ch);
                bi += 1;
            }
        } else {
            out.push_str("\x1b[0m");
            out.push_str(&style_to_ansi(&ground(style)));
            out.push_str(text);
            if *is_border {
                bi += text.chars().count();
            }
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
    fn every_embedded_template_parses_and_validates() {
        // T14: the template IS the theme — an embedded file that fails to
        // parse would ship a theme that silently degrades to base.
        for (name, src) in EMBEDDED {
            let t = from_toml(name, src)
                .unwrap_or_else(|e| panic!("{name}: embedded template broken: {e:?}"));
            assert!(validate(&t).is_empty(), "{name} failed validation");
        }
    }

    #[test]
    fn coded_base_and_its_template_agree() {
        // base is the one theme in code (the fallback contract cannot
        // depend on the parser it backstops) — its template must not
        // drift from it.
        let t = from_toml("base", template("base").unwrap()).unwrap();
        assert_eq!(
            t,
            base(),
            "themes/base.toml drifted from the coded contract"
        );
    }

    #[test]
    fn seeded_files_regenerate_update_and_respect_edits() {
        let dir = temp_themes("sync");
        // A missing file regenerates on load (delete = reset).
        let (t, msgs) = load_or_seed("nord", Some(&dir));
        assert!(msgs.is_empty());
        assert_eq!(t, builtin("nord").unwrap());
        let path = dir.join("nord.toml");
        let seeded = std::fs::read_to_string(&path).unwrap();
        assert!(is_pristine(&seeded), "fresh seed must self-verify");
        assert!(seeded.starts_with(SEED_PREFIX), "provenance line missing");
        // sync tops up the rest, touches nothing twice.
        let r = sync_all(&dir);
        assert_eq!(r.seeded, EMBEDDED.len() - 1);
        assert_eq!(
            sync_all(&dir),
            SyncReport::default(),
            "second sync is a no-op"
        );
        // An OLD pristine seed (different template, intact fingerprint)
        // updates — the version-skew case a byte-compare cannot handle.
        let old_body = format!("{SEED_PREFIX}0.0.1\n# some previous template\n");
        let old = format!(
            "{old_body}{FINGERPRINT_PREFIX}{:016x}\n",
            fnv64(old_body.as_bytes())
        );
        std::fs::write(&path, &old).unwrap();
        let r = sync_all(&dir);
        assert_eq!((r.updated, r.kept), (1, 0), "pristine old seed must update");
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            seeded_content(template("nord").unwrap())
        );
        // An EDIT (fingerprint broken) is kept, forever.
        let edited = seeded.replace("#81a1c1", "#123456");
        std::fs::write(&path, &edited).unwrap();
        assert!(!is_pristine(&edited));
        let r = sync_all(&dir);
        assert_eq!((r.updated, r.kept), (0, 1), "edited file must be kept");
        assert_eq!(std::fs::read_to_string(&path).unwrap(), edited);
        let _ = std::fs::remove_dir_all(&dir);
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
    fn gradient_swatch_carries_the_whole_sweep() {
        // Review #21: indexing by row position sampled only the dark ends
        // (t≈0.02, t≈0.99) — the bright mid-sweep, the theme's point,
        // never appeared. Pinned per glyph: border glyph i of 6 must wear
        // exactly the colour at t = i/5.
        let t = builtin("chrome").unwrap();
        let s = swatch(&t);
        for i in 0..6 {
            let tpos = i as f32 / 5.0;
            let expect = style_to_ansi(&gradient_at(&t.palette.border_gradient, tpos).unwrap());
            assert!(
                s.contains(&expect),
                "border glyph {i} missing its sweep colour {expect:?} in {s:?}"
            );
        }
    }

    #[test]
    fn an_unreadable_file_is_named_not_silently_shadowed() {
        // Review #21: EACCES fell through to the builtin with no message —
        // the operator edits a file that has no effect and is told nothing.
        use std::os::unix::fs::PermissionsExt;
        let dir = temp_themes("perm");
        let path = dir.join("nord.toml");
        std::fs::write(&path, "x = 1\n").unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o000)).unwrap();
        let (t, msgs) = load("nord", Some(&dir));
        assert_eq!(t, builtin("nord").unwrap());
        assert!(!msgs.is_empty(), "the problem must be named");
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn editor_artifacts_are_not_themes() {
        // Review #21, measured: emacs lock `.#aura.toml` stems to `.#aura`
        // and passed the extension filter into the theme list.
        let dir = temp_themes("locks");
        std::fs::write(dir.join(".#aura.toml"), "junk").unwrap();
        let names = available(Some(&dir));
        assert!(
            names.iter().all(|n| !n.starts_with('.')),
            "artifact minted a theme: {names:?}"
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn base_is_terminal_default_not_aura() {
        // T4: the prototype shipped a base byte-identical to aura's hexes.
        let b = base();
        assert!(!b.palette.border.contains('#'));
        assert_ne!(b.palette, builtin("aura").unwrap().palette);
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
