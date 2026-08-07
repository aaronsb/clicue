//! The doctor: probe a live zsh, never parse config text (spec/doctor.md M1).
//!
//! One captive `zsh -ic` run emits `key=value` lines; findings are derived
//! from that map plus daemon/corpus checks done Rust-side. Severity is the
//! spec's taxonomy: fighter (genuine conflict), degradation (works, worse,
//! and would otherwise be silent), info (worth knowing).

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixStream;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use anyhow::{Context, Result};

use crate::{corpus, daemon, protocol};

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub enum Severity {
    Fighter,
    Degradation,
    Info,
}

impl Severity {
    fn label(self) -> &'static str {
        match self {
            Severity::Fighter => "FIGHTER",
            Severity::Degradation => "degraded",
            Severity::Info => "info",
        }
    }
}

#[derive(Debug, Clone)]
pub struct Finding {
    pub severity: Severity,
    pub title: String,
    pub detail: String,
}

fn finding(severity: Severity, title: &str, detail: String) -> Finding {
    Finding {
        severity,
        title: title.into(),
        detail,
    }
}

/// The zsh probe. Everything is read from the LOADED shell state —
/// functions, widgets, options, bindings — one `key=value` per line.
/// `${+name}` and option/bindkey inspection only; nothing is executed
/// beyond what an interactive startup already ran.
pub fn probe_script() -> String {
    // Keep this ASCII and one statement per line: the output is parsed by
    // splitting on the FIRST '=' of each line.
    r#"
print -r -- "zsh_version=$ZSH_VERSION"
print -r -- "zdotdir=$ZDOTDIR"
print -r -- "autocomplete=$(( ${+functions[.autocomplete:async:start]} || ${+functions[_autocomplete]} ))"
print -r -- "fzf_tab=${+functions[fzf-tab-complete]}"
print -r -- "autosuggest=${+functions[_zsh_autosuggest_start]}"
print -r -- "autosuggest_async=${+functions[_zsh_autosuggest_async_response]}"
print -r -- "tab_owner=${${(z)$(bindkey '^I')}[2]:-none}"
print -r -- "up_owner=${${(z)$(bindkey '^[[A')}[2]:-none}"
print -r -- "down_owner=${${(z)$(bindkey '^[[B')}[2]:-none}"
print -r -- "right_owner=${${(z)$(bindkey '^[[C')}[2]:-none}"
print -r -- "left_owner=${${(z)$(bindkey '^[[D')}[2]:-none}"
print -r -- "up_o_owner=${${(z)$(bindkey '^[OA')}[2]:-none}"
print -r -- "down_o_owner=${${(z)$(bindkey '^[OB')}[2]:-none}"
print -r -- "right_o_owner=${${(z)$(bindkey '^[OC')}[2]:-none}"
print -r -- "left_o_owner=${${(z)$(bindkey '^[OD')}[2]:-none}"
print -r -- "enter_owner=${${(z)$(bindkey '^M')}[2]:-none}"
print -r -- "home_owner=${${(z)$(bindkey '^[[H')}[2]:-none}"
print -r -- "end_owner=${${(z)$(bindkey '^[[F')}[2]:-none}"
print -r -- "home_o_owner=${${(z)$(bindkey '^[OH')}[2]:-none}"
print -r -- "end_o_owner=${${(z)$(bindkey '^[OF')}[2]:-none}"
print -r -- "home_t_owner=${${(z)$(bindkey '^[[1~')}[2]:-none}"
print -r -- "end_t_owner=${${(z)$(bindkey '^[[4~')}[2]:-none}"
print -r -- "pgup_owner=${${(z)$(bindkey '^[[5~')}[2]:-none}"
print -r -- "pgdn_owner=${${(z)$(bindkey '^[[6~')}[2]:-none}"
print -r -- "ext_history=${options[extendedhistory]}"
print -r -- "ignore_all_dups=${options[histignorealldups]}"
print -r -- "histsize=$HISTSIZE"
print -r -- "savehist=$SAVEHIST"
print -r -- "whatis=${+commands[whatis]}"
print -r -- "konsole=${+KONSOLE_DBUS_SESSION}"
print -r -- "compinit=${+functions[_main_complete]}"
print -r -- "proto_theme_load=${+functions[_clicue_theme_load]}"
print -r -- "proto_src=${$(whence -v _clicue_pre_redraw 2>/dev/null)##* }"
print -r -- "shim_loaded=${+functions[_clicue_hello]}"
print -r -- "omz=${+ZSH}"
print -r -- "zinit=${+functions[zinit]}"
print -r -- "antidote=${+functions[antidote]}"
print -r -- "zim=${+functions[zimfw]}"
"#
    .trim()
    .to_string()
}

