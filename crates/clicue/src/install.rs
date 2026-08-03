//! Install/uninstall: one line in the rc file, doctor-gated, diff shown.
//!
//! ADR-100: `clicue install` runs the doctor first, refuses on fighters
//! unless forced, detects plugin managers (their load discipline beats our
//! guess — print instructions instead of editing), and otherwise appends
//! ONE idempotent line to the right rc file, showing the diff before
//! writing. Uninstall is symmetric. The pure functions here never touch
//! the real HOME — the callers pass paths, the tests pass temp dirs.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

/// The one line. `eval` of the emitted shim is the zoxide pattern: the
/// shim is generated output, so shim and daemon versions cannot drift.
pub const INSTALL_LINE: &str = r#"eval "$(clicue init zsh)""#;
/// Marker comment so uninstall can also remove an annotated line.
pub const MARKER: &str = "# clicue — live command guidance (managed by `clicue install`)";
/// compinit, added ONLY when the probed shell never ran it (stock macOS
/// zshrc, fresh zsh): the compsys bridge needs _main_complete, and a
/// doctor warning alone leaves a stock install half-working with no
/// visible reason. Tagged so uninstall removes exactly this line and
/// never a compinit the operator wrote themselves.
pub const COMPINIT_LINE: &str =
    "autoload -Uz compinit && compinit -i   # clicue: flag harvesting needs compsys";

/// Which rc file owns the shim line: `$ZDOTDIR/.zshrc` when ZDOTDIR is
/// set in the probed shell, else `~/.zshrc`.
pub fn rc_path(home: &Path, zdotdir: Option<&Path>) -> PathBuf {
    zdotdir.unwrap_or(home).join(".zshrc")
}

pub fn installed_in(text: &str) -> bool {
    text.lines().any(|l| {
        let t = l.trim();
        !t.starts_with('#') && t.contains("clicue init zsh")
    })
}

/// Appended block: marker (+ compinit when the shell lacks it) + line,
/// separated from existing content.
pub fn with_line_appended(text: &str, add_compinit: bool) -> String {
    let mut out = text.to_string();
    if !out.is_empty() && !out.ends_with('\n') {
        out.push('\n');
    }
    if !out.is_empty() {
        out.push('\n');
    }
    out.push_str(MARKER);
    out.push('\n');
    if add_compinit {
        out.push_str(COMPINIT_LINE);
        out.push('\n');
    }
    out.push_str(INSTALL_LINE);
    out.push('\n');
    out
}

/// Remove our marker and any non-comment line evaluating the shim.
pub fn with_line_removed(text: &str) -> String {
    let mut out: Vec<&str> = Vec::new();
    for l in text.lines() {
        let t = l.trim();
        if t == MARKER {
            continue;
        }
        if !t.starts_with('#') && t.contains("clicue init zsh") {
            continue;
        }
        if t == COMPINIT_LINE {
            continue; // ours, by exact spelling — never a hand-written compinit
        }
        out.push(l);
    }
    let mut s = out.join("\n");
    if !s.is_empty() && !s.ends_with('\n') {
        s.push('\n');
    }
    s
}

/// Plugin manager detection from the doctor's probe map. When one is in
/// play, its own load discipline decides placement — we instruct, never
/// edit (ADR-100).
pub fn manager_of(probe: &BTreeMap<String, String>) -> Option<&'static str> {
    let truthy = |k: &str| probe.get(k).map(|v| v == "1").unwrap_or(false);
    if truthy("zinit") {
        Some("zinit")
    } else if truthy("antidote") {
        Some("antidote")
    } else if truthy("zim") {
        Some("zim")
    } else if truthy("omz") {
        Some("oh-my-zsh")
    } else {
        None
    }
}

pub fn manager_instructions(manager: &str) -> String {
    let common = format!(
        "Add this line AFTER your plugin loads (compinit and zsh-autosuggestions must\n\
         come first — doctor X3):\n\n    {INSTALL_LINE}\n"
    );
    match manager {
        "oh-my-zsh" => format!(
            "oh-my-zsh detected. Put the line at the END of ~/.zshrc, after\n\
             `source $ZSH/oh-my-zsh.sh`:\n\n    {INSTALL_LINE}\n"
        ),
        "zinit" => format!(
            "zinit detected. {common}\
             (after your last `zinit load`/`zinit light` and any `zicompinit`)."
        ),
        "antidote" => format!(
            "antidote detected. {common}\
             (after `antidote load`)."
        ),
        "zim" => format!(
            "zim detected. {common}\
             (after `source $ZIM_HOME/init.zsh`)."
        ),
        other => format!("{other} detected. {common}"),
    }
}

