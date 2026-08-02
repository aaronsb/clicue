//! The daemon: socket lifecycle and the per-connection serve loop.
//!
//! Contract: spec/protocol.md §§1–3 (transport), §8–10 (failure,
//! versioning). The render path is a stub until the layout and source
//! modules land; the transport and framing here are final.

use std::fs;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};

use anyhow::{bail, Context, Result};

use crate::protocol::{self, ErrorFrame, Reply, Request};

/// Socket path per spec §1: `$XDG_RUNTIME_DIR/clicue.sock`, else
/// `$XDG_CACHE_HOME/clicue/clicue.sock`, else `~/.cache/clicue/clicue.sock`.
pub fn socket_path() -> Result<PathBuf> {
    if let Some(dir) = std::env::var_os("XDG_RUNTIME_DIR").filter(|d| !d.is_empty()) {
        return Ok(PathBuf::from(dir).join("clicue.sock"));
    }
    let cache = std::env::var_os("XDG_CACHE_HOME")
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|h| PathBuf::from(h).join(".cache")))
        .context("neither XDG_RUNTIME_DIR, XDG_CACHE_HOME nor HOME is set")?;
    Ok(cache.join("clicue").join("clicue.sock"))
}

/// Spec §1: refuse to serve from a directory another user could rename a
/// socket into. Owner must be us and group/other write bits clear.
fn check_parent(dir: &Path) -> Result<()> {
    let meta = fs::metadata(dir)
        .with_context(|| format!("socket directory {} does not exist", dir.display()))?;
    // SAFETY-free libc call equivalents: MetadataExt gives uid/mode directly.
    let uid = unsafe { libc_geteuid() };
    if meta.uid() != uid {
        bail!(
            "socket directory {} is owned by uid {}, not us ({uid})",
            dir.display(),
            meta.uid()
        );
    }
    if meta.mode() & 0o022 != 0 {
        bail!(
            "socket directory {} is writable by group or other (mode {:o})",
            dir.display(),
            meta.mode() & 0o777
        );
    }
    Ok(())
}

// std has no geteuid; avoid a libc dependency for one call.
unsafe fn libc_geteuid() -> u32 {
    extern "C" {
        fn geteuid() -> u32;
    }
    geteuid()
}

/// Bind, replacing a STALE socket (bind fails AddrInUse but nothing
/// answers a connect) and refusing to displace a LIVE daemon.
fn bind(path: &Path) -> Result<UnixListener> {
    if let Some(parent) = path.parent() {
        if !parent.exists() {
            fs::DirBuilder::new()
                .recursive(true)
                .mode(0o700)
                .create(parent)
                .with_context(|| format!("creating {}", parent.display()))?;
        }
        check_parent(parent)?;
    }
    match UnixListener::bind(path) {
        Ok(l) => {
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            Ok(l)
        }
        Err(e) if e.kind() == ErrorKind::AddrInUse => {
            if UnixStream::connect(path).is_ok() {
                bail!("a daemon is already serving {}", path.display());
            }
            fs::remove_file(path)
                .with_context(|| format!("removing stale socket {}", path.display()))?;
            let l = UnixListener::bind(path)?;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
            Ok(l)
        }
        Err(e) => Err(e).with_context(|| format!("binding {}", path.display())),
    }
}

/// `clicue daemon` entry point.
pub fn run() -> Result<()> {
    let path = socket_path()?;
    let listener = bind(&path)?;
    serve(listener)
}

/// Accept loop, one thread per connection. A shell holds one persistent
/// connection (spec §3), so the thread count tracks live shells.
pub fn serve(listener: UnixListener) -> Result<()> {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                std::thread::spawn(move || {
                    // A dropped connection is a shell exiting: not an error.
                    let _ = serve_connection(stream);
                });
            }
            Err(e) => {
                // Accept errors are transient (EMFILE, EINTR); keep serving.
                eprintln!("clicue daemon: accept: {e}");
            }
        }
    }
    Ok(())
}

fn serve_connection(stream: UnixStream) -> Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut stream = stream;
    let mut line = String::new();
    loop {
        line.clear();
        if reader.read_line(&mut line)? == 0 {
            return Ok(()); // shell closed the connection
        }
        let frame = match serde_json::from_str::<Request>(&line) {
            Ok(req) if req.v == protocol::VERSION => serde_json::to_string(&handle(req))?,
            Ok(req) => serde_json::to_string(&ErrorFrame {
                v: protocol::VERSION,
                error: format!(
                    "protocol version mismatch: shim speaks v{}, daemon speaks v{}",
                    req.v,
                    protocol::VERSION
                ),
            })?,
            Err(e) => serde_json::to_string(&ErrorFrame {
                v: protocol::VERSION,
                error: format!("unparseable request: {e}"),
            })?,
        };
        stream.write_all(frame.as_bytes())?;
        stream.write_all(b"\n")?;
    }
}

/// Render stub: stands down on everything. Replaced module by module as
/// layout and sources land against their spec sections; the transport
/// around it does not change.
fn handle(_req: Request) -> Reply {
    Reply::stand_down()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Action, Event, Session, VERSION};

    // A private 0700 directory: check_parent rightly refuses /tmp itself
    // (root-owned, world-writable), which is exactly the property under test.
    fn temp_socket(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("clicue-test-{}", std::process::id()));
        let _ = fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir);
        dir.join(format!("{tag}.sock"))
    }

    fn request_line(v: u32) -> String {
        let req = Request {
            v,
            session: Session {
                pid: std::process::id(),
                start: 0,
            },
            event: Event::Redraw,
            buffer: "car".into(),
            cursor: 3,
            cols: 120,
            lines: 40,
            keymap: "main".into(),
            pending: None,
            hist: vec![],
        };
        serde_json::to_string(&req).unwrap()
    }

    fn round_trip(path: &Path, line: &str) -> String {
        let mut conn = UnixStream::connect(path).unwrap();
        conn.write_all(line.as_bytes()).unwrap();
        conn.write_all(b"\n").unwrap();
        let mut reply = String::new();
        BufReader::new(conn).read_line(&mut reply).unwrap();
        reply
    }

    #[test]
    fn serves_stand_down_and_error_frames() {
        let path = temp_socket("serve");
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || serve(listener));

        let reply: Reply =
            serde_json::from_str(&round_trip(&path, &request_line(VERSION))).unwrap();
        assert_eq!(reply.card, "");
        assert_eq!(reply.action, Action::Delegate);

        let err: ErrorFrame =
            serde_json::from_str(&round_trip(&path, &request_line(VERSION + 1))).unwrap();
        assert!(err.error.contains("version mismatch"));

        let err: ErrorFrame = serde_json::from_str(&round_trip(&path, "not json")).unwrap();
        assert!(err.error.contains("unparseable"));

        let _ = fs::remove_file(&path);
    }

    #[test]
    fn bind_replaces_stale_socket_and_refuses_live_one() {
        let path = temp_socket("bind");
        let _ = fs::remove_file(&path);
        // Stale: a socket file with no listener behind it.
        drop(UnixListener::bind(&path).unwrap());
        let listener = bind(&path).expect("stale socket should be replaced");
        // Live: a second bind while the first listener still answers.
        let err = bind(&path).expect_err("live daemon must not be displaced");
        assert!(err.to_string().contains("already serving"));
        drop(listener);
        let _ = fs::remove_file(&path);
    }

    #[test]
    fn socket_file_mode_is_0600() {
        let path = temp_socket("mode");
        let _ = fs::remove_file(&path);
        let _l = bind(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let _ = fs::remove_file(&path);
    }
}
