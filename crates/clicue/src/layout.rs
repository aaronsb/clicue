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

/// Operator preferences (the zstyles of the prototype).
#[derive(Debug, Clone)]
pub struct LayoutCfg {
    /// H4: fixed cue count for tier 1.
    pub tier1_rows: usize,
    /// W2: a cap, not a target.
    pub max_width: usize,
    /// H2: None = auto (`LINES − 6`).
    pub max_lines: Option<usize>,
    /// H5: None = auto (clamped to a third of the window).
    pub tier2_rows: Option<usize>,
}

impl Default for LayoutCfg {
    fn default() -> Self {
        LayoutCfg {
            tier1_rows: 10,
            max_width: 120,
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
/// layout decides nothing about WHAT to show, only HOW.
#[derive(Debug)]
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

fn border_row(inner: usize, label: &str, l: &str, r: &str, h: &str, style: &str) -> Row {
    let label = fit_label(label, inner);
    let rule = inner.saturating_sub(wcols(&label)).max(1);
    let mut row = Row::new();
    row.push(l, None);
    row.push(&label, None);
    row.push(&h.repeat(rule), None);
    row.push(r, None);
    row.overlay(style);
    row
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

    // S6: an explanation alone justifies the card.
    if total == 0 && explain.is_empty() {
        return None;
    }

    let g = &theme.glyphs;
    let p = &theme.palette;

    // W1–W3: outer width. The only floor is the arithmetic limit; the
    // terminal always wins over preferences.
    let cols = input.dims.cols as usize;
    let mut lw = cols.saturating_sub(1);
    lw = lw.min(input.cfg.max_width.max(12));
    // Floor 12 (the arithmetic limit) — but W3's own principle caps every
    // floor at the terminal: a floor allowed to win over the window is a
    // card drawn into the wrapping column.
    lw = lw.max(12).min(cols.saturating_sub(1).max(3));
    let inner = lw.saturating_sub(2).max(1);

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
    let mut gr = r2.saturating_sub(er);
    if er > 0 {
        gr = gr.saturating_sub(1); // the explanation's own border
    }

    // C1/C2: name column over display labels of both visible windows plus
    // the explain labels.
    let mut vis: Vec<&str> = Vec::new();
    if t1n > 0 {
        let hi = t1n.min(view.top1 + r1 - 1);
        for c in cues.iter().take(hi).skip(view.top1.saturating_sub(1)) {
            vis.push(&c.label);
        }
    }
    if total > t1n {
        let t2 = view.top2.max(t1n + 1);
        let hi = total.min(t2 + r2.max(1) - 1);
        for c in cues.iter().take(hi).skip(t2 - 1) {
            vis.push(&c.label);
        }
    }
    for e in explain {
        vis.push(&e.label);
    }
    let mut namew = vis.iter().map(|s| wcols(s)).max().unwrap_or(0).min(28);
    // Capped against what is actually LEFT; floors bend to the terminal.
    // (The prototype's fixed floor-10 gloss could overflow a tiny window;
    // here the row arithmetic is exact so W1 holds at every width.)
    let namemax = inner.saturating_sub(17).max(1);
    namew = namew.min(namemax);
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
        rows.push(border_row(inner, &label, &g.tl, &g.tr, &g.h, &p.border));
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
        } else if input.mode == Mode::Arg {
            format!(" {n} more{pg} ")
        } else {
            format!(" all {n} on system{pg} ")
        };
        rows.push(border_row(inner, &label, &g.tl, &g.tr, &g.h, &p.border));

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
        rows.push(border_row(inner, label, jl, jr, &g.h, &p.border));

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

    // ── legend ───────────────────────────────────────────────────────────
    let segs = legend(input, view.maxed, focus, grid_out, canmax);
    let hint = fit_legend(&segs, inner);
    {
        let rule = inner.saturating_sub(wcols(&hint));
        let mut row = Row::new();
        row.push(&g.bl, None);
        row.push(&hint, None);
        row.push(&g.h.repeat(rule), None);
        row.push(&g.br, None);
        row.overlay(&p.border);
        let start = g.bl.chars().count();
        row.spans
            .push((start, start + hint.chars().count(), p.hint.clone()));
        rows.push(row);
    }

    // ── gloss bar + close (H7: rendered unconditionally) ─────────────────
    if total > 0 {
        let c = &cues[view.sel - 1];
        let gw = inner.saturating_sub(namew + 5).max(1);
        let mut row = Row::new();
        row.push(&g.v, Some(&p.border));
        row.push("   ", None);
        row.push(&pad_to(fit_hard(&c.label, namew), namew), Some(&p.text));
        row.push("  ", None);
        row.push(&pad_to(fit_ellipsis(&c.gloss, gw), gw), Some(&p.gloss));
        row.push(&g.v, Some(&p.border));
        rows.push(row);

        let mut close = Row::new();
        close.push(&g.bl, None);
        close.push(&g.h.repeat(inner), None);
        close.push(&g.br, None);
        close.overlay(&p.border);
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
}