/// Run the probe in a captive interactive zsh with a hard timeout — an rc
/// file that blocks on input must not hang the doctor. Captive means NO
/// controlling terminal (setsid), not just a null stdin: compinit's
/// compaudit prompt and every "press any key" rc read go to /dev/tty
/// directly, bypassing stdin — with no ctty they abort instantly instead
/// of hanging the probe. [MEASURED: ubuntu-latest, whose global zsh rc
/// runs compinit; under a pty its insecure-dirs prompt ate the whole 10s.]
pub fn run_probe() -> Result<BTreeMap<String, String>> {
    let mut cmd = Command::new("zsh");
    cmd.args(["-ic", &probe_script()])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    // Safety: setsid is async-signal-safe; nothing else runs pre-exec.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    let mut child = cmd.spawn().context("spawning zsh — is zsh installed?")?;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        match child.try_wait()? {
            Some(_) => break,
            None if Instant::now() > deadline => {
                let _ = child.kill();
                anyhow::bail!(
                    "zsh probe did not finish within 10s — an rc file may be blocking on input"
                );
            }
            None => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    let mut out = String::new();
    if let Some(mut stdout) = child.stdout.take() {
        use std::io::Read;
        let _ = stdout.read_to_string(&mut out);
    }
    Ok(parse_probe(&out))
}

/// `key=value` lines → map. Interactive startups print MOTDs and prompts;
/// only lines whose key looks like a probe key are taken.
pub fn parse_probe(out: &str) -> BTreeMap<String, String> {
    let mut map = BTreeMap::new();
    for line in out.lines() {
        if let Some((k, v)) = line.split_once('=') {
            let k = k.trim();
            if !k.is_empty() && k.chars().all(|c| c.is_ascii_alphanumeric() || c == '_') {
                map.insert(k.to_string(), v.trim().to_string());
            }
        }
    }
    map
}

/// Daemon reachability, checked Rust-side: connect, send a minimal
/// hello frame, read one reply line.
#[derive(Debug, Clone)]
pub enum DaemonStatus {
    Unreachable(String),
    Answering,
    VersionMismatch(String),
}

pub fn check_daemon() -> DaemonStatus {
    let path = match daemon::socket_path() {
        Ok(p) => p,
        Err(e) => return DaemonStatus::Unreachable(e.to_string()),
    };
    let stream = match UnixStream::connect(&path) {
        Ok(s) => s,
        Err(e) => return DaemonStatus::Unreachable(format!("{}: {e}", path.display())),
    };
    let _ = stream.set_read_timeout(Some(Duration::from_millis(500)));
    let mut w = match stream.try_clone() {
        Ok(w) => w,
        Err(e) => return DaemonStatus::Unreachable(e.to_string()),
    };
    let req = format!(
        r#"{{"v":{},"session":{{"pid":{},"start":0}},"event":{{"kind":"hello"}},"buffer":"","cursor":0,"cols":80,"lines":24,"keymap":"main"}}"#,
        protocol::VERSION,
        std::process::id()
    );
    if w.write_all(req.as_bytes())
        .and_then(|_| w.write_all(b"\n"))
        .is_err()
    {
        return DaemonStatus::Unreachable("write failed".into());
    }
    let mut line = String::new();
    match BufReader::new(stream).read_line(&mut line) {
        Ok(n) if n > 0 => {
            if line.contains("\"error\"") {
                DaemonStatus::VersionMismatch(line.trim().to_string())
            } else {
                DaemonStatus::Answering
            }
        }
        _ => DaemonStatus::Unreachable("no reply within 500ms".into()),
    }
}

