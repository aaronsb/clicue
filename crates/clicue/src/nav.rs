//! Directory ring scanner for the "you are here" pane.
//!
//! Contract: docs/design-notes/navigation-and-place.md. Up is free (the
//! breadcrumb is a string-split of relayed pwd, never I/O), down is priced
//! (one `read_dir` per ring), and the display falloff IS the cost model:
//! names + counts at −1, a capped count at −2, nothing below. Measured
//! baselines this module must hold: full rings ~0.08 ms warm on a typical
//! project directory; a pathological child (`/usr/bin`, ~5k entries) costs
//! 3.0 ms uncapped and 0.27 ms with the count cap — the "99+" display cap
//! bounds the scan, not just the label.
//!
//! Everything here reads relayed place and the filesystem at render time.
//! NOTHING is persisted — the relay/record line of spec/protocol.md §4c.

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant, SystemTime};

/// Grandchild counts stop here; the display says "99+". Early-stopping at
/// the cap is what bounds a 5k-entry child to ~0.3 ms [MEASURED].
pub const COUNT_CAP: usize = 100;

/// Total scan budget per render. Warm local filesystems finish in well
/// under 1 ms; a fired deadline means a cold network mount, and the pane
/// renders reserved `…` cells that later renders fill (layout keeps height
/// constant per card-layout H7 — cells, not rows).
pub const SCAN_DEADLINE: Duration = Duration::from_millis(5);

/// A grandchild count, or the reason there isn't one.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Count {
    Exact(usize),
    /// Early-stopped at [`COUNT_CAP`]; render as "99+".
    AtLeast(usize),
    /// Permission denied; render as "–".
    Denied,
    /// Deadline fired before this child was counted; render the reserved
    /// `…` cell and try again next render.
    Pending,
}

/// One visible child directory of pwd.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChildEntry {
    pub name: String,
    pub count: Count,
}

/// The rings around a directory. `children`/`siblings` hold visible
/// directories only, sorted by name; dotdirs fold into counts.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Rings {
    pub children: Vec<ChildEntry>,
    /// Dot-directories under pwd, folded to a count ("+n hidden").
    pub hidden: usize,
    /// Visible sibling directory names, self excluded. Empty at `/`.
    pub siblings: Vec<String>,
    /// False when the deadline fired; some counts are [`Count::Pending`]
    /// and a later render should call [`NavScanner::rings`] again.
    pub complete: bool,
}

#[derive(Debug, Clone)]
struct CachedListing {
    mtime: Option<SystemTime>,
    /// (name, is_dir) for every entry; dirs and non-dirs both matter for
    /// the hidden fold and for count reuse.
    dirs: Vec<String>,
    hidden_dirs: usize,
}

#[derive(Debug, Clone, Copy)]
struct CachedCount {
    mtime: Option<SystemTime>,
    count: Count,
}

/// Per-daemon scanner with a cross-shell cache: the daemon outlives
/// shells, so one operator's terminals share warmth. Keys are absolute
/// paths; revalidation is one stat per directory per render.
#[derive(Debug, Default)]
pub struct NavScanner {
    listings: HashMap<PathBuf, CachedListing>,
    counts: HashMap<PathBuf, CachedCount>,
}

fn dir_mtime(path: &Path) -> Option<SystemTime> {
    fs::metadata(path).ok().and_then(|m| m.modified().ok())
}

impl NavScanner {
    pub fn new() -> Self {
        Self::default()
    }

    /// Visible child-directory names of `path` plus the hidden-dir count,
    /// cached against the directory's own mtime. Symlinks are never
    /// followed (a symlink to a directory is not descended and not
    /// counted as a child — loops are unrepresentable, and lying about
    /// size is worse than omitting).
    fn listing(&mut self, path: &Path) -> Option<&CachedListing> {
        let mtime = dir_mtime(path);
        let fresh = match self.listings.get(path) {
            Some(c) => c.mtime == mtime && mtime.is_some(),
            None => false,
        };
        if !fresh {
            let rd = fs::read_dir(path).ok()?;
            let mut dirs = Vec::new();
            let mut hidden_dirs = 0usize;
            for e in rd.flatten() {
                let is_dir = e.file_type().map(|t| t.is_dir()).unwrap_or(false);
                if !is_dir {
                    continue;
                }
                let name = e.file_name().to_string_lossy().into_owned();
                if name.starts_with('.') {
                    hidden_dirs += 1;
                } else {
                    dirs.push(name);
                }
            }
            dirs.sort_unstable();
            self.listings.insert(
                path.to_path_buf(),
                CachedListing {
                    mtime,
                    dirs,
                    hidden_dirs,
                },
            );
        }
        self.listings.get(path)
    }