/// A minimal unified-ish diff of the change for the operator to approve.
pub fn render_diff(path: &Path, before: &str, after: &str) -> String {
    let mut s = format!(
        "--- {}\n+++ {} (proposed)\n",
        path.display(),
        path.display()
    );
    for l in before.lines() {
        if !after.contains(l) {
            s += &format!("- {l}\n");
        }
    }
    for l in after.lines() {
        if !before.contains(l) {
            s += &format!("+ {l}\n");
        }
    }
    s
}

pub struct InstallOpts {
    pub yes: bool,
    pub force: bool,
}

fn confirm(prompt: &str) -> Result<bool> {
    print!("{prompt} [y/N] ");
    std::io::stdout().flush()?;
    let mut line = String::new();
    std::io::stdin().read_line(&mut line)?;
    Ok(matches!(line.trim(), "y" | "Y" | "yes"))
}

/// `clicue install`. Doctor first; fighters refuse unless --force;
/// manager present → instructions; else append with diff + confirmation.
pub fn install(opts: &InstallOpts) -> Result<i32> {
    let probe = crate::doctor::run_probe()?;
    let findings = crate::doctor::evaluate(
        &probe,
        &crate::doctor::check_daemon(),
        &crate::doctor::corpus_state(),
    );
    let code = crate::doctor::print_findings(&findings, &mut std::io::stdout());
    if code != 0 && !opts.force {
        bail!("doctor found fighters — resolve them, or rerun with --force");
    }

    // Theme files before rc wiring (T14): the themes directory should be
    // browsable and editable from the first moment, and this is idempotent
    // — only files that don't exist are written, so a re-run after an
    // upgrade tops up new themes without touching edits.
    if let Some(dir) = crate::config::themes_dir() {
        let n = crate::theme::seed_all(&dir);
        if n > 0 {
            println!("seeded {n} theme file(s) into {}", dir.display());
        }
    }

    if let Some(mgr) = manager_of(&probe) {
        println!("{}", manager_instructions(mgr));
        return Ok(0);
    }

    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")?;
    let zdot = probe
        .get("zdotdir")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let rc = rc_path(&home, zdot.as_deref());
    let before = std::fs::read_to_string(&rc).unwrap_or_default();
    if installed_in(&before) {
        println!(
            "already installed: {} references `clicue init zsh`",
            rc.display()
        );
        return Ok(0);
    }
    // compinit=0 in the probe means the loaded shell has no compsys —
    // the stock-zshrc case; the block carries its own fix.
    let add_compinit = probe.get("compinit").map(|v| v != "1").unwrap_or(true);
    let after = with_line_appended(&before, add_compinit);
    println!("{}", render_diff(&rc, &before, &after));
    if !opts.yes && !confirm(&format!("append to {}?", rc.display()))? {
        println!("nothing written.");
        return Ok(1);
    }
    std::fs::write(&rc, after).with_context(|| format!("writing {}", rc.display()))?;
    println!(
        "installed. Open a new shell (or `source {}`).",
        rc.display()
    );
    Ok(0)
}

/// `clicue uninstall`: remove our line(s), diff shown, confirmation asked.
pub fn uninstall(yes: bool) -> Result<i32> {
    let home = std::env::var_os("HOME")
        .map(PathBuf::from)
        .context("HOME is not set")?;
    let zdot = std::env::var_os("ZDOTDIR")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from);
    let rc = rc_path(&home, zdot.as_deref());
    let before = std::fs::read_to_string(&rc).unwrap_or_default();
    if !installed_in(&before) {
        println!("nothing to remove: {} has no clicue line", rc.display());
        return Ok(0);
    }
    let after = with_line_removed(&before);
    println!("{}", render_diff(&rc, &before, &after));
    if !yes && !confirm(&format!("write {}?", rc.display()))? {
        println!("nothing written.");
        return Ok(1);
    }
    std::fs::write(&rc, after).with_context(|| format!("writing {}", rc.display()))?;
    // "Removes exactly what install added": a seeded theme file the
    // operator EDITED is no longer what install added — it stays.
    if let Some(dir) = crate::config::themes_dir() {
        let removed = remove_pristine_themes(&dir);
        if removed > 0 {
            println!(
                "removed {removed} unedited theme file(s) from {}",
                dir.display()
            );
        }
    }
    println!("uninstalled. Running shells keep the shim until they exit (`clicue-off` disables it live).");
    Ok(0)
}