fn truthy(map: &BTreeMap<String, String>, key: &str) -> bool {
    map.get(key).map(|v| v == "1").unwrap_or(false)
}

fn on(map: &BTreeMap<String, String>, key: &str) -> bool {
    map.get(key).map(|v| v == "on").unwrap_or(false)
}

/// Derive findings from the probe (spec/doctor.md F/X/D/T/P) plus the
/// Rust-side daemon and corpus checks.
pub fn evaluate(
    probe: &BTreeMap<String, String>,
    daemon_status: &DaemonStatus,
    corpus_state: &str,
) -> Vec<Finding> {
    let mut f = Vec::new();
    let get = |k: &str| probe.get(k).map(String::as_str).unwrap_or("");

    // ── fighters ────────────────────────────────────────────────────────
    if truthy(probe, "autocomplete") {
        f.push(finding(
            Severity::Fighter,
            "zsh-autocomplete is loaded",
            "It rebuilds compadd, owns Tab, and draws its own listing — a genuine conflict \
             (doctor F1). Remove it from your zsh config before installing clicue."
                .into(),
        ));
    }
    // The prototype in the same shell IS a fighter: same POSTDISPLAY, same
    // Tab, same widget names one generation apart.
    let proto_src = get("proto_src");
    if truthy(probe, "proto_theme_load")
        || (proto_src.contains("clicue") && proto_src.ends_with(".zsh"))
    {
        f.push(finding(
            Severity::Fighter,
            "the clicue PROTOTYPE is loaded in this shell",
            format!(
                "Loaded from {proto_src}. The prototype and the daemon shim would fight over \
                 POSTDISPLAY and Tab. Disable the conf.d file that sources it \
                 (e.g. ~/.zsh/conf.d/45-clicue) before `clicue install`."
            ),
        ));
    }
    if truthy(probe, "fzf_tab") {
        f.push(finding(
            Severity::Fighter,
            "fzf-tab owns Tab",
            "clicue delegates Tab to whatever owned it, so fzf-tab still works — but two \
             candidate UIs on one keystroke is a choice to make knowingly (doctor F2). \
             Keep whichever you prefer, or install with --force to run both."
                .into(),
        ));
    }

    // ── coexistence ────────────────────────────────────────────────────
    if truthy(probe, "autosuggest") {
        let ok = truthy(probe, "autosuggest_async");
        let detail = if ok {
            "clicue supersedes its ghost text and wraps its async response by name — the \
             loaded version exposes the expected functions (doctor X1)."
        } else {
            "Loaded, but _zsh_autosuggest_async_response is absent — an unknown version; \
             the shim's wrap may miss and the two ghosts may fight (doctor X1)."
        };
        f.push(finding(
            if ok {
                Severity::Info
            } else {
                Severity::Degradation
            },
            "zsh-autosuggestions is loaded",
            detail.into(),
        ));
    }
    if !truthy(probe, "compinit") {
        f.push(finding(
            Severity::Degradation,
            "compinit has not run",
            "The compsys bridge needs _main_complete; flag harvesting will be empty until \
             compinit runs before the shim loads (doctor X3)."
                .into(),
        ));
    }
    if truthy(probe, "shim_loaded") {
        f.push(finding(
            Severity::Info,
            "clicue shim already loaded",
            "This shell already runs the shim; `clicue install` would be a no-op.".into(),
        ));
        // Keys the shim binds must still POINT at the shim once the rc has
        // finished loading. A later bindkey silently disconnects that key:
        // the operator's Down going to history-substring-search instead of
        // the card is how "there's no way into the grid" happens — while
        // doctor reports no fighters. Binding order is the whole fallback
        // design: clicue binds LAST, captures the previous owner, and
        // delegates to it whenever the card is not engaged.
        // Every sequence the shim binds, INCLUDING the application-mode
        // (smkx) ^[O… variants — zle enables smkx while editing, so many
        // terminals send those during live keystrokes; a plugin rebinding
        // only that spelling steals keys a CSI-only probe calls clean.
        // Skips: "" is a probe key an older probe never emitted; "none"
        // is defensive (an unbound key actually reports `undefined-key`,
        // which stays FLAGGED — the shim bound all of these, so unbound
        // means someone ran bindkey -r after it). (doctor F3)
        let stolen: Vec<String> = [
            ("Tab", "^I", "tab_owner"),
            ("Up", "^[[A", "up_owner"),
            ("Down", "^[[B", "down_owner"),
            ("Right", "^[[C", "right_owner"),
            ("Left", "^[[D", "left_owner"),
            ("Up", "^[OA", "up_o_owner"),
            ("Down", "^[OB", "down_o_owner"),
            ("Right", "^[OC", "right_o_owner"),
            ("Left", "^[OD", "left_o_owner"),
            ("Enter", "^M", "enter_owner"),
            ("Home", "^[[H", "home_owner"),
            ("End", "^[[F", "end_owner"),
            ("Home", "^[OH", "home_o_owner"),
            ("End", "^[OF", "end_o_owner"),
            ("Home", "^[[1~", "home_t_owner"),
            ("End", "^[[4~", "end_t_owner"),
            ("PgUp", "^[[5~", "pgup_owner"),
            ("PgDn", "^[[6~", "pgdn_owner"),
        ]
        .iter()
        .filter_map(|(name, seq, key)| {
            let owner = get(key);
            (!owner.is_empty() && owner != "none" && !owner.starts_with("_clicue_"))
                .then(|| format!("{name} ({seq}) → {owner}"))
        })
        .collect();
        if !stolen.is_empty() {
            f.push(finding(
                Severity::Fighter,
                "keys rebound after clicue loaded",
                format!(
                    "{}. Something in the rc binds these AFTER the shim, so they never \
                     reach the card (arrows cannot enter the grid, Enter cannot compose). \
                     Move those bindkey calls BEFORE the clicue eval — the shim captures \
                     the previous owner and delegates to it whenever the card is not \
                     engaged, so the original behavior survives when clicue binds last.",
                    stolen.join(", ")
                ),
            ));
        }
    }
    let tab_owner = get("tab_owner");
    if !truthy(probe, "shim_loaded")
        && !matches!(
            tab_owner,
            "" | "none"
                | "expand-or-complete"
                | "complete-word"
                | "expand-or-complete-prefix"
                | "menu-complete"
                | "_clicue_w_accept"
        )
        && !truthy(probe, "fzf_tab")
        && !truthy(probe, "autocomplete")
    {
        f.push(finding(
            Severity::Info,
            "Tab has a custom owner",
            format!(
                "bindkey '^I' → {tab_owner}. clicue will delegate to it whenever the card \
                 has nothing to do (doctor F2)."
            ),
        ));
    }

    // ── degradations ───────────────────────────────────────────────────
    if !on(probe, "ext_history") {
        f.push(finding(
            Severity::Degradation,
            "EXTENDED_HISTORY is off",
            "History carries no timestamps, so the recency signal is empty and \
             frecency/recency silently behave as plain frequency (doctor D1). \
             Add `setopt EXTENDED_HISTORY` to your zshrc."
                .into(),
        ));
    }
    let histsize: u64 = get("histsize").parse().unwrap_or(0);
    if histsize > 0 && histsize < 1000 {
        f.push(finding(
            Severity::Degradation,
            "HISTSIZE is small",
            format!(
                "HISTSIZE={histsize}: a thin corpus ranks weakly (doctor D2). \
                 Several thousand lines make the habit signal real."
            ),
        ));
    }
    if !truthy(probe, "whatis") {
        f.push(finding(
            Severity::Degradation,
            "whatis is not installed",
            "No glosses for system commands — the card works but loses its descriptions \
             (doctor D3). Install man-db and run mandb once."
                .into(),
        ));
    }
    if on(probe, "ignore_all_dups") {
        f.push(finding(
            Severity::Info,
            "HIST_IGNORE_ALL_DUPS is set",
            "Fine, and designed for: invocation ranking uses recency precisely because a \
             de-duplicated history makes counts meaningless (doctor D4). Nothing to change."
                .into(),
        ));
    }

    // ── terminal ───────────────────────────────────────────────────────
    if truthy(probe, "konsole") {
        f.push(finding(
            Severity::Info,
            "konsole eats Shift+Up/Down",
            "The terminal claims them for Scroll Line Up/Down, so those keystrokes never \
             reach zsh; Alt+↑↓ works. To free Shift: Settings → Configure Keyboard \
             Shortcuts (doctor T1)."
                .into(),
        ));
    }

    // ── daemon / corpus ────────────────────────────────────────────────
    match daemon_status {
        DaemonStatus::Answering => f.push(finding(
            Severity::Info,
            "daemon is answering",
            "Socket reachable, protocol version agrees.".into(),
        )),
        DaemonStatus::VersionMismatch(frame) => f.push(finding(
            Severity::Degradation,
            "daemon protocol mismatch",
            format!(
                "The daemon answered with an error frame: {frame}. Restart it (a mid-upgrade \
                 daemon serves the old version until restarted)."
            ),
        )),
        DaemonStatus::Unreachable(why) => f.push(finding(
            Severity::Info,
            "daemon is not running",
            format!("{why}. The shim auto-spawns one on first use; nothing to do."),
        )),
    }
    f.push(finding(Severity::Info, "corpus", corpus_state.to_string()));

    // ── privacy posture, always (doctor P1) ────────────────────────────
    f.push(finding(
        Severity::Info,
        "data posture",
        "Everything is derived from your shell history; nothing is instrumented. \
         Space-prefixed commands are never learned (HIST_IGNORE_SPACE). \
         `clicue data forget <cmd>` removes a habit retroactively."
            .into(),
    ));

    f
}