    /// Entry count of one directory, capped, cached against its mtime.
    fn count(&mut self, path: &Path) -> Count {
        let mtime = dir_mtime(path);
        if let Some(c) = self.counts.get(path) {
            if c.mtime == mtime && mtime.is_some() {
                return c.count;
            }
        }
        let count = match fs::read_dir(path) {
            Ok(rd) => {
                let mut n = 0usize;
                for _ in rd {
                    n += 1;
                    if n >= COUNT_CAP {
                        break;
                    }
                }
                if n >= COUNT_CAP {
                    Count::AtLeast(n)
                } else {
                    Count::Exact(n)
                }
            }
            Err(_) => Count::Denied,
        };
        self.counts.insert(path.to_path_buf(), CachedCount { mtime, count });
        count
    }

    /// The rings around `pwd`, under [`SCAN_DEADLINE`]. Cheap rings first
    /// (children names, then siblings), the multiplying ring (grandchild
    /// counts) last, so a fired deadline costs detail, never structure.
    pub fn rings(&mut self, pwd: &Path) -> Rings {
        let start = Instant::now();
        let mut rings = Rings {
            complete: true,
            ..Default::default()
        };

        let (child_names, hidden) = match self.listing(pwd) {
            Some(l) => (l.dirs.clone(), l.hidden_dirs),
            None => return rings, // unreadable pwd: empty rings, complete
        };
        rings.hidden = hidden;

        if let Some(parent) = pwd.parent() {
            let self_name = pwd.file_name().map(|n| n.to_string_lossy().into_owned());
            if let Some(l) = self.listing(parent) {
                rings.siblings = l
                    .dirs
                    .iter()
                    .filter(|n| Some(n.as_str()) != self_name.as_deref())
                    .cloned()
                    .collect();
            }
        }

        for name in child_names {
            let count = if start.elapsed() < SCAN_DEADLINE {
                self.count(&pwd.join(&name))
            } else {
                rings.complete = false;
                Count::Pending
            };
            rings.children.push(ChildEntry { name, count });
        }
        rings
    }
}

// ── the navigational class ──────────────────────────────────────────────
// A subclass of pathish with the opposite tier-1 story: navigation is
// non-destructive and its targets are existence-checkable, so the F1
// staleness objection fails twice (design note "The navigational class").
// A runtime constant for now; when the corpus builder starts emitting
// destination data it moves there, for the G2 reason (one copy of a
// judgement call, or two copies drift).
pub const NAVIGATIONAL: &[&str] = &["cd", "chdir", "pushd", "popd", "dirs"];

pub fn is_navigational(cmd: &str) -> bool {
    NAVIGATIONAL.contains(&cmd)
}

// ── target resolution ───────────────────────────────────────────────────

/// Lexical `.`/`..` normalization — the same *logical* resolution zsh's
/// `cd` applies to `$PWD` by default (CHASE_LINKS off), which is why this
/// is string arithmetic and not `canonicalize` (that would follow
/// symlinks and disagree with where the shell will actually say you are).
fn normalize(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for c in path.components() {
        match c {
            std::path::Component::CurDir => {}
            std::path::Component::ParentDir => {
                if !out.pop() {
                    out.push("/");
                }
            }
            other => out.push(other),
        }
    }
    if out.as_os_str().is_empty() {
        out.push("/");
    }
    out
}

/// A path in display form: `~`-abbreviated when under home.
pub fn tilde(path: &Path, home: Option<&str>) -> String {
    let s = path.to_string_lossy();
    if let Some(h) = home.filter(|h| !h.is_empty()) {
        if s == *h {
            return "~".into();
        }
        if let Some(rest) = s.strip_prefix(h) {
            if rest.starts_with('/') {
                return format!("~{rest}");
            }
        }
    }
    s.into_owned()
}

/// Where a typed navigation target lands, resolved against relayed place.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ResolvedTarget {
    pub path: PathBuf,
    pub exists: bool,
}

