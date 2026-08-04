//! Per-session state: where the cursor is (position analysis) and what
//! the operator has done about it (selection, engagement, tab machine).
//!
//! Contracts: spec/keys.md (engagement gating, tab machine, selection),
//! spec/sources.md §position, and the pre-redraw decision sequence of
//! prototype/clicue.zsh:218–367. Pure: no I/O, no clock.

use crate::model::Mode;

/// Position analysis of the buffer up to the cursor — the prototype's
/// per-segment decision (clicue.zsh:261–307).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Position {
    pub mode: Mode,
    /// In arg mode, the command being argued (first word of the segment).
    pub cmd: String,
    /// Colon-joined command path the cursor sits in (`gh:org`): non-flag
    /// tokens BEFORE the one being typed — a flag never changes what the
    /// next token means, a subcommand always does.
    pub cmdpath: String,
    /// The partial word being completed ("" right after a space).
    pub pfx: String,
    /// The segment already carries an option token.
    pub optctx: bool,
    /// All words of the current segment.
    pub words: Vec<String>,
    /// The segment ends in whitespace (a fresh word position).
    pub trailing: bool,
    /// The word under the cursor is unambiguously filesystem (`/` or a
    /// leading `~`). Compsys owns completing it — but whether that means
    /// standing DOWN is the caller's call, not this function's: for a
    /// navigational command a path is exactly what the card explains
    /// (design note navigation-and-place.md), so the verdict needs the
    /// command class, which pure buffer analysis does not have.
    pub pathlike: bool,
}

/// Why clicue is standing down for this event.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StandDown {
    /// Below min-input in command position.
    TooShort,
    /// Command position starting with `-`, `.` or `/` — pathish typing.
    PathLike,
    /// zsh's own completion menu owns the display (clicue.zsh:250).
    MenuSelect,
    /// Operator dismissed this exact buffer (Esc; clicue.zsh:239–245).
    Dismissed,
}

/// Split the buffer into its last command segment. Separators per the
/// prototype (`${buf##*(\||\|\||;|&&)}`) plus `&` — candidates.zsh's
/// separator set is the fuller one and sources.md adopted it.
fn last_segment(buffer: &str) -> &str {
    let mut start = 0;
    let b = buffer.as_bytes();
    let mut i = 0;
    while i < b.len() {
        match b[i] {
            b'|' | b';' | b'&' => start = i + 1,
            _ => {}
        }
        i += 1;
    }
    buffer[start..].trim_start()
}

/// Whitespace tokenizer honouring simple quoting — an approximation of
/// zsh `${(z)}`; divergence is acceptable because a quoted word is
/// filesystem-or-value territory where clicue stands down anyway.
fn words_of(seg: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cur = String::new();
    let mut quote: Option<char> = None;
    for c in seg.chars() {
        match quote {
            Some(q) => {
                if c == q {
                    quote = None;
                } else {
                    cur.push(c);
                }
            }
            None => match c {
                '\'' | '"' => quote = Some(c),
                c if c.is_whitespace() => {
                    if !cur.is_empty() {
                        out.push(std::mem::take(&mut cur));
                    }
                }
                c => cur.push(c),
            },
        }
    }
    if !cur.is_empty() {
        out.push(cur);
    }
    out
}

/// The pre-redraw position decision. `keymap`/dismissal are checked by
/// the caller (they need session state); this is the pure buffer half.
pub fn analyze(buffer: &str, min_input: usize) -> Result<Position, StandDown> {
    let seg = last_segment(buffer);
    let trailing = seg.ends_with(char::is_whitespace) && !seg.is_empty();
    let words = words_of(seg);

    if words.is_empty() || (words.len() == 1 && !trailing) {
        // ── command position ────────────────────────────────────────
        let pfx = seg.trim_end().to_string();
        if pfx.chars().count() < min_input {
            return Err(StandDown::TooShort);
        }
        if pfx.starts_with(['-', '.', '/']) {
            return Err(StandDown::PathLike);
        }
        return Ok(Position {
            mode: Mode::Cmd,
            cmd: String::new(),
            cmdpath: String::new(),
            pfx,
            optctx: false,
            words,
            trailing,
            pathlike: false,
        });
    }

    // ── argument position ───────────────────────────────────────────
    let cmd = words[0].clone();
    let last = words.last().cloned().unwrap_or_default();
    let pathlike = last.contains('/') || last.starts_with('~');
    // Path from non-flag tokens BEFORE the word being typed. With a
    // trailing space every word is complete; otherwise the last word is
    // the one being typed and does not extend the path.
    let upto = if trailing {
        words.len()
    } else {
        words.len() - 1
    };
    let mut cmdpath = cmd.clone();
    for w in &words[1..upto] {
        if !w.is_empty() && !w.starts_with('-') {
            cmdpath.push(':');
            cmdpath.push_str(w);
        }
    }
    let optctx = words[1..].iter().any(|w| w.starts_with('-'));
    let pfx = if trailing { String::new() } else { last };
    Ok(Position {
        mode: Mode::Arg,
        cmd,
        cmdpath,
        pfx,
        optctx,
        words,
        trailing,
        pathlike,
    })
}