pub fn corpus_state() -> String {
    match corpus::cache_path() {
        Ok(cache) => match corpus::load(&cache) {
            Ok(c) => {
                // Same classifier as `clicue data` (S6): two surfaces
                // disagreeing about the same corpus undermine the right one.
                // Trailing history is the working state of a live shell.
                let state = corpus::default_histfile()
                    .map(|h| corpus::staleness(&c, &corpus::stamp(&h, &corpus::path_dirs())))
                    .unwrap_or(corpus::Staleness::Structural);
                match state {
                    corpus::Staleness::Structural => format!(
                        "{} — STALE ({} glosses, {} invocations); run `clicue data rebuild`",
                        cache.display(),
                        c.gloss.len(),
                        c.invoke.len()
                    ),
                    _ => format!(
                        "{} — current ({} glosses, {} invocations)",
                        cache.display(),
                        c.gloss.len(),
                        c.invoke.len()
                    ),
                }
            }
            Err(_) => format!(
                "absent at {} — built automatically at first daemon start",
                cache.display()
            ),
        },
        Err(e) => format!("location unresolvable: {e}"),
    }
}

/// Full doctor run: probe, evaluate, print grouped by severity.
/// Returns the process exit code: 1 if any fighter, else 0.
pub fn run() -> Result<i32> {
    let probe = run_probe()?;
    let mut findings = evaluate(&probe, &check_daemon(), &corpus_state());
    findings.extend(check_themes());
    Ok(print_findings(&findings, &mut std::io::stdout()))
}

