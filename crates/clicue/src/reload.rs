//! Hot reload: one watcher over every input the daemon derives from.
//!
//! Contract: spec/corpus.md S7. The daemon's engine is derived data —
//! config, corpus cache, operator theme files in, behaviour out — so
//! every CLI verb that rewrites an input (`config set`, `theme set`,
//! `data rebuild`, `data forget`) applies live through the same engine
//! swap, and none of them may tell the operator to restart.

use std::fs;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime};

use anyhow::Result;

use crate::daemon::Render;
use crate::engine::CorpusPolicy;

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
    /// Watched by entry list + per-entry stat, so create, edit, and
    /// delete all register (a directory's own mtime misses in-place edits).
    pub dirs: Vec<PathBuf>,
}

impl WatchSet {
    /// The watched paths are the SAME expressions the loaders read —
    /// `config::config_path` and `config::themes_dir` (one owner per
    /// path, review #19): a watch on a path nothing loads from is how a
    /// theme edit "applied live" to an engine that never read it.
    pub fn daemon_inputs() -> WatchSet {
        let mut w = WatchSet::default();
        if let Ok(p) = crate::config::config_path() {
            w.files.push(p);
        }
        if let Some(d) = crate::config::themes_dir() {
            w.dirs.push(d);
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
                // Skip dotfiles: editor artifacts (vim .swp, emacs
                // .#lock) and our own seed tmp files would otherwise
                // trigger a swap per keystroke of a live edit session.
                // Stat by PATH, not DirEntry::metadata — the entry form
                // is symlink_metadata and never sees a stowed target
                // change (review #19/#21, measured).
                .filter(|e| !e.file_name().to_string_lossy().starts_with('.'))
                .map(|e| (e.file_name(), file_stat(fs::metadata(e.path()))))
                .collect();
            entries.sort();
            entries
        })
        .collect();
    (files, dirs)
}

/// First ATTEMPT, not first success — sound today because the
/// construction-time `factory()?` in `reloading_with` propagates failure
/// and the daemon exits, so attempt and success coincide. If startup
/// ever degrades to retry instead of exiting, bind this to the first
/// SUCCESSFUL build, or the retry silently becomes LoadOnly and a stale
/// corpus never folds in.
fn swap_policy(started: &AtomicBool) -> CorpusPolicy {
    if started.swap(true, Ordering::SeqCst) {
        CorpusPolicy::LoadOnly
    } else {
        CorpusPolicy::RebuildIfStale
    }
}

