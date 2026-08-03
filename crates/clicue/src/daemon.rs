//! The daemon: socket lifecycle and the per-connection serve loop.
//!
//! Contract: spec/protocol.md §§1–3 (transport), §8–10 (failure,
//! versioning). The render path is a stub until the layout and source
//! modules land; the transport and framing here are final.

use std::fs::{self, File};
use std::io::{BufRead, BufReader, ErrorKind, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, FileTypeExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime};

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
fn acquire_lock(sock: &Path) -> Result<File> {
    let lock_path = sock.with_extension("lock");
    let lock = File::options()
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
    Ok(lock)
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
    let render = reloading_render(WatchSet::daemon_inputs(), Duration::from_secs(1))?;
    serve_with(listener, render)
}

/// Everything the daemon derives itself from, watched by ONE reloader so
/// every verb that rewrites an input applies live the same way: the
/// config file (`config set`, `theme set`), the corpus cache (`data
/// rebuild`, `data forget`), and the operator theme files. What is NOT
/// here is deliberate: the flag store is written by the daemon's own
/// harvest ingests, and watching it would make the daemon reload itself
/// on every first-Tab.
#[derive(Default, Clone)]
pub struct WatchSet {
    pub files: Vec<PathBuf>,
    /// Watched by entry list + per-entry mtime, so create, edit, and
    /// delete all register (a directory's own mtime misses in-place edits).
    pub dirs: Vec<PathBuf>,
}

impl WatchSet {
    pub fn daemon_inputs() -> WatchSet {
        let mut w = WatchSet::default();
        if let Ok(p) = crate::config::config_path() {
            if let Some(parent) = p.parent() {
                w.dirs.push(parent.join("themes"));
            }
            w.files.push(p);
        }
        if let Ok(p) = crate::corpus::cache_path() {
            w.files.push(p);
        }
        w
    }

    fn is_empty(&self) -> bool {
        self.files.is_empty() && self.dirs.is_empty()
    }
}

/// mtime + length: mtime granularity can be coarse, and a same-second
/// rewrite usually changes length; both together is the cheap stat that
/// registers every real edit.
type FileStamp = Option<(SystemTime, u64)>;

/// One comparable snapshot of every watched input.
type InputsStamp = (Vec<FileStamp>, Vec<Vec<(std::ffi::OsString, FileStamp)>>);

fn file_stat(m: std::io::Result<fs::Metadata>) -> FileStamp {
    let m = m.ok()?;
    Some((m.modified().ok()?, m.len()))
}

fn inputs_stat(watch: &WatchSet) -> InputsStamp {
    let files = watch
        .files
        .iter()
        .map(|p| file_stat(fs::metadata(p)))
        .collect();
    let dirs = watch
        .dirs
        .iter()
        .map(|d| {
            let mut entries: Vec<_> = fs::read_dir(d)
                .into_iter()
                .flatten()
                .flatten()
                .map(|e| (e.file_name(), file_stat(e.metadata())))
                .collect();
            entries.sort();
            entries
        })
        .collect();
    (files, dirs)
}

/// Engine that follows its inputs: when any watched file or directory
/// changes, the next request (rate-limited to one stat pass per
/// `min_interval`) swaps in a freshly built engine. Sessions are shared
/// across swaps, so open shells keep their hello universes, dismissals
/// and live harvests; a swap that fails keeps the current engine. This is
/// why `theme set`, `config set`, `data rebuild` and `data forget` never
/// ask for a daemon restart — and why an invalid edit behaves exactly
/// like a daemon restart would (per-key fallback with warnings), never
/// worse. Swaps LOAD the corpus as-is (S7): only the daemon's first
/// engine rebuilds a stale corpus, so a swap can never enter a rebuild
/// loop against a histfile that moves with every command.
pub fn reloading_render(watch: WatchSet, min_interval: Duration) -> Result<Render> {
    use crate::engine::CorpusPolicy;
    use std::sync::atomic::{AtomicBool, Ordering};
    let sessions = crate::engine::SharedSessions::default();
    let started = std::sync::Arc::new(AtomicBool::new(false));
    let mk = move || -> Result<Render> {
        let policy = if started.swap(true, Ordering::SeqCst) {
            CorpusPolicy::LoadOnly
        } else {
            CorpusPolicy::RebuildIfStale
        };
        let engine =
            std::sync::Arc::new(crate::engine::Engine::new_shared(sessions.clone(), policy)?);
        Ok(std::sync::Arc::new(move |req| engine.handle(req)) as Render)
    };
    reloading_with(watch, min_interval, mk)
}