/// Everything the daemon remembers about one shell between events.
#[derive(Debug, Clone, Default)]
pub struct SessionState {
    /// 1-based selection into the candidate list; 0 = none yet.
    pub sel: usize,
    pub top1: usize,
    pub top2: usize,
    pub gridtop: usize,
    /// Focus 2 = the grid is a MODE (spec/keys.md G-rules).
    pub focus: u8,
    /// Arrows and Enter are inert until Tab engages (keys.md E-rules).
    pub engaged: bool,
    /// Esc'd, for this exact buffer only (clicue.zsh:229–245).
    pub suppressed_buffer: Option<String>,
    /// Buffer at last event, to reset selection when it changes.
    pub last_buffer: Option<String>,
    /// Expansion is sticky per command, not forever (clicue.zsh:366).
    pub expanded: bool,
    pub expanded_cmd: String,
    pub maxed: bool,
    /// Highest history event number incorporated (protocol ack).
    pub hist_ack: u64,
    /// Session-appended history lines (event number, line).
    pub hist: Vec<(u64, String)>,
}

impl SessionState {
    pub fn reset_selection(&mut self) {
        self.sel = 0;
        self.top1 = 0;
        self.top2 = 0;
        self.gridtop = 0;
        self.focus = 1;
        self.engaged = false;
    }

    /// A changed buffer invalidates the selection and lifts a dismissal
    /// (Esc hides the card for the CURRENT buffer only — clicue.zsh:239).
    pub fn on_buffer(&mut self, buffer: &str) {
        if self.last_buffer.as_deref() != Some(buffer) {
            self.last_buffer = Some(buffer.to_string());
            self.reset_selection();
            if self.suppressed_buffer.as_deref() != Some(buffer) {
                self.suppressed_buffer = None;
            }
        }
    }

    pub fn dismissed(&self, buffer: &str) -> bool {
        self.suppressed_buffer.as_deref() == Some(buffer)
    }

    pub fn dismiss(&mut self, buffer: &str) {
        self.suppressed_buffer = Some(buffer.to_string());
        self.reset_selection();
    }

    /// The line finished: everything per-line resets (clicue.zsh:413–418).
    pub fn on_line_finish(&mut self) {
        self.reset_selection();
        self.suppressed_buffer = None;
        self.last_buffer = None;
        self.expanded = false;
        self.expanded_cmd.clear();
        self.maxed = false;
    }

    /// Will the next Tab INSERT rather than move? True when the only
    /// candidate is exactly what is typed (keys.md T-rules; prototype
    /// _clicue_tab_inserts).
    pub fn tab_inserts(&self, cues: usize, _first_is_exact_pfx: bool, info: bool) -> bool {
        // A sole candidate inserts whether or not it is fully typed (T4,
        // amended): cycling a one-item list does nothing visible, and a
        // unique completion inserting on the completion key is the
        // universal contract — `cd Pr<Tab>ai<Tab>ag<Tab><Enter>` must
        // stay one gesture per level. Ambiguity earns the card.
        !info && cues == 1
    }