/// Engine that follows its inputs: when any watched file or directory
/// changes, the reloader (rate-limited to one stat pass per
/// `min_interval`) swaps in a freshly built engine. Sessions are shared
/// across swaps, so open shells keep their hello universes, dismissals
/// and live harvests; a swap that fails keeps the current engine. This
/// is why `theme set`, `config set`, `data rebuild` and `data forget`
/// never ask for a daemon restart — and why an invalid edit behaves
/// exactly like a daemon restart would (per-key fallback with warnings),
/// never worse. Swaps never rebuild a merely-stale corpus (S7,
/// `CorpusPolicy::LoadOnly`) — only the daemon's first engine does, so a
/// swap cannot chase a moving histfile in a rebuild loop. The one
/// exception is an absent or unreadable cache, whose fallback build
/// costs a single extra swap: the save re-triggers the watch once, and
/// the second swap loads cleanly and writes nothing.
pub fn reloading_render(watch: WatchSet, min_interval: Duration) -> Result<Render> {
    let sessions = crate::engine::SharedSessions::default();
    let started = std::sync::Arc::new(AtomicBool::new(false));
    let mk = move || -> Result<Render> {
        let engine = std::sync::Arc::new(crate::engine::Engine::new_shared(
            sessions.clone(),
            swap_policy(&started),
        )?);
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
    let current = std::sync::Arc::new(RwLock::new(factory()?));
    let factory = std::sync::Arc::new(factory);
    let busy = std::sync::Arc::new(AtomicBool::new(false));
    let watch = std::sync::Arc::new(watch);
    // Stat AFTER the first build: a write landing during it must trigger
    // a reload, not be mistaken for the state already built. (The first
    // engine may itself write the corpus cache — a stamp taken before it
    // would see that write as an operator action and swap for nothing.)
    let state = std::sync::Arc::new(Mutex::new((Instant::now(), Some(inputs_stat(&watch)))));
    Ok(std::sync::Arc::new(move |req| {
        if !watch.is_empty() {
            let due = {
                let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                if st.0.elapsed() >= min_interval {
                    st.0 = Instant::now();
                    true
                } else {
                    false
                }
            };
            // Poll AND build off the request path: a themes read_dir on a
            // slow or network-mounted $HOME is a different tail than a
            // clock check, and whichever request pays it does so against
            // the shim's 5ms deadline. Here the request path is an
            // elapsed check and a CAS; `busy` spans the whole pass, so at
            // most one poll-or-build is in flight and requests keep
            // flowing on the current engine until the swap lands. A
            // failed build clears the stamp so a later interval retries
            // (bounded: one build per interval) instead of freezing on
            // the old engine until another edit.
            if due && !busy.swap(true, Ordering::SeqCst) {
                let current = current.clone();
                let factory = factory.clone();
                let busy = busy.clone();
                let state = state.clone();
                let watch = watch.clone();
                std::thread::spawn(move || {
                    let now = Some(inputs_stat(&watch));
                    let changed = {
                        let mut st = state.lock().unwrap_or_else(|e| e.into_inner());
                        if now != st.1 {
                            st.1 = now;
                            true
                        } else {
                            false
                        }
                    };
                    if changed {
                        match factory() {
                            Ok(r) => {
                                *current.write().unwrap_or_else(|e| e.into_inner()) = r;
                            }
                            Err(e) => {
                                eprintln!("clicue daemon: reload failed, keeping current: {e:#}");
                                state.lock().unwrap_or_else(|e| e.into_inner()).1 = None;
                            }
                        }
                    }
                    busy.store(false, Ordering::SeqCst);
                });
            }
        }
        let r = current.read().unwrap_or_else(|e| e.into_inner()).clone();
        r(req)
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{Reply, Request, Session, VERSION};
    use std::os::unix::fs::DirBuilderExt;
    use std::sync::atomic::AtomicUsize;

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("clicue-reload-{}-{tag}", std::process::id()));
        let _ = fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&dir);
        use std::os::unix::fs::PermissionsExt;
        let _ = fs::set_permissions(&dir, fs::Permissions::from_mode(0o700));
        dir
    }

    fn request() -> Request {
        serde_json::from_str(
            &serde_json::to_string(&Request {
                v: VERSION,
                session: Session {
                    pid: std::process::id(),
                    start: 0,
                },
                event: crate::protocol::Event::Redraw,
                buffer: "car".into(),
                cursor: 3,
                cols: 120,
                lines: 40,
                keymap: "main".into(),
                pending: None,
                env: None,
                hist: vec![],
            })
            .unwrap(),
        )
        .unwrap()
    }

    fn counting_factory(gen: &std::sync::Arc<AtomicUsize>) -> impl Fn() -> Result<Render> {
        let g = gen.clone();
        move || {
            let n = g.fetch_add(1, Ordering::SeqCst) + 1;
            Ok(std::sync::Arc::new(move |_req| Reply {
                card: format!("gen{n}"),
                ..Reply::stand_down()
            }) as Render)
        }
    }

    fn until(render: &Render, want: &str) {
        let deadline = Instant::now() + Duration::from_secs(5);
        loop {
            let got = render(request()).card;
            if got == want {
                return;
            }
            assert!(Instant::now() < deadline, "expected {want}, stuck at {got}");
            std::thread::sleep(Duration::from_millis(5));
        }
    }

    #[test]
    fn reload_swaps_on_config_change_and_keeps_current_on_failure() {
        let dir = temp_dir("cfg");
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
        assert_eq!(render(request()).card, "gen1");
        assert_eq!(render(request()).card, "gen1", "unchanged file, no swap");
        // mtime granularity can be coarse; changing LENGTH always registers
        fs::write(&cfg, "theme = \"mono\"  \n").unwrap();
        until(&render, "gen2");
        // build 3 fails (async): the current engine survives, and the
        // cleared stamp retries on a later interval WITHOUT another edit
        fs::write(&cfg, "theme = \"plain\"\n").unwrap();
        until(&render, "gen4");
    }

    #[test]
    fn reload_watches_every_input_kind() {
        // One reloader for every input (S7): the corpus cache (`data
        // rebuild` / `data forget` rewrite it) and the theme files apply
        // live through the same swap as the config file.
        let dir = temp_dir("inputs");
        let corpus = dir.join("corpus.json");
        let themes = dir.join("themes");
        fs::create_dir_all(&themes).unwrap();
        fs::write(&corpus, "{}").unwrap();
        let gen = std::sync::Arc::new(AtomicUsize::new(0));
        let render = reloading_with(
            WatchSet {
                files: vec![corpus.clone()],
                dirs: vec![themes.clone()],
            },
            Duration::ZERO,
            counting_factory(&gen),
        )
        .unwrap();
        assert_eq!(render(request()).card, "gen1");
        // A corpus rewrite (what `data rebuild` does) swaps.
        fs::write(&corpus, "{\"stamp\":\"rebuilt\"}").unwrap();
        until(&render, "gen2");
        // A theme file APPEARING swaps…
        fs::write(themes.join("mine.toml"), "accent = \"#ff0000\"\n").unwrap();
        until(&render, "gen3");
        // …and an in-place EDIT swaps too (dir mtime alone would miss it;
        // the length differs so coarse mtime granularity cannot hide it).
        fs::write(themes.join("mine.toml"), "accent = \"#00ff00\"  \n").unwrap();
        until(&render, "gen4");
    }

    #[test]
    fn dotfile_churn_does_not_swap() {
        // Editor artifacts (vim .swp, emacs .#lock) and seed tmp files
        // land in the watched directory during live edits — they must not
        // trigger swaps (review #21).
        let dir = temp_dir("dotfiles");
        let themes = dir.join("themes");
        fs::create_dir_all(&themes).unwrap();
        let gen = std::sync::Arc::new(AtomicUsize::new(0));
        let render = reloading_with(
            WatchSet {
                files: vec![],
                dirs: vec![themes.clone()],
            },
            Duration::ZERO,
            counting_factory(&gen),
        )
        .unwrap();
        assert_eq!(render(request()).card, "gen1");
        fs::write(themes.join(".aura.toml.swp"), "editor junk").unwrap();
        fs::write(themes.join(".#mine.toml"), "lock").unwrap();
        for _ in 0..10 {
            assert_eq!(render(request()).card, "gen1", "dotfile churn swapped");
            std::thread::sleep(Duration::from_millis(3));
        }
        // A real file still registers.
        fs::write(themes.join("mine.toml"), "accent = \"fg=#ff0000\"\n").unwrap();
        until(&render, "gen2");
    }

    #[test]
    fn edits_behind_a_symlink_register() {
        // stow/chezmoi configs are symlinks into the repo; the entry-form
        // metadata never sees the target change (review #19, measured).
        let dir = temp_dir("symlink");
        let themes = dir.join("themes");
        let real = dir.join("real.toml");
        fs::create_dir_all(&themes).unwrap();
        fs::write(&real, "accent = \"#ff0000\"\n").unwrap();
        std::os::unix::fs::symlink(&real, themes.join("mine.toml")).unwrap();
        let gen = std::sync::Arc::new(AtomicUsize::new(0));
        let render = reloading_with(
            WatchSet {
                files: vec![],
                dirs: vec![themes],
            },
            Duration::ZERO,
            counting_factory(&gen),
        )
        .unwrap();
        assert_eq!(render(request()).card, "gen1");
        fs::write(&real, "accent = \"#00ff00\"  \n").unwrap();
        until(&render, "gen2");
    }

    #[test]
    fn daemon_inputs_watch_the_paths_the_loaders_read() {
        // The gap review #19 caught: a watch on a path nothing loads from.
        // The watched set must be built from the SAME functions the
        // loaders call, so the two cannot drift apart.
        let w = WatchSet::daemon_inputs();
        if let Ok(p) = crate::config::config_path() {
            assert!(w.files.contains(&p), "config file unwatched");
        }
        if let Ok(p) = crate::corpus::cache_path() {
            assert!(w.files.contains(&p), "corpus cache unwatched");
        }
        if let Some(d) = crate::config::themes_dir() {
            assert!(
                w.dirs.contains(&d),
                "themes dir unwatched, or watched at a different path than the loader reads"
            );
        }
    }

    #[test]
    fn only_the_first_swap_rebuilds() {
        let started = AtomicBool::new(false);
        assert_eq!(swap_policy(&started), CorpusPolicy::RebuildIfStale);
        assert_eq!(swap_policy(&started), CorpusPolicy::LoadOnly);
        assert_eq!(swap_policy(&started), CorpusPolicy::LoadOnly);
    }
}