/// Delete seeded theme files whose content still matches the template
/// byte-for-byte; edited files are operator data and stay. Returns how
/// many were removed; the directory itself goes too once empty.
pub fn remove_pristine_themes(dir: &std::path::Path) -> usize {
    let mut removed = 0;
    for name in crate::theme::builtin_names() {
        let path = dir.join(format!("{name}.toml"));
        if let (Ok(content), Some(t)) =
            (std::fs::read_to_string(&path), crate::theme::builtin(name))
        {
            if content == crate::theme::to_toml(&t) && std::fs::remove_file(&path).is_ok() {
                removed += 1;
            }
        }
    }
    let _ = std::fs::remove_dir(dir); // only succeeds when empty
    removed
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Removal matches this literal by exact spelling: changing it
    /// orphans the compinit lines OLDER versions wrote into rc files —
    /// which, unlike an orphaned marker, changes shell behavior. A
    /// respelling requires a removal migration for the old form.
    #[test]
    fn compinit_line_literal_is_the_on_disk_contract() {
        assert_eq!(
            COMPINIT_LINE,
            "autoload -Uz compinit && compinit -i   # clicue: flag harvesting needs compsys"
        );
        // -i: skip insecure dirs silently instead of prompting at every
        // startup (Homebrew's group-writable share/zsh is the classic
        // trigger; a doctor probe with stdin closed would abort on the
        // prompt and misreport compinit=0 forever).
        assert!(COMPINIT_LINE.contains("compinit -i"));
    }

    #[test]
    fn append_is_idempotent_via_installed_in() {
        let rc = "export PATH=$PATH:/opt/bin\n";
        assert!(!installed_in(rc));
        let once = with_line_appended(rc, false);
        assert!(installed_in(&once));
        assert!(once.contains(MARKER));
        assert!(
            !once.contains("compinit"),
            "compsys-having shells get no compinit"
        );
        assert!(once.ends_with('\n'));
        // a commented-out line does not count as installed
        let commented = format!("# {INSTALL_LINE}\n");
        assert!(!installed_in(&commented));
    }

    #[test]
    fn remove_round_trips_to_original() {
        let rc = "# mine\nalias ll='ls -l'\n";
        let installed = with_line_appended(rc, true);
        assert!(installed.contains(COMPINIT_LINE));
        let removed = with_line_removed(&installed);
        assert!(!installed_in(&removed));
        assert!(removed.contains("alias ll"));
        assert!(!removed.contains(MARKER));
        assert!(!removed.contains("compinit"), "our compinit line goes too");
        // an operator's own compinit spelling survives removal
        let theirs = "autoload -Uz compinit\ncompinit -u\n";
        assert_eq!(with_line_removed(theirs), theirs);
    }

    #[test]
    fn manager_detection_prefers_explicit_managers_over_omz_var() {
        let probe: BTreeMap<String, String> = [("zinit", "1"), ("omz", "1")]
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect();
        assert_eq!(manager_of(&probe), Some("zinit"));
        let none: BTreeMap<String, String> = BTreeMap::new();
        assert_eq!(manager_of(&none), None);
        for m in ["oh-my-zsh", "zinit", "antidote", "zim"] {
            assert!(manager_instructions(m).contains(INSTALL_LINE));
        }
    }

    #[test]
    fn rc_path_honours_zdotdir() {
        let home = Path::new("/home/x");
        assert_eq!(rc_path(home, None), PathBuf::from("/home/x/.zshrc"));
        assert_eq!(
            rc_path(home, Some(Path::new("/home/x/.config/zsh"))),
            PathBuf::from("/home/x/.config/zsh/.zshrc")
        );
    }

    #[test]
    fn diff_shows_only_the_change() {
        let before = "a\nb\n";
        let after = with_line_appended(before, false);
        let d = render_diff(Path::new("/tmp/rc"), before, &after);
        assert!(d.contains(&format!("+ {INSTALL_LINE}")));
        assert!(!d.contains("- a"));
    }
}