    /// Tab cycling within tier 1 (keys.md T5): engage, advance, wrap at
    /// the tier-1 boundary. `just_harvested` presses land on cue 1.
    pub fn tab_cycle(&mut self, t1n: usize, total: usize, just_harvested: bool) {
        // The FIRST press engages and sits on cue 1 (T3/T5: the ranked
        // top is "usually one press"); only an already-engaged press
        // advances. `sel` defaults to 1 before engagement, so advancing
        // unconditionally skipped the top cue — first Tab landed on 2,
        // masked for years by single-cue wrap [MEASURED 2026-08-03].
        let was_engaged = self.engaged;
        self.engaged = true;
        let lim = if t1n == 0 || t1n > total { total } else { t1n };
        if lim == 0 {
            return;
        }
        if just_harvested || self.sel == 0 || !was_engaged {
            self.sel = 1;
        } else {
            self.sel += 1;
            if self.sel > lim {
                self.sel = 1;
            }
        }
    }

    /// Move the one selection by delta, clamped to [1, total] — tier 1
    /// flows into the grid with nothing to switch (keys.md, layout spec).
    pub fn move_sel(&mut self, delta: i64, total: usize) -> bool {
        if !self.engaged || total == 0 {
            return false;
        }
        let cur = self.sel.max(1) as i64;
        self.sel = (cur + delta).clamp(1, total as i64) as usize;
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn command_position_rules() {
        assert_eq!(analyze("gi", 1).unwrap().mode, Mode::Cmd);
        assert_eq!(analyze("gi", 1).unwrap().pfx, "gi");
        assert_eq!(analyze("", 1), Err(StandDown::TooShort));
        assert_eq!(analyze("./run", 1), Err(StandDown::PathLike));
        assert_eq!(analyze("-x", 1), Err(StandDown::PathLike));
        // after a pipe, command position starts fresh
        let p = analyze("ls | gr", 1).unwrap();
        assert_eq!(p.mode, Mode::Cmd);
        assert_eq!(p.pfx, "gr");
    }

    #[test]
    fn argument_position_rules() {
        let p = analyze("git sta", 1).unwrap();
        assert_eq!(p.mode, Mode::Arg);
        assert_eq!(p.cmd, "git");
        assert_eq!(p.pfx, "sta");
        assert!(!p.trailing);

        let p = analyze("git ", 1).unwrap();
        assert_eq!(p.pfx, "");
        assert!(p.trailing);

        // subcommands extend the path; flags do not; the typed word doesn't
        let p = analyze("gh org list --limit 1", 1).unwrap();
        assert_eq!(p.cmdpath, "gh:org:list");
        assert!(p.optctx);

        // Pathlike is a FACT on the position now, not a verdict — the
        // engine stands down unless the command is navigational.
        assert!(analyze("cat src/ma", 1).unwrap().pathlike);
        assert!(analyze("ls ~/pro", 1).unwrap().pathlike);
        assert!(analyze("cd ../..", 1).unwrap().pathlike);
        assert!(
            analyze("cat src/ma ", 1).unwrap().pathlike,
            "same fact after the trailing space — unchanged from the Err era"
        );
    }

    #[test]
    fn dismissal_is_per_buffer_and_typing_lifts_it() {
        let mut s = SessionState::default();
        s.on_buffer("rm -r");
        s.dismiss("rm -r");
        assert!(s.dismissed("rm -r"));
        s.on_buffer("rm -rf"); // typing continues
        assert!(!s.dismissed("rm -rf"));
    }

    #[test]
    fn tab_machine() {
        let mut s = SessionState::default();
        // harvest press lands on 1, does not skip (keys.md; prototype bug note)
        s.tab_cycle(10, 40, true);
        assert_eq!(s.sel, 1);
        s.tab_cycle(10, 40, false);
        assert_eq!(s.sel, 2);
        // wraps at tier-1 boundary, not at total
        s.sel = 10;
        s.tab_cycle(10, 40, false);
        assert_eq!(s.sel, 1);
        // arrows inert until engaged
        let mut fresh = SessionState::default();
        assert!(!fresh.move_sel(1, 40));
        // engaged: selection flows past tier 1 into the grid and clamps
        assert!(s.move_sel(100, 40));
        assert_eq!(s.sel, 40);
        assert!(s.move_sel(-100, 40));
        assert_eq!(s.sel, 1);
    }

    #[test]
    fn tab_inserts_on_any_sole_candidate() {
        let s = SessionState::default();
        assert!(s.tab_inserts(1, true, false));
        assert!(!s.tab_inserts(1, true, true)); // info card
        assert!(!s.tab_inserts(2, true, false));
        assert!(
            s.tab_inserts(1, false, false),
            "a unique completion inserts — the universal contract (T4 amended)"
        );
    }
}