/// Resolve a navigation word the way the shell will: `~` and `~/…` to
/// home, `-` to `$OLDPWD`, `+N`/`-N` to the dirstack (zsh `$dirstack[N]`,
/// 1-based; `+0` is pwd itself), absolute as itself, anything else
/// relative to pwd — all with logical `..` resolution. None when the
/// word needs state we do not have (`-` with no oldpwd, `+3` off the
/// stack) — unknown fails safe to no row, never to a guess.
pub fn resolve_target(
    typed: &str,
    pwd: &str,
    oldpwd: Option<&str>,
    dirstack: &[String],
    home: Option<&str>,
) -> Option<ResolvedTarget> {
    let path: PathBuf = match typed {
        "" | "~" => PathBuf::from(home?),
        "-" => PathBuf::from(oldpwd?),
        t if t == "+0" => PathBuf::from(pwd),
        t if (t.starts_with('+') || t.starts_with('-'))
            && t.len() > 1
            && t[1..].chars().all(|c| c.is_ascii_digit()) =>
        {
            // cd/pushd +N and -N both index the stack; +N from the top
            // (dirstack[N]), -N from the bottom. Relayed $dirstack
            // excludes pwd, matching zsh's own array.
            let n: usize = t[1..].parse().ok()?;
            let entry = if t.starts_with('+') {
                dirstack.get(n.checked_sub(1)?)?
            } else {
                dirstack.get(dirstack.len().checked_sub(n + 1)?)?
            };
            PathBuf::from(entry)
        }
        t if t == "~" || t.starts_with("~/") => {
            let mut p = PathBuf::from(home?);
            p.push(&t[2..]);
            p
        }
        t if t.starts_with('/') => PathBuf::from(t),
        t => {
            let mut p = PathBuf::from(pwd);
            p.push(t);
            p
        }
    };
    let path = normalize(&path);
    let exists = fs::metadata(&path).map(|m| m.is_dir()).unwrap_or(false);
    Some(ResolvedTarget { path, exists })
}

/// The failure-only recommendation (design note): a suggestion exists
/// ONLY when the typed target does not resolve from here AND exactly one
/// known directory matches its final component — by full name, or
/// failing that by unique prefix. Ambiguity degrades to silence: guessing
/// wrong three ways is worse than the honest resolution-failure row.
/// The pool in the zero-data slice is what relayed place and the scanner
/// already know: children, siblings, ancestors, dirstack, oldpwd.
pub fn did_you_mean(
    typed: &str,
    pwd: &str,
    rings: &Rings,
    oldpwd: Option<&str>,
    dirstack: &[String],
) -> Option<PathBuf> {
    let want = Path::new(typed).file_name()?.to_string_lossy().into_owned();
    let pwdp = Path::new(pwd);
    let mut pool: Vec<PathBuf> = Vec::new();
    pool.extend(rings.children.iter().map(|c| pwdp.join(&c.name)));
    if let Some(parent) = pwdp.parent() {
        pool.extend(rings.siblings.iter().map(|s| parent.join(s)));
    }
    let mut anc = pwdp.parent();
    while let Some(a) = anc {
        pool.push(a.to_path_buf());
        anc = a.parent();
    }
    pool.extend(dirstack.iter().map(PathBuf::from));
    pool.extend(oldpwd.map(PathBuf::from));
    pool.sort_unstable();
    pool.dedup();
    pool.retain(|p| p != pwdp);

    let name_of = |p: &PathBuf| {
        p.file_name()
            .map(|n| n.to_string_lossy().into_owned())
            .unwrap_or_else(|| "/".into())
    };
    let exact: Vec<&PathBuf> = pool.iter().filter(|p| name_of(p) == want).collect();
    match exact.len() {
        1 => return Some(exact[0].clone()),
        0 => {}
        _ => return None, // ambiguous — silence
    }
    let pfx: Vec<&PathBuf> = pool.iter().filter(|p| name_of(p).starts_with(&want)).collect();
    match pfx.len() {
        1 => Some(pfx[0].clone()),
        _ => None,
    }
}