/// D5: theme health. The daemon never fails on a broken theme — it falls
/// back and says so only on its own stderr, which nobody reads. Doctor is
/// where the fallback becomes visible.
pub fn check_themes() -> Vec<Finding> {
    theme_findings(
        &crate::config::load().config.theme,
        crate::config::themes_dir().as_deref(),
    )
}

pub fn theme_findings(active: &str, dir: Option<&std::path::Path>) -> Vec<Finding> {
    use crate::theme;
    let mut f = Vec::new();
    let (_t, msgs) = theme::load(active, dir);
    if msgs.is_empty() {
        f.push(finding(
            Severity::Info,
            "theme",
            format!(
                "'{active}' loads cleanly ({} available)",
                theme::available(dir).len()
            ),
        ));
    } else {
        f.push(finding(
            Severity::Degradation,
            "active theme does not load",
            format!(
                "cards render a fallback instead of '{active}': {}",
                msgs.join("; ")
            ),
        ));
    }
    // Sweep the rest of the directory: a broken file only bites when
    // selected — name it now, not then.
    if let Some(d) = dir {
        let mut broken: Vec<String> = Vec::new();
        if let Ok(entries) = std::fs::read_dir(d) {
            for e in entries.flatten() {
                let p = e.path();
                if p.extension().and_then(|x| x.to_str()) != Some("toml") {
                    continue;
                }
                let Some(stem) = p.file_stem().and_then(|x| x.to_str()) else {
                    continue;
                };
                if stem == active || stem.starts_with('.') {
                    continue;
                }
                let ok = std::fs::read_to_string(&p)
                    .map(|src| theme::from_toml(stem, &src).is_ok())
                    .unwrap_or(false);
                if !ok {
                    broken.push(stem.to_string());
                }
            }
        }
        if !broken.is_empty() {
            broken.sort();
            f.push(finding(
                Severity::Info,
                "theme files with problems",
                format!(
                    "{} — harmless until selected; `clicue theme preview <name>` names the \
                     errors, deleting a file regenerates the shipped version",
                    broken.join(", ")
                ),
            ));
        }
    }
    f
}

