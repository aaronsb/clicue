//! The daemon: socket lifecycle and the per-connection serve loop.
//!
//! Contract: spec/protocol.md §§1–3 (transport), §8–10 (failure,
//! versioning). The engine behind the socket lives in engine.rs; the
//! input-watching swap machinery that keeps it current lives in
//! reload.rs (spec corpus.md S7).

use std::fs::{self, File};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::Duration;

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
    let uid = unsafe { libc::geteuid() };
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

/// The daemon singleton lock. Held (flocked) for the daemon's lifetime;
/// the connect-probe alone loses a start race (measured on review of
/// PR #5: 6 concurrent starts against a stale socket produced two live
/// daemons), and §9's auto-spawn fires N times at once when a terminal
/// multiplexer restores a session.
fn lock_path(sock: &Path) -> PathBuf {
    sock.with_extension("lock")
}

fn acquire_lock(sock: &Path) -> Result<File> {
    let lock_path = lock_path(sock);
    let mut lock = File::options()
        .create(true)
        .truncate(false)
        .write(true)
        .open(&lock_path)
        .with_context(|| format!("opening {}", lock_path.display()))?;
    let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc != 0 {
        bail!(
            "another daemon holds {} — refusing to start twice",
            lock_path.display()
        );
    }
    // The held lock's content is the holder's pid (spec §9b): `daemon
    // status/stop` read it, so it must be written under the lock, never
    // by an observer.
    lock.set_len(0)?;
    lock.write_all(format!("{}\n", std::process::id()).as_bytes())?;
    lock.sync_all().ok();
    Ok(lock)
}

// ── lifecycle controls (spec §9b, ADR-300) ──────────────────────────────

/// What `daemon status/stop/restart` observe. The lock is the truth:
/// acquirable means no daemon; held means the pid recorded in it lives.
#[derive(Debug, PartialEq, Eq)]
pub enum DaemonState {
    NotRunning,
    Running {
        pid: i32,
        /// False when /proc/pid/exe is deleted or points elsewhere than
        /// an existing file — the stale-binary signal (ADR-300).
        exe_current: bool,
    },
}

