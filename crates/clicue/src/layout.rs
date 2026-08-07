//! The card — candidates and explanations become lines plus spans.
//!
//! Contract: spec/card-layout.md, extracted from prototype/lib/render.zsh.
//! Every width here is terminal COLUMNS via unicode-width — the wide-glyph
//! fix the spec opens with. Spans are CHARACTER offsets into the card text:
//! zsh's region_highlight is character-indexed, so the daemon converts and
//! the shim stays dumb. This deliberately supersedes the byte rule that
//! protocol spans inherited from frame sizing; integration owns the note.

use unicode_width::{UnicodeWidthChar, UnicodeWidthStr};

use crate::model::{Cue, ExplainRow, Kind, Mode};
use crate::theme::Theme;

// ── inputs ───────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Copy)]
pub struct Dims {
    pub cols: u16,
    pub lines: u16,
}

/// W5: below this many columns the card stops being a UI — the legend
/// loses its primary gesture and the column arithmetic scrambles. A
/// literal, not a percentage: 10% of an 80-column terminal is not a card.
/// Both width bounds floor here; only the terminal itself may go lower.
pub const MIN_CARD_COLS: usize = 34;

/// A width bound the operator can state either way: absolute columns, or
/// a percentage of the terminal (W2/W5).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WidthBound {
    Cols(usize),
    Pct(u8),
}

impl WidthBound {
    pub fn resolve(&self, cols: usize) -> usize {
        match self {
            WidthBound::Cols(n) => *n,
            WidthBound::Pct(p) => cols * (*p as usize) / 100,
        }
    }
    /// `"60%"` or `"96"`; percentages must land in 1–100, columns ≥ 1
    /// (same rule as the integer TOML spelling — `"0"` must not slip in
    /// as a string and then display as though honoured).
    pub fn parse(s: &str) -> Option<WidthBound> {
        if let Some(pct) = s.trim().strip_suffix('%') {
            let v: u8 = pct.trim().parse().ok()?;
            (1..=100).contains(&v).then_some(WidthBound::Pct(v))
        } else {
            s.trim()
                .parse()
                .ok()
                .filter(|n| *n >= 1)
                .map(WidthBound::Cols)
        }
    }
}

impl std::fmt::Display for WidthBound {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WidthBound::Cols(n) => f.pad(&n.to_string()),
            WidthBound::Pct(p) => f.pad(&format!("{p}%")),
        }
    }
}

/// Operator preferences (the zstyles of the prototype).
#[derive(Debug, Clone)]
pub struct LayoutCfg {
    /// H4: fixed cue count for tier 1.
    pub tier1_rows: usize,
    /// W5: the card never shrinks below this, so short content still
    /// presents as a stable card rather than a sliver.
    pub min_width: WidthBound,
    /// W2: a cap, not a target.
    pub max_width: WidthBound,
    /// H2: None = auto (`LINES − 6`).
    pub max_lines: Option<usize>,
    /// H5: None = auto (clamped to a third of the window).
    pub tier2_rows: Option<usize>,
}

impl Default for LayoutCfg {
    fn default() -> Self {
        LayoutCfg {
            tier1_rows: 10,
            min_width: WidthBound::Pct(30),
            max_width: WidthBound::Cols(120),
            max_lines: None,
            tier2_rows: None,
        }
    }
}

/// L2: legend labels come from what is actually bound; the daemon builds
/// these from the shim's reported bindings, not from constants.
#[derive(Debug, Clone)]
pub struct KeyLabels {
    pub accept: String,
    pub dismiss: String,
    pub maximize: String,
    pub expand: String,
}

impl Default for KeyLabels {
    fn default() -> Self {
        KeyLabels {
            accept: "Tab".into(),
            dismiss: "Esc".into(),
            maximize: "Alt+M".into(),
            expand: "Alt+E".into(),
        }
    }
}

/// Window state the prototype kept in globals. Mutated by render: the
/// selection is clamped and the windows slide to keep it visible (S3).
#[derive(Debug, Clone)]
pub struct View {
    /// 1-based selection across the WHOLE candidate list.
    pub sel: usize,
    pub top1: usize,
    pub top2: usize,
    pub gridtop: usize,
    /// H6: the operator's per-line "give me the whole window".
    pub maxed: bool,
}

impl Default for View {
    fn default() -> Self {
        View {
            sel: 1,
            top1: 1,
            top2: 0,
            gridtop: 0,
            maxed: false,
        }
    }
}

impl View {
    /// Selection reset on a changed buffer; `maxed` survives — the reason
    /// to maximise is the list, and that survives a keystroke (H6).
    pub fn reset(&mut self) {
        *self = View {
            maxed: self.maxed,
            ..View::default()
        };
    }
}

/// Everything the renderer reads. The daemon's state machine fills this;
/// layout decides nothing about WHAT to show, only HOW. Copy (all fields
/// are references or scalars) so the width pass can pose what-if variants
/// (W6's worst-case legend) without a builder.
#[derive(Debug, Clone, Copy)]
pub struct CardInput<'a> {
    pub cues: &'a [Cue],
    pub explain: &'a [ExplainRow],
    pub mode: Mode,
    pub prefix: &'a str,
    /// Informational card: not a candidate list (prototype `_clicue_info`).
    pub info: bool,
    /// The typed option prefix matched nothing; the whole set is shown and
    /// the label says so (sources spec, two-pass relaxation).
    pub argnomatch: bool,
    /// Tab has been pressed; arrows and Enter belong to the card (L5).
    pub engaged: bool,
    /// E3 collapse gate — the daemon computed the familiarity percentile.
    pub familiar: bool,
    /// The operator opened a collapsed explanation (sticky per line).
    pub expanded: bool,
    /// L6: MUST be the same predicate the key dispatch reads.
    pub tab_inserts: bool,
    /// Ghost stem decided by the daemon (GH1 precedence lives there);
    /// layout only advertises `→ accept` when one exists (L7).
    pub ghost: &'a str,
    /// The "you are here" pane for a navigational command (design note
    /// navigation-and-place.md); None for every other card.
    pub nav: Option<&'a crate::nav::NavPane>,
    /// The symmetric "you are going" pane: the same rings drawn around
    /// the RESOLVED destination. Never present without `nav`.
    pub nav_going: Option<&'a crate::nav::NavPane>,
    /// Names the place whose children fill the grid ("inside ~/x") for
    /// navigational commands; the generic counters otherwise.
    pub grid_label: Option<&'a str>,
    /// E5 footer: `run N× · top P% · age`, empty for none.
    pub invnote: &'a str,
    pub dims: Dims,
    pub cfg: &'a LayoutCfg,
    pub keys: &'a KeyLabels,
}

// ── outputs ──────────────────────────────────────────────────────────────

/// G5: published so the paging keys move by exactly the visible page.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Grid {
    pub page: usize,
    pub lo: usize,
    pub hi: usize,
    pub rows: usize,
    pub cols: usize,
}

/// Character-offset span into [`Card::text`].
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Span {
    pub start: usize,
    pub end: usize,
    pub style: String,
}

#[derive(Debug)]
pub struct Card {
    /// Leading newline + lines joined with newlines, exactly what the shim
    /// appends to POSTDISPLAY (SP1).
    pub text: String,
    pub spans: Vec<Span>,
    pub grid: Option<Grid>,
    /// S2: derived, not toggled — 2 means the grid holds the selection.
    pub focus: u8,
    /// H6: whether maximize would change anything (legend gates on it).
    pub canmax: bool,
    /// Tier-1 cue count, the key layer's page fallback before a grid exists.
    pub tier1_count: usize,
}

// ── column helpers ───────────────────────────────────────────────────────

fn wcols(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

/// Hard truncation to at most `w` columns (names: a clipped name is
/// legible, a wrapped card is not — C2).
fn fit_hard(s: &str, w: usize) -> String {
    let mut out = String::new();
    let mut used = 0;
    for ch in s.chars() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > w {
            break;
        }
        out.push(ch);
        used += cw;
    }
    out
}