/// The swap mechanism, factory-injected so tests need no real engine.
fn reloading_with(
    watch: WatchSet,
    min_interval: Duration,
    factory: impl Fn() -> Result<Render> + Send + Sync + 'static,
) -> Result<Render> {
    use std::sync::atomic::{AtomicBool, Ordering};
    let current = std::sync::Arc::new(RwLock::new(factory()?));
    let factory = std::sync::Arc::new(factory);
    let building = std::sync::Arc::new(AtomicBool::new(false));
    // Stat AFTER the first build: a write landing during it must trigger
    // a reload, not be mistaken for the state already built. (The first
    // engine may itself write the corpus cache — a stamp taken before it
    // would see that write as an operator action and swap for nothing.)
    let state = std::sync::Arc::new(Mutex::new((Instant::now(), Some(inputs_stat(&watch)))));
    Ok(std::sync::Arc::new(move |req| {
        if !watch.is_empty() {
            let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
            if st.0.elapsed() >= min_interval {
                st.0 = Instant::now();
                let now = Some(inputs_stat(&watch));
                if now != st.1 && !building.swap(true, Ordering::SeqCst) {
                    st.1 = now;
                    // Build OFF the request path: an engine build takes far
                    // longer than the shim's 5ms deadline, and a blocked
                    // request reads as a wedged daemon. Requests keep
                    // flowing on the current engine until the swap. A
                    // failed build clears the stamp so the next interval
                    // retries (bounded: one build per interval) instead of
                    // freezing on the old engine until another edit.
                    let current = current.clone();
                    let factory = factory.clone();
                    let building = building.clone();
                    let state = state.clone();
                    std::thread::spawn(move || {
                        match factory() {
                            Ok(r) => {
                                *current.write().unwrap_or_else(|e| e.into_inner()) = r;
                            }
                            Err(e) => {
                                eprintln!(
                                    "clicue daemon: config reload failed, keeping current: {e:#}"
                                );
                                state.lock().unwrap_or_else(|e| e.into_inner()).1 = None;
                            }
                        }
                        building.store(false, Ordering::SeqCst);
                    });
                }
            }
        }
        let r = current.read().unwrap_or_else(|e| e.into_inner()).clone();
        r(req)
    }))
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
    fn reload_swaps_on_config_change_and_keeps_current_on_failure() {
        use std::sync::atomic::{AtomicUsize, Ordering};
        let dir = temp_dir("reload");
        let cfg = dir.join("config.toml");
        fs::write(&cfg, "theme = \"aura\"\n").unwrap();
        let gen = std::sync::Arc::new(AtomicUsize::new(0));
        let g = gen.clone();
        let render = reloading_with(
            WatchSet {
                files: vec![cfg.clone()],
                dirs: vec![],
            },
            Duration::ZERO,
            move || {
                let n = g.fetch_add(1, Ordering::SeqCst) + 1;
                if n == 3 {
                    anyhow::bail!("boom"); // third build fails: engine must survive
                }
                Ok(std::sync::Arc::new(move |_req| Reply {
                    card: format!("gen{n}"),
                    ..Reply::stand_down()
                }) as Render)
            },
        )
        .unwrap();
        let req = || serde_json::from_str::<Request>(&request_line(VERSION)).unwrap();
        // Swaps land asynchronously (built off the request path): poll.
        let until = |want: &str| {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got = render(req()).card;
                if got == want {
                    return;
                }
                assert!(Instant::now() < deadline, "expected {want}, stuck at {got}");
                std::thread::sleep(Duration::from_millis(5));
            }
        };
        assert_eq!(render(req()).card, "gen1");
        assert_eq!(render(req()).card, "gen1", "unchanged file, no swap");
        // mtime granularity can be coarse; changing LENGTH always registers
        fs::write(&cfg, "theme = \"mono\"  \n").unwrap();
        until("gen2");
        // build 3 fails (async): the current engine survives, and the
        // cleared stamp retries on a later interval WITHOUT another edit
        fs::write(&cfg, "theme = \"plain\"\n").unwrap();
        until("gen4");
    }

    #[test]
    fn reload_watches_every_input_kind() {
        // One reloader for every input (S7): the corpus cache (`data
        // rebuild` / `data forget` rewrite it) and the theme files apply
        // live through the same swap as the config file.
        use std::sync::atomic::{AtomicUsize, Ordering};
        let dir = temp_dir("reload-inputs");
        let corpus = dir.join("corpus.json");
        let themes = dir.join("themes");
        fs::create_dir_all(&themes).unwrap();
        fs::write(&corpus, "{}").unwrap();
        let gen = std::sync::Arc::new(AtomicUsize::new(0));
        let g = gen.clone();
        let render = reloading_with(
            WatchSet {
                files: vec![corpus.clone()],
                dirs: vec![themes.clone()],
            },
            Duration::ZERO,
            move || {
                let n = g.fetch_add(1, Ordering::SeqCst) + 1;
                Ok(std::sync::Arc::new(move |_req| Reply {
                    card: format!("gen{n}"),
                    ..Reply::stand_down()
                }) as Render)
            },
        )
        .unwrap();
        let req = || serde_json::from_str::<Request>(&request_line(VERSION)).unwrap();
        let until = |want: &str| {
            let deadline = Instant::now() + Duration::from_secs(5);
            loop {
                let got = render(req()).card;
                if got == want {
                    return;
                }
                assert!(Instant::now() < deadline, "expected {want}, stuck at {got}");
                std::thread::sleep(Duration::from_millis(5));
            }
        };
        assert_eq!(render(req()).card, "gen1");
        // A corpus rewrite (what `data rebuild` does) swaps.
        fs::write(&corpus, "{\"stamp\":\"rebuilt\"}").unwrap();
        until("gen2");
        // A theme file APPEARING swaps…
        fs::write(themes.join("mine.toml"), "accent = \"#ff0000\"\n").unwrap();
        until("gen3");
        // …and an in-place EDIT swaps too (dir mtime alone would miss it;
        // the length differs so coarse mtime granularity cannot hide it).
        fs::write(themes.join("mine.toml"), "accent = \"#00ff00\"  \n").unwrap();
        until("gen4");
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
}