pub fn print_findings(findings: &[Finding], out: &mut impl Write) -> i32 {
    let mut fighters = 0;
    for severity in [Severity::Fighter, Severity::Degradation, Severity::Info] {
        let group: Vec<_> = findings.iter().filter(|f| f.severity == severity).collect();
        if group.is_empty() {
            continue;
        }
        for f in group {
            if severity == Severity::Fighter {
                fighters += 1;
            }
            let _ = writeln!(out, "[{}] {}", severity.label(), f.title);
            for line in f.detail.lines() {
                let _ = writeln!(out, "    {}", line.trim());
            }
        }
        let _ = writeln!(out);
    }
    if fighters > 0 {
        let _ = writeln!(
            out,
            "{fighters} fighter(s) found — resolve them (before `clicue install`, \
             or in the rc if clicue is already loaded)."
        );
        1
    } else {
        let _ = writeln!(out, "no fighters — safe to `clicue install`.");
        0
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn probe_with(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
        pairs
            .iter()
            .map(|(k, v)| (k.to_string(), v.to_string()))
            .collect()
    }

    #[test]
    fn probe_script_is_parseable_shape() {
        let s = probe_script();
        assert!(s.contains("tab_owner="));
        assert!(s.contains("proto_src="));
        for line in s.lines() {
            assert!(line.starts_with("print -r -- \""), "{line}");
        }
    }

    #[test]
    fn parse_probe_ignores_motd_noise() {
        let out =
            "Welcome to zsh!\nzsh_version=5.9\nnot a probe line\ntab_owner=fzf-tab-complete\n";
        let m = parse_probe(out);
        assert_eq!(m.get("zsh_version").unwrap(), "5.9");
        assert_eq!(m.get("tab_owner").unwrap(), "fzf-tab-complete");
        assert_eq!(m.len(), 2);
    }

    #[test]
    fn keys_rebound_after_the_shim_are_a_fighter() {
        // The real incident: 50-keybindings ran after 45-clicue and Down
        // went to history-substring-search — no way into the grid, while
        // doctor said "no fighters".
        let probe = probe_with(&[
            ("shim_loaded", "1"),
            ("tab_owner", "_clicue_w_accept"),
            ("up_owner", "history-substring-search-up"),
            ("down_owner", "history-substring-search-down"),
            ("right_owner", "_clicue_w_right"),
            ("enter_owner", "_clicue_w_enter"),
            ("ext_history", "on"),
            ("whatis", "1"),
            ("compinit", "1"),
        ]);
        let f = evaluate(&probe, &DaemonStatus::Answering, "current");
        let hit = f
            .iter()
            .find(|x| x.title.contains("rebound after clicue"))
            .expect("stolen keys must be a finding");
        assert!(matches!(hit.severity, Severity::Fighter));
        assert!(hit
            .detail
            .contains("Down (^[[B) → history-substring-search-down"));
        assert!(
            !hit.detail.contains("Enter (^M)"),
            "intact keys are not listed"
        );
    }

    #[test]
    fn theme_findings_name_the_fallback_and_the_broken_files() {
        // D5: the daemon's fallback message goes to stderr nobody reads;
        // this is where it becomes visible.
        let dir = std::env::temp_dir().join(format!("clicue-doctor-themes-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700));
        // Healthy: nothing on disk, the active theme resolves embedded.
        let f = theme_findings("aura", Some(&dir));
        assert_eq!(f.len(), 1);
        assert_eq!(f[0].severity, Severity::Info);
        assert!(f[0].detail.contains("loads cleanly"), "{}", f[0].detail);
        // Broken ACTIVE file: degraded, loader's message carried.
        std::fs::write(dir.join("aura.toml"), "[palette]\naccent = \"\"\n").unwrap();
        let f = theme_findings("aura", Some(&dir));
        assert_eq!(f[0].severity, Severity::Degradation);
        assert!(f[0].detail.contains("aura"), "{}", f[0].detail);
        // Stray broken files: info, all named, recovery gestures included.
        std::fs::write(dir.join("mystery.toml"), "not toml at all [").unwrap();
        let f = theme_findings("base", Some(&dir));
        let sweep = f
            .iter()
            .find(|x| x.title.contains("problems"))
            .expect("broken files must be listed");
        assert_eq!(sweep.severity, Severity::Info);
        assert!(
            sweep.detail.contains("aura") && sweep.detail.contains("mystery"),
            "{}",
            sweep.detail
        );
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn intact_shim_bindings_raise_no_rebind_finding() {
        let probe = probe_with(&[
            ("shim_loaded", "1"),
            ("tab_owner", "_clicue_w_accept"),
            ("up_owner", "_clicue_w_up"),
            ("down_owner", "_clicue_w_down"),
            ("ext_history", "on"),
            ("whatis", "1"),
            ("compinit", "1"),
        ]);
        let f = evaluate(&probe, &DaemonStatus::Answering, "current");
        assert!(!f.iter().any(|x| x.title.contains("rebound after clicue")));
    }

    #[test]
    fn prototype_in_shell_is_a_fighter_with_the_conf_d_hint() {
        let probe = probe_with(&[
            ("proto_theme_load", "1"),
            (
                "proto_src",
                "/home/x/.local/share/clicue/prototype/clicue.zsh",
            ),
            ("ext_history", "on"),
            ("whatis", "1"),
            ("compinit", "1"),
        ]);
        let f = evaluate(&probe, &DaemonStatus::Answering, "current");
        let fighter = f
            .iter()
            .find(|x| x.severity == Severity::Fighter)
            .expect("prototype must be a fighter");
        assert!(fighter.title.contains("PROTOTYPE"));
        assert!(fighter.detail.contains("45-clicue"));
    }

    #[test]
    fn silent_degradations_are_named_with_consequences() {
        let probe = probe_with(&[("ext_history", "off"), ("histsize", "500"), ("whatis", "0")]);
        let f = evaluate(&probe, &DaemonStatus::Unreachable("x".into()), "absent");
        let degr: Vec<_> = f
            .iter()
            .filter(|x| x.severity == Severity::Degradation)
            .collect();
        assert_eq!(degr.len(), 4, "{degr:#?}"); // ext_history, histsize, whatis, compinit
        assert!(degr.iter().any(|x| x.detail.contains("frequency")));
    }

    #[test]
    fn exit_code_1_only_on_fighters() {
        let clean = evaluate(
            &probe_with(&[("ext_history", "on"), ("whatis", "1"), ("compinit", "1")]),
            &DaemonStatus::Answering,
            "current",
        );
        let mut sink = Vec::new();
        assert_eq!(print_findings(&clean, &mut sink), 0);
        let fighters = evaluate(
            &probe_with(&[("autocomplete", "1"), ("compinit", "1")]),
            &DaemonStatus::Answering,
            "current",
        );
        let mut sink = Vec::new();
        assert_eq!(print_findings(&fighters, &mut sink), 1);
    }

    #[test]
    fn live_probe_runs_if_zsh_exists() {
        if Command::new("zsh").arg("--version").output().is_err() {
            return; // no zsh on this machine — skip
        }
        let m = run_probe().expect("probe should complete");
        assert!(m.contains_key("zsh_version"), "{m:?}");
        assert!(m.contains_key("tab_owner"));
    }
}