/// C4: glosses ellipsise — `…` replaces the last kept column.
fn fit_ellipsis(s: &str, w: usize) -> String {
    if wcols(s) <= w {
        return s.to_string();
    }
    if w == 0 {
        return String::new();
    }
    let mut out = fit_hard(s, w - 1);
    out.push('…');
    out
}

/// Front-ellipsis: keep the TAIL. For breadcrumbs and paths the deep end
/// is the informative one — `… › app › clicue` orients, `~ › Projects …`
/// does not.
fn fit_tail(s: &str, w: usize) -> String {
    if wcols(s) <= w {
        return s.to_string();
    }
    if w == 0 {
        return String::new();
    }
    let budget = w - 1;
    let mut used = 0;
    let mut start = s.len();
    for (i, ch) in s.char_indices().rev() {
        let cw = UnicodeWidthChar::width(ch).unwrap_or(0);
        if used + cw > budget {
            break;
        }
        used += cw;
        start = i;
    }
    format!("…{}", &s[start..])
}

fn pad_to(mut s: String, w: usize) -> String {
    let c = wcols(&s);
    if c < w {
        s.push_str(&" ".repeat(w - c));
    }
    s
}

/// C5: a label that outgrows the box is silently clipped to `inner − 1` —
/// a clipped label reads, a wrapped card does not.
fn fit_label(lbl: &str, inner: usize) -> String {
    if wcols(lbl) > inner.saturating_sub(1) {
        let keep = inner.saturating_sub(2).max(1);
        let mut l = fit_hard(lbl, keep);
        l.push(' ');
        return l;
    }
    lbl.to_string()
}

// ── row assembly ─────────────────────────────────────────────────────────
// Each line knows its own span structure at emission: SP4 — the daemon
// carries row types structurally, never re-derives them from text.

struct Row {
    line: String,
    chars: usize,
    spans: Vec<(usize, usize, String)>,
}

impl Row {
    fn new() -> Self {
        Row {
            line: String::new(),
            chars: 0,
            spans: Vec::new(),
        }
    }
    fn push(&mut self, s: &str, style: Option<&str>) {
        let start = self.chars;
        let n = s.chars().count();
        self.line.push_str(s);
        self.chars += n;
        if let Some(st) = style {
            if n > 0 {
                self.spans.push((start, start + n, st.to_string()));
            }
        }
    }
    /// SP3: the selected tier-1 row is highlighted whole; appended last so
    /// it wins over the segment styling underneath.
    fn overlay(&mut self, style: &str) {
        self.spans.push((0, self.chars, style.to_string()));
    }
}

/// Fill `cols` columns by cycling the rule pattern's chars — each char is
/// validated to one column, so char count IS column count (ADR-400). A
/// 1-char h degenerates to the old `repeat`.
fn hfill(h: &str, cols: usize) -> String {
    h.chars().cycle().take(cols).collect()
}

/// Columns a corner pair overhangs beyond the two 1-column `v` positions
/// the body rows put under them — the rule absorbs it (ADR-400).
fn overhang(l: &str, r: &str) -> usize {
    wcols(l).saturating_sub(1) + wcols(r).saturating_sub(1)
}

/// A 1-column stand-in for a ramp: its first 1-column char keeps the
/// theme's texture; `+` (the base corner) if the ramp has none.
fn one_col(s: &str) -> String {
    s.chars()
        .find(|c| UnicodeWidthChar::width(*c).unwrap_or(0) == 1)
        .map(String::from)
        .unwrap_or_else(|| "+".into())
}

/// The validator's 8-column cap keeps the rule ≥1 at the card FLOOR, but
/// W3 lets the terminal itself squeeze below it — there a full ramp
/// would overflow the row (review #35, measured: 8-col corners scramble
/// an 18-column tmux slice). Same never-break posture as the theme
/// loader: degrade the pair to 1-column stand-ins, never overflow.
fn fit_corners<'a>(l: &'a str, r: &'a str, inner: usize) -> (String, String) {
    if overhang(l, r) > inner.saturating_sub(3) {
        (one_col(l), one_col(r))
    } else {
        (l.to_string(), r.to_string())
    }
}

fn border_row(inner: usize, label: &str, l: &str, r: &str, h: &str, t: &Theme) -> Row {
    let (l, r) = fit_corners(l, r, inner);
    let over = overhang(&l, &r);
    let label = fit_label(label, inner.saturating_sub(over));
    let rule = inner.saturating_sub(wcols(&label) + over).max(1);
    let mut row = Row::new();
    row.push(&l, None);
    row.push(&label, None);
    row.push(&hfill(h, rule), None);
    row.push(&r, None);
    border_overlay(&mut row, t);
    row
}

/// Flat border style, or the theme's gradient swept across the row —
/// segment spans land AFTER the flat overlay, so region_highlight's
/// last-wins stacking shows the gradient with the flat colour as the
/// fallback for anything the segments miss. The sweep is positioned by
/// CHAR count (`row.chars`, what region_highlight indexes); multi-char
/// corners make it drift a few chars from column-true — invisible at
/// card widths (ADR-400).
fn border_overlay(row: &mut Row, t: &Theme) {
    row.overlay(&t.palette.border);
    for (s, e, style) in crate::theme::gradient_segments(&t.palette.border_gradient, row.chars) {
        row.spans.push((s, e, style));
    }
}

// ── the legend ───────────────────────────────────────────────────────────

/// L1: derived from live state on every render; only real gestures.
fn legend(
    input: &CardInput,
    maxed: bool,
    focus: u8,
    grid: Option<Grid>,
    canmax: bool,
) -> Vec<String> {
    let acc = &input.keys.accept;
    let dis = &input.keys.dismiss;
    let dismiss = format!("{dis} dismiss");

    // L3: nothing here answers to an arrow.
    if input.cues.is_empty() || (input.info && input.explain.is_empty()) {
        return vec![dismiss];
    }

    // L4: the grid is a different legend because the keys mean different
    // things there — all four arrows navigate, none touches the ghost.
    if focus == 2 {
        let mut segs = vec!["←→↑↓ navigate".to_string()];
        if let Some(gd) = grid {
            if gd.page > 0 && input.cues.len() - gd.lo + 1 > gd.page {
                segs.push("PgUp/PgDn page".into());
            }
        }
        segs.push("Home/End ends".into());
        if canmax || maxed {
            let dir = if maxed { "shorter" } else { "taller" };
            segs.push(format!("{} {dir}", input.keys.maximize));
        }
        segs.push("⏎ insert".into());
        segs.push(dismiss);
        return segs;
    }

    // L5: gestures that only work once engaged are only advertised then.
    let engaged_insert = input.engaged.then(|| "⏎ insert".to_string());

    // L6: same predicate the key dispatch reads.
    if input.tab_inserts {
        let mut segs = vec![format!("{acc} insert")];
        segs.extend(engaged_insert);
        segs.push(dismiss);
        return segs;
    }

    let mut segs = vec![format!("{acc} cycle")];
    if input.engaged && input.cues.len() > 1 {
        segs.push("↑↓ browse".into());
    }
    if !input.ghost.is_empty() {
        segs.push("→ accept".into()); // L7
    }
    segs.extend(engaged_insert);
    segs.push(dismiss);
    segs
}

/// L8: segments drop from the MIDDLE — the primary gesture and the escape
/// hatch survive any width; at absurd widths the last segment truncates
/// rather than the line overflowing.
fn fit_legend(segs: &[String], avail: usize) -> String {
    let join = |parts: &[String]| format!(" {} ", parts.join(" · "));
    let full = join(segs);
    if wcols(&full) <= avail {
        return full;
    }
    let last = segs.len() - 1;
    for n in (1..last).rev() {
        let mut keep: Vec<String> = segs[..n].to_vec();
        keep.push(segs[last].clone());
        let t = join(&keep);
        if wcols(&t) <= avail {
            return t;
        }
    }
    let t = format!(" {} ", segs[last]);
    if wcols(&t) <= avail {
        return t;
    }
    format!(
        " {} ",
        fit_hard(&segs[last], avail.saturating_sub(2).max(1))
    )
}

