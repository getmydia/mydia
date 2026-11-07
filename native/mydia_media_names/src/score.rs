//! Picks the best TMDB search candidate for a parsed title. Pure; no I/O.

use std::collections::HashSet;

use serde::{Deserialize, Serialize};

use crate::names::{clean_title, identity_key};

/// Minimum confidence for a candidate to be accepted.
pub const THRESHOLD: f64 = 0.75;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Candidate {
    pub id: i64,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Wanted {
    pub title: String,
    pub year: Option<i32>,
    pub is_show: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Match {
    pub id: i64,
    pub confidence: f64,
}

fn tokens(s: &str) -> HashSet<String> {
    clean_title(s)
        .split_whitespace()
        .map(|w| {
            w.chars()
                .filter(|c| c.is_alphanumeric())
                .collect::<String>()
                .to_lowercase()
        })
        .filter(|w| !w.is_empty())
        .collect()
}

#[allow(
    clippy::cast_precision_loss,
    reason = "token counts are tiny, well within f64 precision"
)]
fn title_sim(a: &str, b: &str) -> f64 {
    if identity_key(a) == identity_key(b) {
        return 1.0;
    }
    let (ta, tb) = (tokens(a), tokens(b));
    let total = ta.len() + tb.len();
    if total == 0 {
        return 0.0;
    }
    2.0 * ta.intersection(&tb).count() as f64 / total as f64
}

fn year_adjustment(wanted: &Wanted, year: Option<i32>) -> f64 {
    match (wanted.year, year) {
        (Some(w), Some(c)) => match (w - c).abs() {
            0 => 0.0,
            1 => -0.10,
            _ if wanted.is_show => -0.20,
            _ => -0.40,
        },
        _ => -0.05,
    }
}

fn confidence(wanted: &Wanted, c: &Candidate) -> f64 {
    let mut sim = title_sim(&wanted.title, &c.title);
    if let Some(orig) = &c.original_title {
        sim = sim.max(title_sim(&wanted.title, orig));
    }
    (sim + year_adjustment(wanted, c.year)).clamp(0.0, 1.0)
}

/// The best candidate at or above [`THRESHOLD`]; ties keep the earlier one.
pub fn score(wanted: &Wanted, candidates: &[Candidate]) -> Option<Match> {
    let mut best: Option<Match> = None;
    for c in candidates {
        let conf = confidence(wanted, c);
        if best.as_ref().is_none_or(|b| conf > b.confidence) {
            best = Some(Match {
                id: c.id,
                confidence: conf,
            });
        }
    }
    best.filter(|m| m.confidence >= THRESHOLD)
}

#[cfg(test)]
#[allow(clippy::unwrap_used, reason = "tests")]
mod tests {
    use super::*;

    fn cand(id: i64, title: &str, orig: Option<&str>, year: i32) -> Candidate {
        Candidate {
            id,
            title: title.into(),
            original_title: orig.map(Into::into),
            year: Some(year),
        }
    }

    fn want(title: &str, year: Option<i32>, is_show: bool) -> Wanted {
        Wanted {
            title: title.into(),
            year,
            is_show,
        }
    }

    fn assert_conf(m: &Match, expected: f64) {
        assert!((m.confidence - expected).abs() < 1e-9, "{}", m.confidence);
    }

    #[test]
    fn exact_title_and_year_wins() {
        let cs = [
            cand(1, "Quiet Harbor Nights", None, 2014),
            cand(2, "Quiet Harbor", None, 2014),
        ];
        let m = score(&want("Quiet Harbor", Some(2014), false), &cs).unwrap();
        assert_eq!(m.id, 2);
        assert_conf(&m, 1.0);
    }

    #[test]
    fn year_off_by_one_still_matches() {
        let cs = [cand(3, "Copper Valley", None, 2018)];
        let m = score(&want("Copper Valley", Some(2019), false), &cs).unwrap();
        assert_eq!(m.id, 3);
        assert_conf(&m, 0.90);
    }

    #[test]
    fn missing_year_matches() {
        let cs = [cand(3, "Copper Valley", None, 2018)];
        let m = score(&want("Copper Valley", None, false), &cs).unwrap();
        assert_conf(&m, 0.95);
    }

    #[test]
    fn wrong_year_movie_misses() {
        let cs = [cand(3, "Copper Valley", None, 2018)];
        assert_eq!(score(&want("Copper Valley", Some(2001), false), &cs), None);
    }

    #[test]
    fn show_year_drift_is_gentler() {
        let cs = [cand(4, "Lantern Street", None, 2013)];
        let m = score(&want("Lantern Street", Some(2016), true), &cs).unwrap();
        assert_conf(&m, 0.80);
    }

    #[test]
    fn original_title_counts() {
        let cs = [cand(5, "The Blue House", Some("La Casa Azul"), 2010)];
        let m = score(&want("La Casa Azul", Some(2010), false), &cs).unwrap();
        assert_eq!(m.id, 5);
    }

    #[test]
    fn unrelated_titles_miss() {
        let cs = [cand(6, "Glass Meadow", None, 2012)];
        assert_eq!(score(&want("Iron Orchard", Some(2012), false), &cs), None);
    }

    #[test]
    fn ties_keep_tmdb_order() {
        let cs = [
            cand(7, "Copper Valley", None, 2018),
            cand(8, "Copper Valley", None, 2018),
        ];
        let m = score(&want("Copper Valley", Some(2018), false), &cs).unwrap();
        assert_eq!(m.id, 7);
    }

    #[test]
    fn empty_candidates_is_none() {
        assert_eq!(score(&want("Copper Valley", Some(2018), false), &[]), None);
    }
}
