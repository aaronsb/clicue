//! Ranking: frequency, recency, frecency — and the instrument that makes
//! an ordering interrogable (spec/sources.md §B).
//!
//! Scoring never reads the system clock: `now` is injected everywhere, so
//! orderings are reproducible in tests and the daemon controls time.

use serde::{Deserialize, Serialize};

/// The three modes (B1). An unrecognised configured value falls back to
/// frecency — never silently to some other metric.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum RankMode {
    Frequency,
    Recency,
    #[default]
    Frecency,
}

impl RankMode {
    pub fn parse(s: &str) -> Self {
        match s {
            "frequency" => RankMode::Frequency,
            "recency" => RankMode::Recency,
            _ => RankMode::Frecency,
        }
    }
}

/// Bucketed age multiplier, Mozilla-shaped (B2). Integer arithmetic by
/// design — this sits on the keystroke path. A missing timestamp or a
/// missing clock degrades the entry to plain frequency (B4).
pub fn recency_weight(now: u64, last: u64) -> u64 {
    if last == 0 || now == 0 {
        return 1;
    }
    let days = now.saturating_sub(last) / 86_400;
    match days {
        0 => 16,
        1..=7 => 8,
        8..=30 => 4,
        31..=180 => 2,
        _ => 1,
    }
}

/// Score one name under a mode (B1–B3). u64 comfortably exceeds the
/// 8-digit field that overflowed the prototype's string sort (A6).
pub fn score(mode: RankMode, count: u64, last: u64, now: u64) -> u64 {
    match mode {
        RankMode::Frequency => count,
        RankMode::Recency => last / 86_400,
        RankMode::Frecency => count.saturating_mul(recency_weight(now, last)),
    }
}

/// Partition-not-sort (A4): names with a nonzero score ordered by score
/// descending then name; everything else alphabetical after them. `stats`
/// answers (count, last) per name — zeros for the unknown.
pub fn partition_rank<F>(names: Vec<String>, stats: F, mode: RankMode, now: u64) -> Vec<String>
where
    F: Fn(&str) -> (u64, u64),
{
    let mut scored: Vec<(u64, String)> = Vec::new();
    let mut rest: Vec<String> = Vec::new();
    for n in names {
        let (count, last) = stats(&n);
        let s = score(mode, count, last, now);
        if s > 0 {
            scored.push((s, n));
        } else {
            rest.push(n);
        }
    }
    scored.sort_by(|a, b| b.0.cmp(&a.0).then(a.1.cmp(&b.1)));
    rest.sort();
    scored.into_iter().map(|(_, n)| n).chain(rest).collect()
}

/// One row of `clicue data why <prefix>` (B5): the measurement behind an
/// ordering, so "that order feels off" can be checked, not remembered.
#[derive(Debug, Clone, Serialize)]
pub struct WhyRow {
    pub name: String,
    pub count: u64,
    /// Age in days; None when no timestamp is recorded.
    pub age_days: Option<u64>,
    pub weight: u64,
    pub score: u64,
}

pub fn why<F>(ordered: &[String], stats: F, mode: RankMode, now: u64) -> Vec<WhyRow>
where
    F: Fn(&str) -> (u64, u64),
{
    ordered
        .iter()
        .map(|n| {
            let (count, last) = stats(n);
            WhyRow {
                name: n.clone(),
                count,
                age_days: (last > 0 && now > 0).then(|| now.saturating_sub(last) / 86_400),
                weight: recency_weight(now, last),
                score: score(mode, count, last, now),
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    const NOW: u64 = 1_700_000_000;
    const DAY: u64 = 86_400;

    fn stats_map(entries: &[(&str, u64, u64)]) -> HashMap<String, (u64, u64)> {
        entries
            .iter()
            .map(|(n, c, l)| (n.to_string(), (*c, *l)))
            .collect()
    }

    #[test]
    fn unknown_mode_falls_back_to_frecency() {
        assert_eq!(RankMode::parse("frequency"), RankMode::Frequency);
        assert_eq!(RankMode::parse("weird"), RankMode::Frecency);
    }

    #[test]
    fn buckets_match_the_spec() {
        assert_eq!(recency_weight(NOW, NOW), 16);
        assert_eq!(recency_weight(NOW, NOW - 3 * DAY), 8);
        assert_eq!(recency_weight(NOW, NOW - 20 * DAY), 4);
        assert_eq!(recency_weight(NOW, NOW - 100 * DAY), 2);
        assert_eq!(recency_weight(NOW, NOW - 400 * DAY), 1);
        assert_eq!(recency_weight(NOW, 0), 1, "no timestamp → frequency");
        assert_eq!(recency_weight(0, NOW), 1, "no clock → frequency");
    }

    #[test]
    fn frecency_reorders_what_frequency_would_not() {
        // `git` run 10× long ago; `cargo` run 3× today. Frecency prefers
        // the live habit; frequency prefers the fossil.
        let m = stats_map(&[("git", 10, NOW - 400 * DAY), ("cargo", 3, NOW)]);
        let stats = |n: &str| m.get(n).copied().unwrap_or((0, 0));
        let names = || vec!["git".to_string(), "cargo".to_string()];
        let frec = partition_rank(names(), stats, RankMode::Frecency, NOW);
        assert_eq!(frec, ["cargo", "git"]);
        let freq = partition_rank(names(), stats, RankMode::Frequency, NOW);
        assert_eq!(freq, ["git", "cargo"]);
    }

    #[test]
    fn partition_keeps_unscored_alphabetical_after_scored() {
        let m = stats_map(&[("zeta", 5, NOW)]);
        let stats = |n: &str| m.get(n).copied().unwrap_or((0, 0));
        let ordered = partition_rank(
            vec!["alpha".into(), "zeta".into(), "beta".into()],
            stats,
            RankMode::Frecency,
            NOW,
        );
        assert_eq!(ordered, ["zeta", "alpha", "beta"]);
    }

    #[test]
    fn recency_mode_sends_undated_to_the_alphabetical_tier() {
        let m = stats_map(&[("dated", 1, NOW), ("undated", 99, 0)]);
        let stats = |n: &str| m.get(n).copied().unwrap_or((0, 0));
        let ordered = partition_rank(
            vec!["undated".into(), "dated".into()],
            stats,
            RankMode::Recency,
            NOW,
        );
        assert_eq!(ordered, ["dated", "undated"]);
    }

    #[test]
    fn why_rows_expose_the_arithmetic() {
        let m = stats_map(&[("git", 10, NOW - 3 * DAY)]);
        let stats = |n: &str| m.get(n).copied().unwrap_or((0, 0));
        let rows = why(&["git".to_string()], stats, RankMode::Frecency, NOW);
        assert_eq!(rows[0].weight, 8);
        assert_eq!(rows[0].score, 80);
        assert_eq!(rows[0].age_days, Some(3));
    }
}