// ── selection ────────────────────────────────────────────────────────────

/// S3 in ONE place: clamp the selection, slide whichever window holds it.
/// The prototype hit divergence between four copies of this arithmetic;
/// keys.zsh:139-140 records the workaround this fixes properly.
fn clamp_selection(view: &mut View, total: usize, t1n: usize, r1: usize, r2: usize) {
    if view.sel < 1 {
        view.sel = 1;
    }
    if view.sel > total {
        view.sel = total;
    }
    if view.sel <= t1n {
        if view.sel < view.top1 {
            view.top1 = view.sel;
        }
        let r1 = r1.max(1);
        if view.sel + 1 > view.top1 + r1 {
            view.top1 = view.sel + 1 - r1;
        }
        if view.top1 < 1 {
            view.top1 = 1;
        }
    } else {
        if view.top2 < t1n + 1 {
            view.top2 = t1n + 1;
        }
        if view.sel < view.top2 {
            view.top2 = view.sel;
        }
        let r2 = r2.max(1);
        if view.sel + 1 > view.top2 + r2 {
            view.top2 = view.sel + 1 - r2;
        }
    }
}

fn kind_glyph<'t>(cue: &Cue, mode: Mode, theme: &'t Theme) -> &'t str {
    // K1: argument position distinguishes flag vs subcommand by spelling;
    // command position names only reliably-known kinds.
    if mode == Mode::Arg {
        return if cue.insert.starts_with('-') {
            &theme.glyphs.k_flag
        } else {
            &theme.glyphs.k_sub
        };
    }
    match cue.kind {
        Kind::Alias => &theme.glyphs.k_alias,
        Kind::Function => &theme.glyphs.k_function,
        Kind::Builtin => &theme.glyphs.k_builtin,
        Kind::System => &theme.glyphs.k_system,
        Kind::Arg => &theme.glyphs.k_none,
    }
}

// ── the renderer ─────────────────────────────────────────────────────────

