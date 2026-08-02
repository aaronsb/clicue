//! Emission of the generated zsh shim (`clicue init zsh`).
//!
//! The shim is a template (`shim.zsh`) with the protocol version and socket
//! path baked in at emission time — emission runs inside the shell's own
//! environment during `.zshrc` eval, so the baked path agrees with what the
//! auto-spawned daemon will bind (daemon.rs::socket_path). Generated, not
//! copied: shim and daemon versions cannot drift (ADR-100).

const TEMPLATE: &str = include_str!("shim.zsh");

/// Quote for a zsh single-quoted string: `'` becomes `'\''`.
fn zsh_squote(s: &str) -> String {
    s.replace('\'', r"'\''")
}

pub fn emit_zsh() -> String {
    // On a path error the placeholder stays empty and the shim's own
    // fallback (same rules, in zsh) computes the path at source time.
    let sock = crate::daemon::socket_path()
        .map(|p| zsh_squote(&p.display().to_string()))
        .unwrap_or_default();
    TEMPLATE
        .replace("@CLICUE_VERSION@", &crate::protocol::VERSION.to_string())
        .replace("@CLICUE_SOCK@", &sock)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use std::path::PathBuf;
    use std::process::Command;

    /// The emitted shim, written ONCE — tests run in parallel, and each
    /// rewriting the same path let one test source another's half-written
    /// file.
    fn shim_file() -> PathBuf {
        static PATH: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();
        PATH.get_or_init(|| {
            let dir = std::env::temp_dir().join(format!("clicue-shim-test-{}", std::process::id()));
            let _ = std::fs::create_dir_all(&dir);
            let path = dir.join("shim.zsh");
            let mut f = std::fs::File::create(&path).unwrap();
            f.write_all(emit_zsh().as_bytes()).unwrap();
            path
        })
        .clone()
    }

    /// Run a zsh snippet with the shim sourced (non-interactive: functions
    /// defined, nothing installed). Args reach the snippet as $1, $2, …
    fn zsh(snippet: &str, args: &[&str]) -> std::process::Output {
        let shim = shim_file();
        let script = format!("source {} || exit 9\n{}", shim.display(), snippet);
        Command::new("zsh")
            .arg("-c")
            .arg(script)
            .arg("zsh")
            .args(args)
            .output()
            .expect("zsh must be installed to test the shim")
    }

    fn zsh_stdout(snippet: &str, args: &[&str]) -> Vec<u8> {
        let out = zsh(snippet, args);
        assert!(
            out.status.success(),
            "zsh failed: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        out.stdout
    }

    #[test]
    fn emitted_shim_parses_and_bakes_placeholders() {
        let shim = shim_file();
        let out = Command::new("zsh").arg("-n").arg(&shim).output().unwrap();
        assert!(
            out.status.success(),
            "zsh -n rejected the shim: {}",
            String::from_utf8_lossy(&out.stderr)
        );
        let text = emit_zsh();
        assert!(!text.contains("@CLICUE_VERSION@"));
        assert!(!text.contains("@CLICUE_SOCK@"));
        // The guards the spec demands are present in the emitted text.
        assert!(text.contains("refusing to bind"));
        assert!(text.contains("bare printable characters are typing"));
        assert!(text.contains("memo=clicue"));
        assert!(text.contains("clicue-off"));
    }

    #[test]
    fn json_escaper_round_trips_hostile_buffers() {
        let cases: Vec<String> = vec![
            "plain text".into(),
            r#"a"quote" and \backslash\"#.into(),
            "newline\nand\ttab".into(),
            "\u{1b}[31mansi\u{1b}[0m".into(),
            "│ ▸ ünïcode ─ glyphs".into(),
            r#"$(rm -rf /) `backticks` 'singles'"#.into(),
            r"trailing backslash \".into(),
            r"\\\\".into(),
            "\u{7}bell and \u{1}ctrl".into(),
        ];
        for input in cases {
            let out = zsh_stdout(r#"_clicue_json_esc "$1"; print -rn -- "$REPLY""#, &[&input]);
            let literal = format!("\"{}\"", String::from_utf8(out).unwrap());
            let decoded: String = serde_json::from_str(&literal)
                .unwrap_or_else(|e| panic!("escaper produced invalid JSON for {input:?}: {e}"));
            assert_eq!(decoded, input, "round trip failed for {input:?}");
        }
    }

    #[test]
    fn json_unescaper_decodes_serde_output() {
        let cases: Vec<String> = vec![
            "plain".into(),
            "line\nbreak\ttab\rcr".into(),
            r#"quote " backslash \ mixed \" tail"#.into(),
            "\u{1b}[7mescape\u{1b}[0m".into(),
            r"trailing \".into(),
            "│╰─ card ─╯".into(),
        ];
        for input in cases {
            let escaped = serde_json::to_string(&input).unwrap();
            let raw = &escaped[1..escaped.len() - 1]; // strip surrounding quotes
            let out = zsh_stdout(r#"_clicue_json_unesc "$1"; print -rn -- "$REPLY""#, &[raw]);
            assert_eq!(
                out,
                input.as_bytes(),
                "unescape failed for serde form {raw:?}"
            );
        }
    }

    #[test]
    fn reply_parsers_extract_a_real_daemon_frame() {
        use crate::protocol::{Action, Reply, Span};
        let reply = Reply {
            v: crate::protocol::VERSION,
            card: "\n╭─ 1/3 ─╮\n│ ▸ cargo │\n╰─────╯".into(),
            ghost: "go build".into(),
            spans: vec![
                Span {
                    start: 1,
                    end: 9,
                    style: "fg=#a277ff".into(),
                },
                Span {
                    start: 12,
                    end: 17,
                    style: "fg=#61ffca,bold".into(),
                },
            ],
            ack: 4207,
            ghost_style: "fg=#6d6a7f".into(),
            action: Action::Insert {
                strip: 0,
                text: "go build ".into(),
            },
        };
        let frame = serde_json::to_string(&reply).unwrap();
        let out = zsh_stdout(
            r#"
j=$1
_clicue_jget_str "$j" card && _clicue_json_unesc "$REPLY" && print -rn -- "$REPLY"
print -rn -- $'\x01'
_clicue_jget_str "$j" ghost && print -rn -- "$REPLY"
print -rn -- $'\x01'
_clicue_jget_num "$j" ack && print -rn -- "$REPLY"
print -rn -- $'\x01'
_clicue_spans "$j"; print -rn -- "${(j:|:)_clicue_rh}"
print -rn -- $'\x01'
if [[ $j == *'"action":"insert"'* ]]; then
  _clicue_jget_str "$j" text && _clicue_json_unesc "$REPLY" && print -rn -- "$REPLY"
fi
"#,
            &[&frame],
        );
        let parts: Vec<&[u8]> = out.split(|b| *b == 1).collect();
        assert_eq!(parts.len(), 5, "expected 5 fields");
        assert_eq!(parts[0], reply.card.as_bytes());
        assert_eq!(parts[1], b"go build");
        assert_eq!(parts[2], b"4207");
        assert_eq!(
            parts[3], b"1|9|fg=#a277ff|12|17|fg=#61ffca,bold" as &[u8],
            "span triplets"
        );
        assert_eq!(parts[4], b"go build ");
    }

    #[test]
    fn error_frame_detection_and_version_bake() {
        let err = serde_json::to_string(&crate::protocol::ErrorFrame {
            v: crate::protocol::VERSION,
            error: "protocol version mismatch: shim speaks v1, daemon speaks v2".into(),
        })
        .unwrap();
        let out = zsh_stdout(
            r#"
_clicue_apply "$1"
print -rn -- "dead=$_clicue_dead action=$_clicue_action err=$_clicue_err""#,
            &[&err],
        );
        let s = String::from_utf8(out).unwrap();
        assert!(
            s.starts_with("dead=1 action=delegate err=protocol version mismatch"),
            "got: {s}"
        );
        // The baked version matches the crate's protocol version.
        let v = zsh_stdout(r#"print -rn -- $_clicue_v"#, &[]);
        assert_eq!(v, crate::protocol::VERSION.to_string().as_bytes());
    }
}