fn probe_state(sock: &Path) -> Result<DaemonState> {
    let lock_path = lock_path(sock);
    let lock = match File::options().read(true).write(true).open(&lock_path) {
        Ok(f) => f,
        Err(e) if e.kind() == ErrorKind::NotFound => return Ok(DaemonState::NotRunning),
        Err(e) => return Err(e).with_context(|| format!("opening {}", lock_path.display())),
    };
    let rc = unsafe { libc::flock(lock.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
    if rc == 0 {
        // We hold it — nobody else did. Dropping the File releases it.
        return Ok(DaemonState::NotRunning);
    }
    let mut text = String::new();
    BufReader::new(&lock).read_to_string(&mut text).ok();
    let pid: i32 = text
        .trim()
        .parse()
        .with_context(|| format!("{} is held but carries no pid", lock_path.display()))?;
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok();
    let exe_current = exe
        .as_deref()
        .map(|p| p.exists() && !p.to_string_lossy().ends_with(" (deleted)"))
        .unwrap_or(false);
    Ok(DaemonState::Running { pid, exe_current })
}

/// Public probe against the configured socket.
pub fn state() -> Result<(DaemonState, PathBuf)> {
    let sock = socket_path()?;
    Ok((probe_state(&sock)?, sock))
}

fn comm_is_clicue(pid: i32) -> bool {
    fs::read_to_string(format!("/proc/{pid}/comm"))
        .map(|c| c.trim() == "clicue")
        .unwrap_or(false)
}

fn wait_lock_free(sock: &Path, budget: Duration) -> bool {
    let deadline = std::time::Instant::now() + budget;
    while std::time::Instant::now() < deadline {
        match probe_state(sock) {
            Ok(DaemonState::NotRunning) => return true,
            _ => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    false
}

/// SIGTERM the lock-holding daemon and wait for the lock to free. No
/// SIGKILL escalation: a daemon surviving SIGTERM is an incident to
/// name, not to mask (spec §9b). Idempotent: Ok(None) when nothing runs.
pub fn stop(sock: &Path) -> Result<Option<i32>> {
    let pid = match probe_state(sock)? {
        DaemonState::NotRunning => return Ok(None),
        DaemonState::Running { pid, .. } => pid,
    };
    if !comm_is_clicue(pid) {
        bail!("lock names pid {pid}, but that process is not clicue — not signalling it");
    }
    if unsafe { libc::kill(pid, libc::SIGTERM) } != 0 {
        bail!(
            "SIGTERM to pid {pid} failed: {}",
            std::io::Error::last_os_error()
        );
    }
    if !wait_lock_free(sock, Duration::from_secs(5)) {
        bail!("pid {pid} still holds the lock 5s after SIGTERM — investigate before retrying");
    }
    Ok(Some(pid))
}

/// Spawn a detached daemon (the shim's own gesture, from the CLI) and
/// wait for it to hold the lock.
pub fn start_detached(sock: &Path) -> Result<i32> {
    let exe = std::env::current_exe().context("resolving our own binary")?;
    let mut cmd = std::process::Command::new(exe);
    cmd.arg("daemon")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());
    // Safety: setsid is async-signal-safe; nothing else runs pre-exec.
    unsafe {
        use std::os::unix::process::CommandExt;
        cmd.pre_exec(|| {
            libc::setsid();
            Ok(())
        });
    }
    cmd.spawn().context("spawning clicue daemon")?;
    let deadline = std::time::Instant::now() + Duration::from_secs(15);
    while std::time::Instant::now() < deadline {
        if let DaemonState::Running { pid, .. } = probe_state(sock)? {
            return Ok(pid);
        }
        std::thread::sleep(Duration::from_millis(50));
    }
    bail!("spawned a daemon but it never took the lock — see clicue doctor");
}

/// Bind under the lock. A pre-existing socket is stale by definition once
/// we hold the lock, but only a SOCKET may be removed — an auto-spawned
/// process deleting an arbitrary file at a configurable path is the wrong
/// default even same-uid. The socket is born 0600 via umask, not chmod'd
/// into it after a world-readable window.
fn bind(path: &Path) -> Result<(UnixListener, File)> {
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
    let lock = acquire_lock(path)?;
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_socket() => {
            // Held lock means no live daemon; the probe is diagnosis only.
            if UnixStream::connect(path).is_ok() {
                bail!(
                    "{} answers but its lock was free — refusing to displace it",
                    path.display()
                );
            }
            fs::remove_file(path)
                .with_context(|| format!("removing stale socket {}", path.display()))?;
        }
        Ok(_) => bail!(
            "{} exists and is not a socket — refusing to remove it",
            path.display()
        ),
        Err(e) if e.kind() == ErrorKind::NotFound => {}
        Err(e) => return Err(e).with_context(|| format!("inspecting {}", path.display())),
    }
    // Atomic 0600 at creation: umask, bind, restore. Process-global, but
    // nothing else in this process creates files concurrently at startup.
    let old = unsafe { libc::umask(0o177) };
    let bound = UnixListener::bind(path);
    unsafe { libc::umask(old) };
    let listener = bound.with_context(|| format!("binding {}", path.display()))?;
    fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    Ok((listener, lock))
}

/// `clicue daemon` entry point.
pub fn run() -> Result<()> {
    let path = socket_path()?;
    let (listener, _lock) = bind(&path)?; // lock lives as long as serve()
    let render = crate::reload::reloading_render(
        crate::reload::WatchSet::daemon_inputs(),
        Duration::from_secs(1),
    )?;
    serve_with(listener, render)
}

pub fn serve(listener: UnixListener) -> Result<()> {
    serve_with(listener, std::sync::Arc::new(handle))
}

/// Shared render function — the engine behind every connection.
pub type Render = std::sync::Arc<dyn Fn(Request) -> Reply + Send + Sync>;

/// Accept loop, one thread per connection — a shell holds one persistent
/// connection (spec §3), so the thread count tracks live shells. The
/// render function is injected so the loop is testable against more than
/// the stand-down stub, and it is where per-session state will thread in.
pub fn serve_with(listener: UnixListener, render: Render) -> Result<()> {
    for stream in listener.incoming() {
        match stream {
            Ok(stream) => {
                let render = render.clone();
                std::thread::spawn(move || {
                    // A dropped connection is a shell exiting: not an error.
                    let _ = serve_connection(stream, render);
                });
            }
            Err(e) => {
                // EMFILE and friends persist; retrying hot burned a full
                // core (measured on review of PR #5). Back off.
                eprintln!("clicue daemon: accept: {e}");
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }
    Ok(())
}

fn serve_connection(stream: UnixStream, render: Render) -> Result<()> {
    let mut reader = BufReader::new(stream.try_clone()?);
    let mut stream = stream;
    let mut raw: Vec<u8> = Vec::new();
    loop {
        raw.clear();
        // Bytes, not read_line: a frame is not required to be UTF-8 to be
        // answerable (spec §8 — a recoverable frame must never look like a
        // crashed daemon), and take() caps memory at MAX_FRAME.
        let n = (&mut reader)
            .take(protocol::MAX_FRAME as u64 + 1)
            .read_until(b'\n', &mut raw)?;
        if n == 0 {
            return Ok(()); // shell closed the connection
        }
        if raw.len() > protocol::MAX_FRAME {
            // Resync inside an oversized stream is impossible; name the
            // limit, close, and let the shim's 49µs reconnect handle it.
            let frame = serde_json::to_string(&ErrorFrame {
                v: protocol::VERSION,
                error: format!(
                    "frame exceeds MAX_FRAME ({} bytes); closing connection",
                    protocol::MAX_FRAME
                ),
            })?;
            stream.write_all(frame.as_bytes())?;
            stream.write_all(b"\n")?;
            return Ok(());
        }
        let frame = respond(&raw, &render);
        stream.write_all(frame.as_bytes())?;
        stream.write_all(b"\n")?;
    }
}

/// One frame in, one frame out. Version is probed BEFORE the full parse:
/// a shim that bumped `v` bumped it because the shape changed, so parsing
/// the shape first would report gibberish instead of the mismatch
/// (spec §10). Error text carries positions only, never request content —
/// the request may be the operator's command line, and §10 stashes these
/// frames for `clicue doctor`.
fn respond(raw: &[u8], render: &Render) -> String {
    #[derive(serde::Deserialize)]
    struct Probe {
        v: u32,
    }
    let frame = match serde_json::from_slice::<Probe>(raw) {
        Ok(p) if p.v != protocol::VERSION => serde_json::to_string(&ErrorFrame {
            v: protocol::VERSION,
            error: format!(
                "protocol version mismatch: shim speaks v{}, daemon speaks v{}",
                p.v,
                protocol::VERSION
            ),
        }),
        _ => match serde_json::from_slice::<Request>(raw) {
            Ok(req) => serde_json::to_string(&render(req)),
            Err(e) => serde_json::to_string(&ErrorFrame {
                v: protocol::VERSION,
                error: format!(
                    "unparseable request (line {}, column {})",
                    e.line(),
                    e.column()
                ),
            }),
        },
    };
    // Serializing our own types cannot fail; if it somehow does, the shim's
    // read deadline turns silence into stand-down (spec §8).
    frame.unwrap_or_default()
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
    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("clicue-test-{}-{tag}", std::process::id()));
        let _ = fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir);
        // Parallel tests race bind()'s process-global umask window, which
        // can strip the search bit from a dir created inside it. Assert
        // the mode explicitly rather than trusting creation-time.
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        dir
    }

    fn temp_socket(tag: &str) -> PathBuf {
        temp_dir(tag).join("test.sock")
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
            env: None,
            hist: vec![],
            nav: None,
        };
        serde_json::to_string(&req).unwrap()
    }

    fn send(conn: &mut UnixStream, line: &[u8]) -> String {
        conn.write_all(line).unwrap();
        conn.write_all(b"\n").unwrap();
        let mut reply = String::new();
        let mut r = BufReader::new(conn.try_clone().unwrap());
        r.read_line(&mut reply).unwrap();
        reply
    }

    #[test]
    fn one_connection_serves_many_frames_and_recovers_from_bad_input() {
        let path = temp_socket("serve");
        let listener = UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || serve(listener));
        let mut conn = UnixStream::connect(&path).unwrap();

        // Persistent connection: several frames on ONE stream (spec §3).
        let reply: Reply =
            serde_json::from_str(&send(&mut conn, request_line(VERSION).as_bytes())).unwrap();
        assert_eq!(reply.card, "");
        assert_eq!(reply.action, Action::Delegate);

        // Version mismatch with a SHAPE the daemon has never seen — the
        // probe must answer before the full parse gets a say (spec §10).
        let v2 = format!(r#"{{"v":{},"shape":"unrecognisable"}}"#, VERSION + 1);
        let err: ErrorFrame = serde_json::from_str(&send(&mut conn, v2.as_bytes())).unwrap();
        assert!(err.error.contains("version mismatch"), "{}", err.error);

        // Non-UTF-8 gets an error frame, not a dead socket (spec §8) —
        // and the error must not echo the request bytes.
        let err: ErrorFrame =
            serde_json::from_str(&send(&mut conn, b"{\"v\":1,\"buffer\":\"\xff\xfe\"}")).unwrap();
        assert!(err.error.contains("unparseable"));
        assert!(!err.error.contains('\u{fffd}'));

        // Still alive after both failures.
        let reply: Reply =
            serde_json::from_str(&send(&mut conn, request_line(VERSION).as_bytes())).unwrap();
        assert_eq!(reply.action, Action::Delegate);
    }

    #[test]
    fn oversized_frame_gets_error_frame_then_close() {
        let path = temp_socket("oversize");
        let listener = UnixListener::bind(&path).unwrap();
        std::thread::spawn(move || serve(listener));
        let mut conn = UnixStream::connect(&path).unwrap();
        let big = vec![b'x'; protocol::MAX_FRAME + 2];
        conn.write_all(&big).unwrap();
        conn.write_all(b"\n").unwrap();
        let mut reply = String::new();
        BufReader::new(conn.try_clone().unwrap())
            .read_line(&mut reply)
            .unwrap();
        let err: ErrorFrame = serde_json::from_str(&reply).unwrap();
        assert!(err.error.contains("MAX_FRAME"));
        // Connection is closed afterwards: next read sees EOF.
        let mut rest = String::new();
        let n = BufReader::new(conn).read_line(&mut rest).unwrap();
        assert_eq!(n, 0);
    }

    #[test]
    fn bind_replaces_stale_socket_and_lock_refuses_second_daemon() {
        let path = temp_socket("bind");
        // Stale: a socket file with no listener behind it.
        drop(UnixListener::bind(&path).unwrap());
        let (_listener, _lock) = bind(&path).expect("stale socket should be replaced");
        // Second daemon: refused by the flock, not by the connect probe.
        let err = bind(&path).expect_err("second daemon must be refused");
        assert!(err.to_string().contains("another daemon holds"), "{err}");
    }

    #[test]
    fn bind_refuses_to_remove_a_non_socket() {
        let path = temp_socket("nonsock");
        fs::write(&path, b"precious").unwrap();
        let err = bind(&path).expect_err("a regular file must survive");
        assert!(err.to_string().contains("not a socket"), "{err}");
        assert_eq!(fs::read(&path).unwrap(), b"precious");
    }

    #[test]
    fn socket_file_mode_is_0600() {
        let path = temp_socket("mode");
        let (_l, _lock) = bind(&path).unwrap();
        let mode = fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn check_parent_rejects_group_writable_dir() {
        let dir = temp_dir("groupw");
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o770)).unwrap();
        let err = check_parent(&dir).expect_err("group-writable must be rejected");
        assert!(
            err.to_string().contains("writable by group or other"),
            "{err}"
        );
        // 0755 is acceptable per spec §1: only WRITE bits matter.
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        check_parent(&dir).expect("0755 parent is fine");
    }

    #[test]
    fn probe_reads_the_lock_truth() {
        // §9b: acquirable = not running; held = the recorded pid, whose
        // exe (ours: the live test binary) is current. flock conflicts
        // across separate opens even within one process, which is what
        // lets one process both hold and probe.
        let sock = temp_socket("probe");
        assert_eq!(
            probe_state(&sock).unwrap(),
            DaemonState::NotRunning,
            "no lock file yet"
        );
        let lock = acquire_lock(&sock).unwrap();
        match probe_state(&sock).unwrap() {
            DaemonState::Running { pid, exe_current } => {
                assert_eq!(pid, std::process::id() as i32, "lock must carry OUR pid");
                assert!(exe_current, "the test binary exists and is current");
            }
            other => panic!("held lock read as {other:?}"),
        }
        drop(lock);
        assert_eq!(
            probe_state(&sock).unwrap(),
            DaemonState::NotRunning,
            "released lock must read as not running"
        );
    }

    #[test]
    fn stop_refuses_a_pid_that_is_not_clicue() {
        // The lock names OUR test process, whose comm is the test
        // binary's, not "clicue" — stop must refuse to signal it.
        let sock = temp_socket("stopsafe");
        let _lock = acquire_lock(&sock).unwrap();
        let err = stop(&sock).expect_err("must refuse to signal a non-clicue pid");
        assert!(err.to_string().contains("not clicue"), "{err}");
    }

    #[test]
    fn stop_is_idempotent_when_nothing_runs() {
        let sock = temp_socket("stopnone");
        assert_eq!(stop(&sock).unwrap(), None);
    }
}