/// Split a pwd into breadcrumb components with `~` substitution: pure
/// string arithmetic on relayed place, zero I/O. `/home/op/a/b` with home
/// `/home/op` → `["~", "a", "b"]`; `/usr/bin` → `["/", "usr", "bin"]`.
pub fn breadcrumb(pwd: &str, home: Option<&str>) -> Vec<String> {
    let rest = match home {
        Some(h) if !h.is_empty() && pwd == h => return vec!["~".into()],
        Some(h) if !h.is_empty() && pwd.starts_with(h) && pwd.as_bytes().get(h.len()) == Some(&b'/') => {
            let mut v = vec!["~".to_string()];
            v.extend(pwd[h.len() + 1..].split('/').map(String::from));
            return v;
        }
        _ => pwd,
    };
    let mut v = vec!["/".to_string()];
    v.extend(rest.split('/').filter(|s| !s.is_empty()).map(String::from));
    v
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Fixture(PathBuf);
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    fn fixture(name: &str) -> Fixture {
        let root = std::env::temp_dir().join(format!("clicue-nav-{name}-{}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("pwd/alpha")).unwrap();
        fs::create_dir_all(root.join("pwd/beta")).unwrap();
        fs::create_dir_all(root.join("pwd/.git")).unwrap();
        fs::create_dir_all(root.join("sibling1")).unwrap();
        fs::create_dir_all(root.join("sibling2")).unwrap();
        for i in 0..3 {
            fs::write(root.join(format!("pwd/alpha/f{i}")), "").unwrap();
        }
        fs::write(root.join("pwd/afile"), "").unwrap();
        Fixture(root)
    }

    #[test]
    fn rings_names_counts_hidden_and_siblings() {
        let fx = fixture("basic");
        let pwd = fx.0.join("pwd");
        let mut sc = NavScanner::new();
        let r = sc.rings(&pwd);
        assert!(r.complete);
        let names: Vec<_> = r.children.iter().map(|c| c.name.as_str()).collect();
        assert_eq!(names, ["alpha", "beta"], "sorted, dotdirs folded, files excluded");
        assert_eq!(r.children[0].count, Count::Exact(3));
        assert_eq!(r.children[1].count, Count::Exact(0));
        assert_eq!(r.hidden, 1);
        assert_eq!(r.siblings, ["sibling1", "sibling2"], "self excluded");
    }

    #[test]
    fn count_early_stops_at_cap() {
        let fx = fixture("cap");
        let big = fx.0.join("pwd/big");
        fs::create_dir_all(&big).unwrap();
        for i in 0..COUNT_CAP + 50 {
            fs::write(big.join(format!("f{i}")), "").unwrap();
        }
        let mut sc = NavScanner::new();
        assert_eq!(sc.count(&big), Count::AtLeast(COUNT_CAP));
    }

    #[test]
    fn symlinked_dir_is_not_a_child() {
        let fx = fixture("symlink");
        let pwd = fx.0.join("pwd");
        // A loop: pwd/loop → pwd. Never followed, never listed.
        std::os::unix::fs::symlink(&pwd, pwd.join("loop")).unwrap();
        let mut sc = NavScanner::new();
        let names: Vec<_> = sc.rings(&pwd).children.iter().map(|c| c.name.clone()).collect();
        assert_eq!(names, ["alpha", "beta"]);
    }

    #[test]
    fn denied_child_is_denied_not_error() {
        let fx = fixture("denied");
        let locked = fx.0.join("pwd/locked");
        fs::create_dir_all(&locked).unwrap();
        let mut perms = fs::metadata(&locked).unwrap().permissions();
        use std::os::unix::fs::PermissionsExt;
        perms.set_mode(0o000);
        fs::set_permissions(&locked, perms.clone()).unwrap();
        let mut sc = NavScanner::new();
        let r = sc.rings(&fx.0.join("pwd"));
        let locked_entry = r.children.iter().find(|c| c.name == "locked");
        // Root sees everything; only assert Denied when the sandbox can't read.
        if fs::read_dir(&locked).is_err() {
            assert_eq!(locked_entry.unwrap().count, Count::Denied);
        }
        perms.set_mode(0o755);
        fs::set_permissions(&locked, perms).unwrap();
    }

    #[test]
    fn cache_revalidates_on_mtime_change() {
        let fx = fixture("mtime");
        let pwd = fx.0.join("pwd");
        let mut sc = NavScanner::new();
        assert_eq!(sc.rings(&pwd).children.len(), 2);
        // A new subdirectory bumps pwd's mtime; the listing must refresh.
        // mtime granularity can be coarse — poke until it visibly moves.
        let before = dir_mtime(&pwd);
        fs::create_dir_all(pwd.join("gamma")).unwrap();
        if dir_mtime(&pwd) == before {
            std::thread::sleep(Duration::from_millis(20));
            fs::create_dir_all(pwd.join("delta")).unwrap();
        }
        let n = sc.rings(&pwd).children.len();
        assert!(n >= 3, "expected refreshed listing, got {n}");
    }

    #[test]
    fn unreadable_pwd_yields_empty_complete_rings() {
        let mut sc = NavScanner::new();
        let r = sc.rings(Path::new("/nonexistent/clicue-nav-test"));
        assert!(r.children.is_empty() && r.siblings.is_empty() && r.complete);
    }

    #[test]
    fn resolve_target_speaks_the_shell_dialect() {
        let fx = fixture("resolve");
        let pwd = fx.0.join("pwd");
        let pwds = pwd.to_string_lossy().into_owned();
        let ds = vec!["/tmp".to_string(), "/var".to_string()];
        let r = |t: &str| resolve_target(t, &pwds, Some("/old"), &ds, Some("/home/op"));

        assert_eq!(r("alpha").unwrap(), ResolvedTarget { path: pwd.join("alpha"), exists: true });
        assert!(!r("missing").unwrap().exists);
        assert_eq!(r("-").unwrap().path, Path::new("/old"));
        assert_eq!(r("~").unwrap().path, Path::new("/home/op"));
        assert_eq!(r("~/x").unwrap().path, Path::new("/home/op/x"));
        assert_eq!(r("..").unwrap(), ResolvedTarget { path: fx.0.clone(), exists: true });
        assert_eq!(r("../sibling1/../sibling2").unwrap().path, fx.0.join("sibling2"));
        assert_eq!(r("+1").unwrap().path, Path::new("/tmp"), "dirstack is 1-based from the top");
        assert_eq!(r("-1").unwrap().path, Path::new("/tmp"), "-N counts from the bottom");
        assert_eq!(r("+0").unwrap().path, pwd);
        assert!(r("+3").is_none(), "off the stack: no row, never a guess");
        assert!(resolve_target("-", &pwds, None, &ds, None).is_none());
        assert_eq!(r("/").unwrap().path, Path::new("/"));
    }

    #[test]
    fn did_you_mean_fires_only_on_unique_match() {
        let fx = fixture("dym");
        let pwd = fx.0.join("pwd");
        let pwds = pwd.to_string_lossy().into_owned();
        let mut sc = NavScanner::new();
        let rings = sc.rings(&pwd);

        // Unique full-name match against a child.
        assert_eq!(
            did_you_mean("nope/alpha", &pwds, &rings, None, &[]),
            Some(pwd.join("alpha"))
        );
        // Unique prefix match against a sibling.
        assert_eq!(
            did_you_mean("sibling1", &pwds, &rings, None, &[]),
            Some(fx.0.join("sibling1"))
        );
        // Ambiguous prefix (sibling1/sibling2) → silence.
        assert_eq!(did_you_mean("sib", &pwds, &rings, None, &[]), None);
        // Nothing matches → silence.
        assert_eq!(did_you_mean("zzz", &pwds, &rings, None, &[]), None);
        // The dirstack is part of the pool.
        let ds = vec!["/somewhere/target-dir".to_string()];
        assert_eq!(
            did_you_mean("target-dir", &pwds, &rings, None, &ds),
            Some(PathBuf::from("/somewhere/target-dir"))
        );
    }

    #[test]
    fn tilde_display() {
        assert_eq!(tilde(Path::new("/home/op/a"), Some("/home/op")), "~/a");
        assert_eq!(tilde(Path::new("/home/op"), Some("/home/op")), "~");
        assert_eq!(tilde(Path::new("/home/opx"), Some("/home/op")), "/home/opx");
        assert_eq!(tilde(Path::new("/usr"), None), "/usr");
    }

    #[test]
    fn breadcrumb_is_pure_string_arithmetic() {
        assert_eq!(breadcrumb("/home/op/a/b", Some("/home/op")), ["~", "a", "b"]);
        assert_eq!(breadcrumb("/home/op", Some("/home/op")), ["~"]);
        assert_eq!(breadcrumb("/home/opx/a", Some("/home/op")), ["/", "home", "opx", "a"]);
        assert_eq!(breadcrumb("/usr/bin", None), ["/", "usr", "bin"]);
        assert_eq!(breadcrumb("/", None), ["/"]);
    }
}
