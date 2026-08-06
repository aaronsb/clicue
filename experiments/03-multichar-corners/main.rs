//! Spike: can corners be multi-column STRINGS (emoji included) without
//! breaking the card's box alignment?
//!
//! Two questions, separable:
//!   1. What does unicode-width (the validator's ruler) claim for the
//!      candidate glyphs — and which candidates are trapdoors (VS16)?
//!   2. Does the proposed arithmetic — corner overhang eats the
//!      horizontal rule — tile against 1-column `v` body rows?
//!
//! Question 3 (does the TERMINAL agree with unicode-width?) cannot be
//! answered from inside this program: run probe.zsh in the real terminal.

use unicode_width::UnicodeWidthStr;

fn w(s: &str) -> usize {
    UnicodeWidthStr::width(s)
}

fn main() {
    println!("── candidate glyphs: unicode-width 0.2.2 columns ──");
    let candidates: &[(&str, &str)] = &[
        ("╭", "current rounded corner"),
        ("🎃", "jack-o-lantern U+1F383"),
        ("🦇", "bat U+1F987"),
        ("👻", "ghost U+1F47B"),
        ("💀", "skull U+1F480"),
        ("🕷", "spider U+1F577 (NO VS16 — text presentation)"),
        ("🕷\u{fe0f}", "spider + VS16 (emoji presentation)"),
        ("🕸", "web U+1F578 (NO VS16)"),
        ("🕸\u{fe0f}", "web + VS16"),
        ("⚡", "high-voltage U+26A1"),
        ("🎃─", "pumpkin + rule (2-char corner string)"),
        ("─🎃", "rule + pumpkin"),
        ("🦇🦇", "double bat"),
        ("░", "light shade U+2591 (East Asian AMBIGUOUS — like ─│ already)"),
        ("▒", "medium shade U+2592 (ambiguous)"),
        ("▓", "dark shade U+2593 (ambiguous)"),
        ("🎃▓▒░", "ramp: pumpkin greebling down into the rule"),
        ("🦇━╍╌┄", "ramp: bat through fading dashes"),
        ("▏", "left one-eighth block U+258F (partial blocks: ambiguous)"),
        ("█▊▌▎", "ramp: partial blocks full → thin"),
        ("\u{e0b0}", "powerline right triangle U+E0B0 (PUA — Nerd Font only)"),
        ("\u{e0b2}", "powerline left triangle U+E0B2"),
        ("\u{e0b1}\u{e0b1}", "powerline chevrons"),
        ("▛", "quadrant upper-left+ U+259B (PETSCII-flavoured)"),
        ("▚", "quadrant diagonal U+259A"),
        ("🭇🭄", "legacy-computing wedges U+1FB47,1FB44 (font support spotty)"),
    ];
    for (g, note) in candidates {
        println!("  {:>2} cols  {:<8} {}", w(g), format!("{g:?}"), note);
    }

    println!("\n── proposed arithmetic: overhang eats the rule, h is a cycled pattern ──");
    // Today: border_row pushes l + label + h*rule + r with
    //   rule = inner − wcols(label), inner = lw − 2
    // and the −2 assumes 1-column corners and a 1-char h. Proposal: keep
    // inner (body rows still wear 1-column `v`), shrink the RULE by the
    // corner overhang so every row spans the same lw columns:
    //   rule = inner − wcols(label) − (wcols(l)−1) − (wcols(r)−1)
    // and fill the rule by CYCLING h's chars (each 1 column) instead of
    // repeating a single char — h="─" behaves exactly as before.
    let fill = |h: &str, rule: usize| -> String { h.chars().cycle().take(rule).collect() };
    let render = |lw: usize, tl: &str, tr: &str, bl: &str, br: &str, h: &str, label: &str| {
        let inner = lw - 2;
        let top_rule = inner
            .saturating_sub(w(label))
            .saturating_sub(w(tl) - 1)
            .saturating_sub(w(tr) - 1)
            .max(1);
        let bot_rule = inner
            .saturating_sub(w(bl) - 1)
            .saturating_sub(w(br) - 1)
            .max(1);
        println!("{tl}{label}{}{tr}", fill(h, top_rule));
        for text in ["▸ git      the stupid content tracker", "  gitui    terminal-ui for git"] {
            let pad = inner.saturating_sub(w(text));
            println!("│{text}{}│", " ".repeat(pad));
        }
        println!("{bl}{}{br}", fill(h, bot_rule));
        // The tiling check unicode-width can do for us:
        let widths = [
            w(tl) + w(label) + top_rule + w(tr),
            1 + inner + 1,
            w(bl) + bot_rule + w(br),
        ];
        let ok = widths.iter().all(|&x| x == lw);
        println!("row widths {widths:?} vs lw={lw}  →  {}", if ok { "TILES" } else { "BROKEN" });
        println!();
    };

    render(46, "╭", "╮", "╰", "╯", "─", " cmd ");
    render(46, "🎃", "🎃", "🦇", "🦇", "─", " cmd ");
    render(46, "💀💀💀", "💀💀💀", "👻", "👻", "─", " spooky ");
    println!("── ramps: big corner greebling down into the rule ──");
    render(46, "🎃▓▒░", "░▒▓🎃", "🦇▓▒░", "░▒▓🦇", "─", " cmd ");
    render(46, "🦇━╍╌┄", "┄╌╍━🦇", "👻━╍╌┄", "┄╌╍━👻", "┄", " cmd ");
    render(46, "⚡▓▒░", "░▒▓⚡", "⚡▒░", "░▒⚡", "░", " cyber ");
    println!("── patterned h: the rest of the border is UTF too ──");
    render(46, "╭", "╮", "╰", "╯", "─┄", " cmd ");
    render(46, "🎃▓▒", "▒▓🎃", "🎃▓▒", "▒▓🎃", "░▒", " spooky ");

    println!("── other theme concepts, same arithmetic ──");
    // heavy-metal: partial-block ramp, full block thinning into the rule
    render(46, "█▊▌▎", "▎▌▊█", "█▊▌▎", "▎▌▊█", "─", " metal ");
    // powerline / oh-my-posh: block caps ending in PUA triangles
    render(46, "█\u{e0b0}", "\u{e0b2}█", "█\u{e0b0}", "\u{e0b2}█", "─", " seg ");
    render(46, "\u{e0b6}█\u{e0b0}", "\u{e0b2}█\u{e0b4}", "\u{e0b6}█\u{e0b0}", "\u{e0b2}█\u{e0b4}", "\u{e0b1}", " posh ");
    // petscii: quadrant corners — WANTS a different rule per edge
    // (▀ on top, ▄ on bottom); with one h the bottom reads inverted.
    render(46, "▛", "▜", "▙", "▟", "▀", " c64 ");
    render(46, "▞▚", "▞▚", "▚▞", "▚▞", "▚▞", " c64 ");
}