pub fn render(input: &CardInput, view: &mut View, theme: &Theme) -> Option<Card> {
    let cues = input.cues;
    let explain = input.explain;
    let total = cues.len();

    // S6: an explanation alone justifies the card; so does place.
    if total == 0 && explain.is_empty() && input.nav.is_none() {
        return None;
    }

    let g = &theme.glyphs;
    let p = &theme.palette;

    let cols = input.dims.cols as usize;

    // H2: height budget; window cap applied AFTER the floor.
    let lines = input.dims.lines as usize;
    let vfit = lines.saturating_sub(6);
    let mut maxlines = input.cfg.max_lines.unwrap_or(vfit).max(8);
    maxlines = maxlines.min(vfit.max(5));
    maxlines = maxlines.max(5);

    // H4/H5/H6: tier sizes.
    let t1rows = input.cfg.tier1_rows.max(1);
    let spare = lines.saturating_sub(t1rows + 10);
    let (mut t2rows, canmax) = match input.cfg.tier2_rows {
        Some(n) => (n, false),
        None => {
            let clamped = (lines / 3).max(10).min(spare.max(1));
            let canmax = spare > clamped;
            (if view.maxed { spare } else { clamped }, canmax)
        }
    };
    t2rows = t2rows.max(2);

    let t1n = t1rows.min(total);
    let focus: u8 = if view.sel > t1n && t1n < total { 2 } else { 1 };

    // H1/H3: both boxes divide one enforced budget; grid gives up first.
    let (mut r1, mut r2) = if total > t1n {
        (t1rows, t2rows)
    } else {
        (t1rows + t2rows + 1, 0)
    };
    let over = (r1 + r2 + 5) as isize - maxlines as isize;
    if over > 0 {
        let cut = (over as usize).min(r2);
        r2 -= cut;
        let rest = over as usize - cut;
        if rest > 0 {
            r1 = r1.saturating_sub(rest).max(1);
        }
    }

    if total > 0 {
        clamp_selection(view, total, t1n, r1, r2);
    }

    // S5: the explanation is budgeted first, out of the grid's share.
    let mut er = 0usize;
    if !explain.is_empty() {
        er = explain.len();
        let ecap = maxlines.saturating_sub(t1n + 5).max(1);
        er = er.min(ecap);
    }
    // r2 is the enforced share for EVERYTHING below tier 1 (H1); its
    // tenants are the explanation (budgeted first, S5), the place panes,
    // and the grid, in that order. Panes fit WHOLE or not at all — a
    // clipped pane reads as a broken card — and the going pane is a
    // FIXED shape (border + 4 body rows, padded blank) because attention
    // retargets it within one buffer, and a pane that changes height
    // with the selection is H7's exact hazard [MEASURED: a 24-line pty
    // pushed the legend off-screen as the preview grew; pane rows also
    // leaked past the budget entirely and clipped the card's bottom].
    // In one-box mode (no grid) r1 carries the whole share and holds
    // only t1n cue rows — the surplus belongs to the panes exactly as
    // r2 does when the grid exists.
    let mut avail = r1.saturating_sub(t1n) + r2;
    avail = avail.saturating_sub(er + usize::from(er > 0));
    let pane_rows = |n: &crate::nav::NavPane| {
        1 + usize::from(!n.breadcrumb.is_empty())
            + n.stack.len().min(4)
            + usize::from(n.stack.len() > 4)
            + (if n.children.is_empty() { 0 } else { 2 })
            + usize::from(!n.siblings.is_empty() || n.hidden > 0)
    };
    const GOING_ROWS: usize = 5;
    let here_rows = input.nav.map_or(0, pane_rows);
    let show_here = input.nav.is_some() && here_rows <= avail;
    let show_going = show_here && input.nav_going.is_some() && here_rows + GOING_ROWS <= avail;
    if show_here {
        avail -= here_rows;
    }
    if show_going {
        avail -= GOING_ROWS;
    }
    let gr = avail;

    // C1: column basis over everything tier 1 CAN show — the first t1n
    // cues (the window slides within them) plus the explain rows. Not the
    // visible window: a content-driven width sized on the window would
    // jump as the operator scrolls. Tier-2 items render as grid cells and
    // the gloss bar clips a grid selection to this basis for the same
    // stability reason.
    let mut labmax = 0usize;
    let mut glomax = 0usize;
    for c in cues.iter().take(t1n) {
        labmax = labmax.max(wcols(&c.label));
        glomax = glomax.max(wcols(&c.gloss));
    }
    let mut descmax = 0usize;
    for e in explain {
        labmax = labmax.max(wcols(&e.label));
        descmax = descmax.max(wcols(&e.desc));
    }

    // W1–W3/W5: outer width. Bounds resolve against the terminal (columns or
    // percentage), floor at MIN_CARD_COLS — but W3's own principle caps
    // every floor at the terminal: a floor allowed to win over the window
    // is a card drawn into the wrapping column.
    let cap = cols.saturating_sub(1).max(3);
    let maxw = input
        .cfg
        .max_width
        .resolve(cols)
        .max(MIN_CARD_COLS)
        .min(cap);
    let minw = input
        .cfg
        .min_width
        .resolve(cols)
        .max(MIN_CARD_COLS)
        .min(maxw);

    // W6: the card takes the width its content needs, clamped to [min,
    // max]. "Content" is everything that would otherwise clip: tier-1
    // rows (C3 chrome 7, and the floor-10 gloss column namemax reserves
    // whether or not the glosses need it), explain rows (chrome 5), the
    // invnote footer and the collapsed line, a grid page holding every
    // item (gutter 3), and the widest legend this candidate set can reach
    // — engaged, ghost present, grid focused, both maximize wordings — so
    // gestures are not dropped by a card that hugged narrow rows, and the
    // width holds still across scrolling, engagement, focus, and Alt+M.
    // Box labels are the one deliberate exception: C5 clips them, and a
    // `nothing matches <prefix>` label must not widen the whole card.
    let mut need = (labmax + glomax.max(10) + 7).max(labmax + descmax + 5);
    if !explain.is_empty() {
        if !input.invnote.is_empty() {
            need = need.max(wcols(input.invnote) + 4);
        }
        if input.familiar {
            // E3's collapsed line names its way out; the named key is the
            // last thing that may be cut. Measured regardless of the
            // current `expanded` so Alt+E does not move the width.
            let note = if input.invnote.is_empty() {
                format!("{} properties", explain.len())
            } else {
                input.invnote.to_string()
            };
            need = need.max(wcols(&format!("{note}  ·  {} to expand", input.keys.expand)) + 4);
        }
    }
    if total > t1n && gr > 0 {
        let cellw = cues[t1n..]
            .iter()
            .map(|c| wcols(&c.insert))
            .max()
            .unwrap_or(1)
            .clamp(1, 28)
            + 2;
        let ncols_full = (total - t1n).div_ceil(gr);
        need = need.max(3 + ncols_full * cellw);
    }
    for np in [input.nav, input.nav_going].into_iter().flatten() {
        // One packed child cell must fit (name capped like grid cells,
        // count label ≤3); breadcrumb and siblings ellipsize instead of
        // driving width. Stack rows reserve label + a readable path stub.
        if let Some(w) = np
            .children
            .iter()
            .map(|(n, c)| wcols(n).min(24) + wcols(c) + 3)
            .max()
        {
            // Like the grid's ncols_full: the width that packs every
            // child into the pane's two rows, so "+n more" is a height
            // decision, not a width accident. Clamped by [min,max] below.
            let ncols_full = np.children.len().div_ceil(2);
            need = need.max(3 + ncols_full * w + 2);
        }
        if !np.stack.is_empty() {
            need = need.max(3 + 4 + 20);
        }
        // The one-line rows contribute their measured need like glosses
        // do (W6: content is everything that would otherwise clip); the
        // max-width cap has the last word, and past it they ellipsize.
        if !np.breadcrumb.is_empty() {
            need = need.max(wcols(&np.breadcrumb.join(" › ")) + 6);
        }
        for (label, path) in np.stack.iter().take(4) {
            need = need.max(wcols(label).max(3) + wcols(path) + 21);
        }
        if !np.siblings.is_empty() || np.hidden > 0 {
            let named: Vec<&str> = np.siblings.iter().take(3).map(|s| s.as_str()).collect();
            let mut t = String::new();
            if !named.is_empty() {
                t = format!("beside you: {}", named.join(" · "));
                if np.siblings.len() > named.len() {
                    t.push_str(&format!(" · +{} more", np.siblings.len() - named.len()));
                }
            }
            if np.hidden > 0 {
                if !t.is_empty() {
                    t.push_str("  ·  ");
                }
                t.push_str(&format!("+{} hidden", np.hidden));
            }
            need = need.max(wcols(&t) + 6);
        }
    }
    {
        // `tab_inserts` is left live here, which is load-bearing: the
        // predicate (state.rs) reads only cue count, exact-prefix and
        // info — nothing that changes while the buffer stands. If it ever
        // gained an engagement term, the ~22-column gap between the two
        // legend branches would make the card jump on Tab.
        let mut worst = *input;
        worst.engaged = true;
        worst.ghost = "g";
        let lneed = |focus: u8, grid: Option<Grid>, maxed: bool| {
            wcols(&format!(
                " {} ",
                legend(&worst, maxed, focus, grid, canmax).join(" · ")
            ))
        };
        need = need.max(lneed(1, None, false)).max(lneed(1, None, true));
        // Same reachability expression as `focus`: a squeezed-to-zero grid
        // still browses (sel past tier 1), so its legend still needs room.
        if total > t1n {
            // page: 1 over-advertises PgUp/PgDn on single-page grids —
            // the safe direction (never under-reserves).
            let gd = Grid {
                page: 1,
                lo: t1n + 1,
                hi: total,
                rows: 1,
                cols: 1,
            };
            need = need
                .max(lneed(2, Some(gd), false))
                .max(lneed(2, Some(gd), true));
        }
    }
    let lw = (need + 2).clamp(minw, maxw);
    let inner = lw.saturating_sub(2).max(1);

    // C2: names take what the room allows. When the card fit its content,
    // this is exactly labmax; squeezed against max-width, glosses keep
    // their measured need down to the old baseline 28 before names give
    // more, and the floor-10 gloss column has the last word (namemax).
    // Floors bend to the terminal: the row arithmetic is exact so W1
    // holds at every width.
    let namemax = inner.saturating_sub(17).max(1);
    let mut namew = labmax
        .min(28.max(inner.saturating_sub(7 + glomax)))
        .min(namemax);
    if namew < 10 {
        namew = 10.min(namemax);
    }
    let glossw = inner.saturating_sub(namew + 7).max(1);

    let mut rows: Vec<Row> = Vec::new();
    let mut grid_out: Option<Grid> = None;

    // ── tier 1 ───────────────────────────────────────────────────────────
    if t1n > 0 {
        let label = if input.argnomatch {
            format!(
                " {}/{} · nothing matches {} ",
                view.sel, total, input.prefix
            )
        } else {
            format!(" {}/{} ", view.sel, total)
        };
        rows.push(border_row(inner, &label, &g.tl, &g.tr, &g.h, theme));
        let bot = t1n.min(view.top1 + r1 - 1);
        for (i, c) in cues.iter().enumerate().take(bot).skip(view.top1 - 1) {
            let idx = i + 1;
            let selected = idx == view.sel;
            let mut row = Row::new();
            row.push(&g.v, Some(&p.border));
            let marker = format!(" {}", if selected { &g.sel } else { &g.nosel });
            row.push(&marker, None);
            row.push(" ", None);
            row.push(kind_glyph(c, input.mode, theme), Some(&p.hint));
            row.push(" ", None);
            let name_start = row.chars;
            row.push(&pad_to(fit_hard(&c.label, namew), namew), Some(&p.text));
            // SP2: emphasis only when the DISPLAYED name starts with the
            // typed prefix — a grouped label reached via its long spelling
            // must not bold the wrong characters.
            if !input.prefix.is_empty() && c.label.starts_with(input.prefix) {
                let n = input.prefix.chars().count();
                row.spans
                    .push((name_start, name_start + n, p.matched.clone()));
            }
            row.push("  ", None);
            row.push(
                &pad_to(fit_ellipsis(&c.gloss, glossw), glossw),
                Some(&p.gloss),
            );
            row.push(&g.v, Some(&p.border));
            if selected {
                row.overlay(&p.selected);
            }
            rows.push(row);
        }
    }

    // ── tier 2: the grid ─────────────────────────────────────────────────
    if total > t1n && gr > 0 {
        let lo = t1n + 1;
        let hi = total;
        let n = hi - lo + 1;
        // G1: cell width from the longest candidate, capped 28, plus pad.
        let w = cues[lo - 1..hi]
            .iter()
            .map(|c| wcols(&c.insert))
            .max()
            .unwrap_or(1)
            .clamp(1, 28);
        let gutter = 3usize; // G2
        let avail = inner.saturating_sub(gutter);
        // Cells shrink before the grid overflows — C2's truncate-don't-wrap
        // rule applied to cells, so a 12-column terminal still grids.
        let colw = (w + 2).min(avail.max(3));
        let w = colw.saturating_sub(2).max(1);
        let ncols = (avail / colw).max(1);
        let grows = n.div_ceil(ncols).clamp(1, gr);
        let page = grows * ncols;

        // G4: the window advances in whole pages.
        if view.gridtop < lo {
            view.gridtop = lo;
        }
        if view.sel >= lo && view.sel <= hi {
            while view.sel >= view.gridtop + page {
                view.gridtop += page;
            }
            while view.sel < view.gridtop {
                view.gridtop = view.gridtop.saturating_sub(page);
            }
            if view.gridtop < lo {
                view.gridtop = lo;
            }
        }

        // G5/G6: counter and keys derive from the same page number.
        let npages = n.div_ceil(page);
        let curpage = (view.gridtop - lo) / page + 1;
        let pg = if npages > 1 {
            format!(" · page {curpage}/{npages}")
        } else {
            String::new()
        };
        let label = if focus == 2 {
            format!(" browsing {}/{}{pg} ", view.sel - lo + 1, n)
        } else if let Some(gl) = input.grid_label {
            format!(" {n} {gl}{pg} ")
        } else if input.mode == Mode::Arg {
            format!(" {n} more{pg} ")
        } else {
            format!(" all {n} on system{pg} ")
        };
        rows.push(border_row(inner, &label, &g.tl, &g.tr, &g.h, theme));

        for r in 0..grows {
            let mut row = Row::new();
            row.push(&g.v, Some(&p.border));
            row.push(&" ".repeat(gutter), None);
            let mut used = 0usize;
            for c in 0..ncols {
                let idx = view.gridtop + c * grows + r;
                if idx > hi || idx - view.gridtop >= page {
                    row.push(&" ".repeat(colw), None);
                } else {
                    let nm = fit_hard(&cues[idx - 1].insert, w);
                    if idx == view.sel {
                        // G7: the CELL is the unit, not the row.
                        let cell = format!("{}{}", g.sel, pad_to(nm, colw - 1));
                        row.push(&cell, Some(&p.selected));
                    } else {
                        row.push(&pad_to(nm, colw), Some(&p.accent));
                    }
                }
                used += colw;
            }
            if used < avail {
                row.push(&" ".repeat(avail - used), None);
            }
            row.push(&g.v, Some(&p.border));
            rows.push(row);
        }
        grid_out = Some(Grid {
            page,
            lo,
            hi,
            rows: grows,
            cols: ncols,
        });
    }

    // ── tier 2: the explanation ──────────────────────────────────────────
    if er > 0 {
        // E3: collapse is a REDUCED view with the way out named on the row.
        let collapsed = !input.expanded && input.familiar;
        let label = if collapsed {
            " typed · collapsed "
        } else {
            " typed "
        };
        // E2: join the box above when one exists, open the card otherwise.
        let (jl, jr) = if rows.is_empty() {
            (&g.tl, &g.tr)
        } else {
            (&g.jl, &g.jr)
        };
        rows.push(border_row(inner, label, jl, jr, &g.h, theme));

        if collapsed {
            let note = if input.invnote.is_empty() {
                format!("{} properties", explain.len())
            } else {
                input.invnote.to_string()
            };
            let line = fit_hard(
                &format!("{note}  ·  {} to expand", input.keys.expand),
                inner.saturating_sub(4),
            );
            let mut row = Row::new();
            row.push(&g.v, Some(&p.border));
            row.push("   ", None);
            row.push(&pad_to(line, inner - 3), Some(&p.gloss));
            row.push(&g.v, Some(&p.border));
            rows.push(row);
        } else {
            // E4: the left column matches tier 1's so the boxes align.
            let dw = inner.saturating_sub(namew + 5).max(1);
            for e in explain.iter().take(er) {
                let mut row = Row::new();
                row.push(&g.v, Some(&p.border));
                row.push("   ", None);
                row.push(&pad_to(fit_hard(&e.label, namew), namew), Some(&p.text));
                row.push("  ", None);
                row.push(&pad_to(fit_ellipsis(&e.desc, dw), dw), Some(&p.gloss));
                row.push(&g.v, Some(&p.border));
                rows.push(row);
            }
            // E5: the invocation-note footer.
            if !input.invnote.is_empty() {
                let note = fit_hard(input.invnote, inner.saturating_sub(4));
                let mut row = Row::new();
                row.push(&g.v, Some(&p.border));
                row.push("   ", None);
                row.push(&pad_to(note, inner - 3), Some(&p.hint));
                row.push(&g.v, Some(&p.border));
                rows.push(row);
            }
        }
    }

    // ── the place panes: "you are here", then "you are going" ────────────
    // Falloff is structural (names → counts → "+n more") and, for now,
    // spoken through existing palette roles: text for the focus ring,
    // accent for children, gloss for the distant ring. The semantic
    // falloff-0/1/2 theme vocabulary lands with the theming work, spec
    // first (design note "Falloff is semantic; themes own its look").
    // Both panes are one renderer with two titles — the symmetry is the
    // feature (`cd .` draws the same place twice; `cd ..` shows here as
    // a styled child on the going map).
    for (np, title, beside, fixed) in [
        (
            if show_here { input.nav } else { None },
            " you are here ",
            "beside you",
            false,
        ),
        (
            if show_going { input.nav_going } else { None },
            " you are going ",
            "beside it",
            true,
        ),
    ]
    .into_iter()
    .filter_map(|(n, t, b, fx)| n.map(|n| (n, t, b, fx)))
    {
        let (jl, jr) = if rows.is_empty() {
            (&g.tl, &g.tr)
        } else {
            (&g.jl, &g.jr)
        };
        rows.push(border_row(inner, title, jl, jr, &g.h, theme));

        // Chrome is border + 3-space indent + border: body = inner − 3,
        // exactly like the explanation's collapsed line.
        let body = inner.saturating_sub(3).max(1);
        let line = |rows: &mut Vec<Row>, text: String, style: &str| {
            let mut row = Row::new();
            row.push(&g.v, Some(&p.border));
            row.push("   ", None);
            row.push(&pad_to(fit_tail(&text, body), body), Some(style));
            row.push(&g.v, Some(&p.border));
            rows.push(row);
        };

        let body_start = rows.len();
        if fixed && np.breadcrumb.is_empty() && np.children.is_empty() && np.siblings.is_empty() {
            // The reserved box before any destination is attended or
            // typed: say what it is for instead of sitting blank.
            line(
                &mut rows,
                "engage and arrow to preview a destination".into(),
                &p.gloss,
            );
        }
        if !np.breadcrumb.is_empty() {
            line(&mut rows, np.breadcrumb.join(" › "), &p.text);
        }

        // Labeled place rows: `-` / `+N`, landing entry marked. Clamped to
        // four with the remainder counted, never silently (design value 1).
        let shown = np.stack.len().min(4);
        for (i, (label, path)) in np.stack.iter().take(shown).enumerate() {
            let mark = if np.landing == Some(i) {
                "  ← lands here"
            } else {
                ""
            };
            line(&mut rows, format!("{label:<3} {path}{mark}"), &p.text);
        }
        if np.stack.len() > shown {
            line(
                &mut rows,
                format!("    +{} deeper", np.stack.len() - shown),
                &p.gloss,
            );
        }

        // Children pack into two rows of `name/ N` cells; what the rows
        // cannot hold is counted into the last cell. Cell width is
        // structure-stable: the count field is reserved (H7 cells). The
        // here_child cell (the operator's own location on a going map)
        // is emphasised by STYLE — every posture has that channel.
        if !np.children.is_empty() {
            let cellw = np
                .children
                .iter()
                .map(|(n, c)| wcols(n).min(24) + wcols(c) + 3)
                .max()
                .unwrap_or(4)
                .min(body.saturating_sub(1).max(3));
            let ncols = (body / cellw).max(1);
            let cap = ncols * 2;
            let shown = if np.children.len() > cap {
                cap.saturating_sub(1)
            } else {
                np.children.len()
            };
            let mut cells: Vec<(String, bool)> = np.children[..shown]
                .iter()
                .map(|(n, c)| {
                    (
                        format!("{}/ {c}", fit_hard(n, 24)),
                        np.here_child.as_deref() == Some(n.as_str()),
                    )
                })
                .collect();
            if np.children.len() > shown {
                cells.push((format!("+{} more", np.children.len() - shown), false));
            }
            for chunk in cells.chunks(ncols) {
                let mut row = Row::new();
                row.push(&g.v, Some(&p.border));
                row.push("   ", None);
                let mut used = 3usize;
                for (cell, is_here) in chunk {
                    let text = pad_to(fit_hard(cell, body.saturating_sub(used - 3).max(1)), cellw);
                    let w = wcols(&text);
                    if used + w > body + 3 {
                        break;
                    }
                    row.push(&text, Some(if *is_here { &p.matched } else { &p.accent }));
                    used += w;
                }
                if used < inner {
                    row.push(&" ".repeat(inner - used), None);
                }
                row.push(&g.v, Some(&p.border));
                rows.push(row);
            }
        }

        if !np.siblings.is_empty() || np.hidden > 0 {
            let mut parts: Vec<String> = Vec::new();
            if !np.siblings.is_empty() {
                let named: Vec<&str> = np.siblings.iter().take(3).map(|s| s.as_str()).collect();
                let mut t = format!("{beside}: {}", named.join(" · "));
                if np.siblings.len() > named.len() {
                    t.push_str(&format!(" · +{} more", np.siblings.len() - named.len()));
                }
                parts.push(t);
            }
            if np.hidden > 0 {
                parts.push(format!("+{} hidden", np.hidden));
            }
            // End-ellipsis here: unlike a path, this row's head carries
            // the meaning.
            line(
                &mut rows,
                fit_ellipsis(&parts.join("  ·  "), body),
                &p.gloss,
            );
        }
        if fixed {
            while rows.len() - body_start < GOING_ROWS - 1 {
                line(&mut rows, String::new(), &p.gloss);
            }
            while rows.len() - body_start > GOING_ROWS - 1 {
                rows.pop();
            }
        }
    }

    // ── legend ───────────────────────────────────────────────────────────
    let (bl, br) = fit_corners(&g.bl, &g.br, inner);
    let over = overhang(&bl, &br);
    let segs = legend(input, view.maxed, focus, grid_out, canmax);
    let hint = fit_legend(&segs, inner.saturating_sub(over));
    {
        let rule = inner.saturating_sub(wcols(&hint) + over);
        let mut row = Row::new();
        row.push(&bl, None);
        row.push(&hint, None);
        row.push(&hfill(&g.h_bottom, rule), None);
        row.push(&br, None);
        border_overlay(&mut row, theme);
        let start = bl.chars().count();
        row.spans
            .push((start, start + hint.chars().count(), p.hint.clone()));
        rows.push(row);
    }

    // ── gloss bar + close (H7: rendered unconditionally) ─────────────────
    if total > 0 {
        let c = &cues[view.sel - 1];
        // A grid selection was never in the column basis (C1) — it must
        // not drive the width, but this free-standing row has the room,
        // so the name takes it here rather than clipping to tier 1's
        // alignment, which does no work on this row when focus is 2.
        let nw = if focus == 2 {
            namew
                .max(wcols(&c.label))
                .min(inner.saturating_sub(15).max(namew))
        } else {
            namew
        };
        let gw = inner.saturating_sub(nw + 5).max(1);
        let mut row = Row::new();
        row.push(&g.v, Some(&p.border));
        row.push("   ", None);
        row.push(&pad_to(fit_hard(&c.label, nw), nw), Some(&p.text));
        row.push("  ", None);
        row.push(&pad_to(fit_ellipsis(&c.gloss, gw), gw), Some(&p.gloss));
        row.push(&g.v, Some(&p.border));
        rows.push(row);

        let mut close = Row::new();
        close.push(&bl, None);
        close.push(&hfill(&g.h_bottom, inner.saturating_sub(over)), None);
        close.push(&br, None);
        border_overlay(&mut close, theme);
        rows.push(close);
    }

    // ── assemble (SP1) ───────────────────────────────────────────────────
    let mut text = String::new();
    let mut spans = Vec::new();
    let mut offset = 1usize; // char 0 is the leading newline
    for row in &rows {
        text.push('\n');
        text.push_str(&row.line);
        for (s, e, st) in &row.spans {
            spans.push(Span {
                start: offset + s,
                end: offset + e,
                style: st.clone(),
            });
        }
        offset += row.chars + 1;
    }

    // Panel ground: one base span under everything, and the panel's bg
    // merged into every span that has none — region_highlight's last-
    // wins stacking replaces the WHOLE attribute set per char, so an
    // fg-only span above the base would punch a terminal-default hole
    // through the card.
    if !theme.palette.panel.is_empty() {
        let bg = theme
            .palette
            .panel
            .split(',')
            .find(|part| part.trim_start().starts_with("bg="))
            .unwrap_or(&theme.palette.panel)
            .trim()
            .to_string();
        for sp in &mut spans {
            if !sp.style.contains("bg=") {
                sp.style = format!("{},{bg}", sp.style);
            }
        }
        // One base span PER ROW, newlines excluded: a bg attribute active
        // across a newline smears to the terminal's right edge on BCE
        // terminals (review #14).
        let mut base = Vec::new();
        let mut at = 1usize;
        for row in &rows {
            if row.chars > 0 {
                base.push(Span {
                    start: at,
                    end: at + row.chars,
                    style: theme.palette.panel.clone(),
                });
            }
            at += row.chars + 1;
        }
        spans.splice(0..0, base);
    }

    Some(Card {
        text,
        spans,
        grid: grid_out,
        focus,
        canmax,
        tier1_count: t1n,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::theme;

    fn cue(name: &str, gloss: &str) -> Cue {
        Cue {
            insert: name.to_string(),
            label: name.to_string(),
            gloss: gloss.to_string(),
            kind: Kind::System,
            suffix: None,
        }
    }

    fn many_cues(n: usize) -> Vec<Cue> {
        (0..n)
            .map(|i| cue(&format!("command-{i}"), &format!("does thing number {i}")))
            .collect()
    }

    fn input<'a>(
        cues: &'a [Cue],
        explain: &'a [ExplainRow],
        dims: Dims,
        cfg: &'a LayoutCfg,
        keys: &'a KeyLabels,
    ) -> CardInput<'a> {
        CardInput {
            cues,
            explain,
            mode: Mode::Cmd,
            prefix: "",
            info: false,
            argnomatch: false,
            engaged: false,
            familiar: false,
            expanded: false,
            tab_inserts: false,
            ghost: "",
            nav: None,
            nav_going: None,
            grid_label: None,
            invnote: "",
            dims,
            cfg,
            keys,
        }
    }

    fn line_widths(card: &Card) -> Vec<usize> {
        // text starts with '\n', so skip the empty first element.
        card.text.lines().skip(1).map(wcols).collect()
    }

    fn pane(pending: bool) -> crate::nav::NavPane {
        crate::nav::NavPane {
            breadcrumb: vec!["~".into(), "Projects".into(), "app".into(), "clicue".into()],
            children: vec![
                (
                    "crates".into(),
                    if pending { "…".into() } else { "1".into() },
                ),
                ("docs".into(), if pending { "…".into() } else { "4".into() }),
                ("spec".into(), if pending { "…".into() } else { "9".into() }),
                (
                    "tests".into(),
                    if pending { "…".into() } else { "3".into() },
                ),
                ("dist".into(), if pending { "…".into() } else { "2".into() }),
            ],
            hidden: 2,
            siblings: vec!["patchbay".into(), "yay-friend".into()],
            stack: vec![("-".into(), "~/Knowledge".into())],
            landing: None,
            dir: std::path::PathBuf::new(),
            here_child: None,
        }
    }

    #[test]
    fn nav_pane_renders_and_alone_justifies_the_card() {
        let cues: Vec<Cue> = Vec::new();
        let explain: Vec<ExplainRow> = Vec::new();
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let np = pane(false);
        let mut inp = input(
            &cues,
            &explain,
            Dims {
                cols: 90,
                lines: 40,
            },
            &cfg,
            &keys,
        );
        inp.mode = Mode::Arg;
        inp.nav = Some(&np);
        let mut view = View::default();
        let card = render(&inp, &mut view, &crate::theme::base()).expect("pane alone renders");
        let widths = line_widths(&card);
        assert!(
            widths.iter().all(|w| *w == widths[0]),
            "every row spans the full card: {widths:?}\n{}",
            card.text
        );
        assert!(card.text.contains("you are here"));
        assert!(card.text.contains("~ › Projects › app › clicue"));
        assert!(card.text.contains("crates/ 1"));
        assert!(card.text.contains("beside you: patchbay"), "{}", card.text);
        assert!(card.text.contains("+2 hidden"));
        assert!(card.text.contains("-   ~/Knowledge"));
    }

    #[test]
    fn nav_pane_count_fill_never_moves_the_card() {
        // H7 as cells, not rows: pending "…" counts filling in on a later
        // render must keep line count AND width identical.
        let cues: Vec<Cue> = Vec::new();
        let explain: Vec<ExplainRow> = Vec::new();
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let before = pane(true);
        let after = pane(false);
        let render_with = |np: &crate::nav::NavPane| {
            let mut inp = input(
                &cues,
                &explain,
                Dims {
                    cols: 90,
                    lines: 40,
                },
                &cfg,
                &keys,
            );
            inp.mode = Mode::Arg;
            inp.nav = Some(np);
            let mut view = View::default();
            render(&inp, &mut view, &crate::theme::base()).unwrap()
        };
        let a = render_with(&before);
        let b = render_with(&after);
        assert_eq!(
            a.text.lines().count(),
            b.text.lines().count(),
            "row count must not change when counts arrive"
        );
        assert_eq!(
            line_widths(&a),
            line_widths(&b),
            "width must not change when counts arrive"
        );
    }

    #[test]
    fn nav_pane_survives_every_width_with_deep_stacks() {
        let cues: Vec<Cue> = Vec::new();
        let explain: Vec<ExplainRow> = Vec::new();
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut np = pane(false);
        np.stack = (1..=9)
            .map(|i| {
                (
                    format!("+{i}"),
                    format!("/very/deep/dirstack/entry/number/{i}"),
                )
            })
            .collect();
        np.landing = Some(0);
        for cols in 12..160u16 {
            let mut inp = input(&cues, &explain, Dims { cols, lines: 30 }, &cfg, &keys);
            inp.mode = Mode::Arg;
            inp.nav = Some(&np);
            let mut view = View::default();
            if let Some(card) = render(&inp, &mut view, &crate::theme::base()) {
                for (i, w) in line_widths(&card).iter().enumerate() {
                    assert!(
                        *w <= (cols as usize).saturating_sub(1),
                        "line {i} is {w} wide at {cols} cols"
                    );
                }
                if cols > 40 {
                    assert!(card.text.contains("lands here"), "landing marked at {cols}");
                    assert!(card.text.contains("+5 deeper"), "clamp counted at {cols}");
                }
            }
        }
    }

    #[test]
    fn never_wider_than_cols_minus_one_at_any_width() {
        // W1/T1, property-style, with long and multibyte names.
        let mut cues = many_cues(40);
        cues.push(cue(
            "日本語のコマンド名がとても長い場合でも収まる",
            "説明文も東アジアの全角文字でできている and very long indeed",
        ));
        cues.push(cue(
            "a-very-long-command-name-that-overflows-any-column",
            "an equally interminable gloss that will need the ellipsis treatment",
        ));
        let explain = vec![ExplainRow {
            label: "-l, --long-form-of-a-flag".into(),
            desc: "display extended metadata as a table, at great length".into(),
        }];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        for cols in 12..200u16 {
            let dims = Dims { cols, lines: 40 };
            let mut inp = input(&cues, &explain, dims, &cfg, &keys);
            inp.mode = Mode::Arg;
            let mut view = View::default();
            let card = render(&inp, &mut view, &theme::base()).unwrap();
            for (i, w) in line_widths(&card).iter().enumerate() {
                assert!(*w < (cols as usize), "cols={cols}: line {i} is {w} wide");
            }
        }
    }

    #[test]
    fn the_card_hugs_its_content() {
        // W6: two short cues on a wide terminal do not get a 120-column box.
        let cues = vec![
            cue("ls", "list directory contents"),
            cue("lsd", "modern ls with icons"),
        ];
        let cfg = LayoutCfg {
            min_width: WidthBound::Pct(1),
            ..LayoutCfg::default()
        };
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 200,
                lines: 40,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        let w = line_widths(&card)[0];
        assert!(
            (MIN_CARD_COLS..80).contains(&w),
            "content this small must not paint {w} columns"
        );
    }

    #[test]
    fn long_history_lines_get_the_width_they_need() {
        // W6/C2: the regression this replaces — a remembered line clipped at
        // a 28-column name cap while the gloss column sat empty.
        // The gloss is deliberately NARROWER than the floor-10 gloss column
        // namemax reserves — the case review #18 caught: sizing that
        // ignored the floor clipped the name by (10 − glossw) columns.
        let long = "git clone git@github.com:somewhere/a-repository-name.git";
        let cues = vec![cue(long, "3×"), cue("git status", "97× · top 1%")];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut inp = input(
            &cues,
            &[],
            Dims {
                cols: 200,
                lines: 40,
            },
            &cfg,
            &keys,
        );
        inp.mode = Mode::Arg;
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(
            card.text.contains(long),
            "the whole remembered line must render when the room exists"
        );
    }

    #[test]
    fn width_bounds_resolve_and_floor() {
        let keys = KeyLabels::default();
        let dims = Dims {
            cols: 100,
            lines: 40,
        };
        // Min as a percentage holds up a card whose content is smaller.
        let cues = vec![cue("a", "b")];
        let cfg = LayoutCfg {
            min_width: WidthBound::Pct(60),
            ..LayoutCfg::default()
        };
        let mut inp = input(&cues, &[], dims, &cfg, &keys);
        inp.info = true; // legend collapses to `Esc dismiss`
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert_eq!(line_widths(&card)[0], 60, "60% of 100 columns");
        // W5: a percentage that resolves below the literal floor loses to it.
        let cfg = LayoutCfg {
            min_width: WidthBound::Pct(1),
            ..LayoutCfg::default()
        };
        let mut inp = input(&cues, &[], dims, &cfg, &keys);
        inp.info = true;
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert_eq!(line_widths(&card)[0], MIN_CARD_COLS, "the literal floor");
    }

    #[test]
    fn width_holds_still_across_navigation_and_engagement() {
        // W6/C1: label lengths vary wildly; scrolling the tier-1 window and
        // engaging the card must not change the card's width.
        let cues: Vec<Cue> = (0..30)
            .map(|i| cue(&format!("cmd-{}", "x".repeat(i)), "a gloss"))
            .collect();
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let dims = Dims {
            cols: 160,
            lines: 14, // squeezes r1 below tier1-rows, so the window slides
        };
        let mut widths = std::collections::HashSet::new();
        let mut view = View::default();
        // The full candidate count, so the selection crosses from tier 1
        // into the grid (focus 2) — the legend swap must not move width.
        for sel in 1..=30 {
            for engaged in [false, true] {
                let mut inp = input(&cues, &[], dims, &cfg, &keys);
                inp.engaged = engaged;
                view.sel = sel;
                let card = render(&inp, &mut view, &theme::base()).unwrap();
                widths.insert(line_widths(&card)[0]);
            }
        }
        assert_eq!(
            widths.len(),
            1,
            "width jumped during navigation: {widths:?}"
        );
    }

    #[test]
    fn collapsed_line_and_invnote_are_measured() {
        // Review #18: E3's collapsed line names its way out (Alt+E), and
        // that named key must not be the thing content-fit truncates.
        let explain = vec![ExplainRow {
            label: "-l".into(),
            desc: "ls".into(),
        }];
        let cfg = LayoutCfg {
            min_width: WidthBound::Pct(1),
            ..LayoutCfg::default()
        };
        let keys = KeyLabels::default();
        let mut inp = input(
            &[],
            &explain,
            Dims {
                cols: 200,
                lines: 40,
            },
            &cfg,
            &keys,
        );
        inp.mode = Mode::Arg;
        inp.familiar = true;
        inp.invnote = "run 97× · top 1% · last seen today";
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(
            card.text.contains("Alt+E to expand"),
            "the way out was truncated: {}",
            card.text
        );
        inp.expanded = true;
        let expanded = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(
            expanded.text.contains(inp.invnote),
            "invnote footer truncated: {}",
            expanded.text
        );
        assert_eq!(
            line_widths(&card)[0],
            line_widths(&expanded)[0],
            "Alt+E must not move the width"
        );
    }

    #[test]
    fn constant_height_as_selection_moves() {
        // H7: for fixed input, moving the selection never changes height.
        let cues = many_cues(60);
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let dims = Dims {
            cols: 100,
            lines: 40,
        };
        let mut heights = std::collections::HashSet::new();
        for sel in 1..=60 {
            let mut inp = input(&cues, &[], dims, &cfg, &keys);
            inp.engaged = true;
            let mut view = View {
                sel,
                ..View::default()
            };
            let card = render(&inp, &mut view, &theme::base()).unwrap();
            heights.insert(card.text.lines().count());
        }
        assert_eq!(
            heights.len(),
            1,
            "height varied with selection: {heights:?}"
        );
    }

    #[test]
    fn grid_page_counter_agrees_with_published_page() {
        // G5: the counter and the keys derive from the same number.
        let cues = many_cues(200);
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let dims = Dims {
            cols: 100,
            lines: 30,
        };
        let inp = input(&cues, &[], dims, &cfg, &keys);
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        let grid = card.grid.expect("200 candidates must overflow");
        assert_eq!(grid.page, grid.rows * grid.cols);
        let n = grid.hi - grid.lo + 1;
        let npages = n.div_ceil(grid.page);
        assert!(
            card.text.contains(&format!("page 1/{npages}")),
            "label must cite the same page count"
        );
    }

    #[test]
    fn legend_always_ends_with_dismiss() {
        // L8: the escape hatch survives any width.
        let segs: Vec<String> = vec![
            "Tab cycle".into(),
            "↑↓ browse".into(),
            "→ accept".into(),
            "⏎ insert".into(),
            "Esc dismiss".into(),
        ];
        for avail in 4..80 {
            let fitted = fit_legend(&segs, avail);
            assert!(wcols(&fitted) <= avail, "avail={avail}: overflowed");
            if avail >= 13 {
                assert!(
                    fitted.contains("dismiss"),
                    "avail={avail}: lost the escape hatch: {fitted:?}"
                );
            }
        }
    }

    #[test]
    fn wide_glyphs_do_not_break_alignment() {
        // Every row of one card has the same display width.
        let cues = vec![
            cue("ls", "list directory contents"),
            cue("日本語", "cjk name, two columns per glyph"),
            cue("naïve", "latin with diacritics"),
        ];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 80,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::builtin("aura").unwrap()).unwrap();
        let widths = line_widths(&card);
        assert!(
            widths.windows(2).all(|w| w[0] == w[1]),
            "rows misaligned: {widths:?}"
        );
    }

    #[test]
    fn selection_is_clamped() {
        let cues = many_cues(5);
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 80,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        let mut view = View {
            sel: 999,
            ..View::default()
        };
        render(&inp, &mut view, &theme::base()).unwrap();
        assert_eq!(view.sel, 5);
        view.sel = 0;
        render(&inp, &mut view, &theme::base()).unwrap();
        assert_eq!(view.sel, 1);
    }

    #[test]
    fn engagement_gates_the_legend() {
        // L5: ⏎ insert must not be advertised before Tab engages the card.
        let cues = many_cues(3);
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut inp = input(
            &cues,
            &[],
            Dims {
                cols: 90,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(!card.text.contains("⏎ insert"));
        assert!(!card.text.contains("↑↓ browse"));
        inp.engaged = true;
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(card.text.contains("⏎ insert"));
        assert!(card.text.contains("↑↓ browse"));
    }

    #[test]
    fn info_card_offers_only_dismiss() {
        // L3.
        let cues = many_cues(1);
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut inp = input(
            &cues,
            &[],
            Dims {
                cols: 90,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        inp.info = true;
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(card.text.contains("Esc dismiss"));
        assert!(!card.text.contains("cycle"));
    }

    #[test]
    fn explain_only_card_renders_and_opens_with_top_corner() {
        // S6 + E2.
        let explain = vec![
            ExplainRow {
                label: "-l".into(),
                desc: "long listing".into(),
            },
            ExplainRow {
                label: "-a, --all".into(),
                desc: "do not hide dotfiles".into(),
            },
        ];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut inp = input(
            &[],
            &explain,
            Dims {
                cols: 80,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        inp.mode = Mode::Arg;
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        let first = card.text.lines().nth(1).unwrap();
        assert!(
            first.starts_with('+'),
            "explain-only card must OPEN a box: {first:?}"
        );
        assert!(card.text.contains("typed"));
    }

    #[test]
    fn spans_are_char_offsets_within_text() {
        let cues = vec![cue("日本語", "cjk")];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 60,
                lines: 24,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        let nchars = card.text.chars().count();
        for s in &card.spans {
            assert!(
                s.start < s.end && s.end <= nchars,
                "span out of range: {s:?}"
            );
        }
    }

    #[test]
    fn budget_is_enforced_not_assumed() {
        // H1/H2: a small window caps the card regardless of preferences.
        let cues = many_cues(300);
        let cfg = LayoutCfg {
            tier1_rows: 20,
            ..LayoutCfg::default()
        };
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 100,
                lines: 20,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        let h = card.text.lines().count() - 1;
        assert!(h <= 14, "card is {h} rows in a 20-row window");
    }

    #[test]
    fn tab_inserts_wording_follows_the_predicate() {
        // L6.
        let cues = vec![cue("org", "the token already typed")];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let mut inp = input(
            &cues,
            &[],
            Dims {
                cols: 90,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        inp.tab_inserts = true;
        let mut view = View::default();
        let card = render(&inp, &mut view, &theme::base()).unwrap();
        assert!(card.text.contains("Tab insert"));
        assert!(!card.text.contains("Tab cycle"));
    }
    #[test]
    fn panel_theme_grounds_every_span() {
        let t = theme::builtin("agnoster").unwrap();
        let cues = vec![cue("git", "the stupid content tracker")];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 90,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &t).unwrap();
        // per-row base spans first (a bg crossing a newline smears to the
        // terminal edge on BCE terminals), tiling every visible row
        let bases: Vec<_> = card
            .spans
            .iter()
            .take_while(|s| s.style == t.palette.panel)
            .collect();
        let rows = card.text.lines().skip(1).count();
        assert_eq!(bases.len(), rows, "one base span per row");
        assert_eq!(bases[0].start, 1, "leading newline excluded");
        let chars: Vec<char> = card.text.chars().collect();
        for b in &bases {
            assert!(
                b.end == chars.len() || chars[b.end] == '\n',
                "base span must stop before the newline"
            );
        }
        // nothing above the bases can punch a terminal-default hole
        for s in &card.spans[bases.len()..] {
            assert!(s.style.contains("bg="), "hole in the panel: {:?}", s.style);
        }
    }

    #[test]
    fn gradient_theme_sweeps_horizontal_borders() {
        let t = theme::builtin("chrome").unwrap();
        let cues = vec![cue("git", "the stupid content tracker")];
        let cfg = LayoutCfg::default();
        let keys = KeyLabels::default();
        let inp = input(
            &cues,
            &[],
            Dims {
                cols: 90,
                lines: 30,
            },
            &cfg,
            &keys,
        );
        let mut view = View::default();
        let card = render(&inp, &mut view, &t).unwrap();
        let grads: Vec<_> = card
            .spans
            .iter()
            .filter(|s| s.style.starts_with("fg=#") && !s.style.contains(','))
            .filter(|s| s.end - s.start <= 3)
            .collect();
        assert!(
            grads.len() >= 10,
            "expected gradient segments, got {}",
            grads.len()
        );
    }
}
