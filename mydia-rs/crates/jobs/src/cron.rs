//! Cron schedule for periodic background workers.
//!
//! Phoenix defines 14 cron entries in `Oban.Plugins.Cron`'s
//! `crontab:` keyword list at `config/config.exs:270-300`. mydia-rs
//! mirrors them entry-for-entry: same schedule expressions, same
//! workers (referenced by name string since the actual worker types
//! land in U17), same optional args payload.
//!
//! ## Scope at U15
//!
//! This module declares the schedule. Wiring each entry to an apalis
//! worker is U17's responsibility — when the worker structs exist,
//! the supervision tree iterates [`schedule()`] and calls
//! `apalis_cron::CronStream::new(entry.schedule).run_with(handler)`
//! for each entry.

use std::str::FromStr;

use cron::Schedule;
use serde_json::Value;
use thiserror::Error;

use crate::queues::Queue;

/// Symbolic identifier for the apalis worker that will execute the
/// scheduled tick. The string is the unqualified Rust type name (e.g.,
/// `"LibraryScanner"`); the actual worker landing in U17 owns the
/// behavior. Anchoring on the type name string here means U15 doesn't
/// take a dep on U17's worker definitions and U17 doesn't have to
/// rewrite this module to register itself.
pub type WorkerName = &'static str;

/// A single cron schedule entry. Mirrors one row of Phoenix's
/// `crontab: [...]` keyword list.
#[derive(Debug, Clone)]
pub struct CronEntry {
    /// Standard 5-field cron expression. `cron` crate accepts the
    /// 5-field form via `Schedule::from_str` after a `"0 "` prefix is
    /// added — see [`Self::parsed_schedule`].
    pub schedule: &'static str,
    /// Queue the produced job lands on. mydia-rs respects per-queue
    /// concurrency caps, so cron entries on the same queue compete
    /// with each other for slots — same semantics as Oban.
    pub queue: Queue,
    /// Worker name. The supervision tree dispatches by this string
    /// when it builds the cron streams.
    pub worker: WorkerName,
    /// Optional JSON args attached to every scheduled tick. Workers
    /// re-deserialize this at execution time per the
    /// "settings-resolved-at-execution-time" pattern from
    /// `docs/plans/2026-03-23-refactor-comprehensive-type-safety-plan.md`.
    pub args: Option<Value>,
}

#[derive(Debug, Error)]
pub enum CronError {
    #[error("invalid cron expression {expr:?}: {source}")]
    InvalidSchedule {
        expr: String,
        #[source]
        source: cron::error::Error,
    },
}

impl CronEntry {
    /// Parse [`Self::schedule`] into a `cron::Schedule`. Two
    /// normalizations make the Phoenix-side 5-field expressions parse
    /// against the `cron` crate's stricter expectations:
    ///
    /// - Prepend `"0 "` so the 5-field form (minute, hour, day, month,
    ///   weekday) matches the crate's required 6-field form (seconds,
    ///   minute, hour, day, month, weekday). Schedules fire at second
    ///   `0` of the matched minute, identical to Oban.
    /// - Translate `0` in the day-of-week field to `7`. Standard
    ///   crontab accepts both as Sunday (vixie convention); the `cron`
    ///   crate only accepts `1..=7`. Phoenix's config uses `0` (e.g.,
    ///   `"0 2 * * 0"` for Sunday at 02:00).
    pub fn parsed_schedule(&self) -> Result<Schedule, CronError> {
        let normalized = normalize_dow_zero(self.schedule);
        let with_seconds = format!("0 {normalized}");
        Schedule::from_str(&with_seconds).map_err(|source| CronError::InvalidSchedule {
            expr: self.schedule.to_owned(),
            source,
        })
    }
}

/// Translate a `0` in the day-of-week field (5th field, 0-indexed
/// fourth) to `7`. Vixie cron accepts both as Sunday; the `cron`
/// crate rejects `0`. Other fields, ranges (`0-6`), steps (`*/2`),
/// and lists (`0,3,5`) are passed through unchanged.
fn normalize_dow_zero(expr: &str) -> String {
    let parts: Vec<&str> = expr.split_whitespace().collect();
    if parts.len() != 5 {
        return expr.to_owned();
    }
    let dow = parts[4];
    // Lone `0` → Sunday in vixie, must become `7` for `cron` crate.
    // Don't touch ranges/lists/steps — those need richer parsing and
    // none of Phoenix's current expressions use them in the dow field.
    let normalized_dow = if dow == "0" { "7" } else { dow };
    format!(
        "{} {} {} {} {}",
        parts[0], parts[1], parts[2], parts[3], normalized_dow
    )
}

/// The full cron schedule, mirroring `config/config.exs:270-300` line
/// for line. Order matches Phoenix so operator logs read the same
/// way during the parallel window.
#[must_use]
pub fn schedule() -> Vec<CronEntry> {
    vec![
        // Monitor downloads every 2 minutes
        CronEntry {
            schedule: "*/2 * * * *",
            queue: Queue::Default,
            worker: "DownloadMonitor",
            args: None,
        },
        // Search for monitored movies every hour
        CronEntry {
            schedule: "0 * * * *",
            queue: Queue::Search,
            worker: "MovieSearch",
            args: Some(serde_json::json!({ "mode": "all_monitored" })),
        },
        // Search for monitored TV shows every 30 minutes
        CronEntry {
            schedule: "*/30 * * * *",
            queue: Queue::Search,
            worker: "TVShowSearch",
            args: Some(serde_json::json!({ "mode": "all_monitored" })),
        },
        // Clean up old events every Sunday at 2 AM
        CronEntry {
            schedule: "0 2 * * 0",
            queue: Queue::Maintenance,
            worker: "EventCleanup",
            args: None,
        },
        // Sync Cardigann definitions daily at 3 AM
        CronEntry {
            schedule: "0 3 * * *",
            queue: Queue::Maintenance,
            worker: "DefinitionSync",
            args: None,
        },
        // Check Cardigann indexer health every hour
        CronEntry {
            schedule: "0 * * * *",
            queue: Queue::Maintenance,
            worker: "CardigannHealthCheck",
            args: None,
        },
        // Clean up old import sessions daily at 4 AM
        CronEntry {
            schedule: "0 4 * * *",
            queue: Queue::Maintenance,
            worker: "ImportSessionCleanup",
            args: None,
        },
        // Check for import lists due for sync every 15 minutes
        CronEntry {
            schedule: "*/15 * * * *",
            queue: Queue::ImportLists,
            worker: "ImportListScheduler",
            args: None,
        },
        // Refresh metadata for all monitored items weekly on Sunday at 5 AM
        CronEntry {
            schedule: "0 5 * * 0",
            queue: Queue::Default,
            worker: "MetadataRefresh",
            args: Some(serde_json::json!({ "refresh_all": true })),
        },
        // Refresh Trakt tokens approaching expiry daily at 6 AM
        CronEntry {
            schedule: "0 6 * * *",
            queue: Queue::Integrations,
            worker: "TraktTokenRefresh",
            args: None,
        },
        // Permanently delete trashed media files past retention period daily at 5 AM
        CronEntry {
            schedule: "0 5 * * *",
            queue: Queue::Maintenance,
            worker: "TrashCleanup",
            args: None,
        },
        // Sync watched status with media servers every 30 minutes
        CronEntry {
            schedule: "*/30 * * * *",
            queue: Queue::Integrations,
            worker: "MediaServerWatchedSync",
            args: Some(serde_json::json!({ "mode": "all_enabled" })),
        },
        // Purge expired release-blacklist rows daily at 5:30 AM (#123)
        CronEntry {
            schedule: "30 5 * * *",
            queue: Queue::Maintenance,
            worker: "BlacklistCleanup",
            args: None,
        },
        // Analyze media files lacking tech metadata every minute (#131)
        CronEntry {
            schedule: "* * * * *",
            queue: Queue::Analysis,
            worker: "FileAnalysis",
            args: None,
        },
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn schedule_matches_phoenix_count() {
        // Phoenix defines exactly 14 cron entries in
        // `config/config.exs:270-300`. If this assertion fires, a
        // Phoenix-side cron landed during the parallel window and
        // mydia-rs needs to follow.
        assert_eq!(schedule().len(), 14);
    }

    #[test]
    fn every_entry_parses_as_valid_cron() {
        for entry in schedule() {
            entry
                .parsed_schedule()
                .unwrap_or_else(|err| panic!("entry {:?} failed to parse: {err}", entry.worker));
        }
    }

    #[test]
    fn workers_with_args_carry_them() {
        let entries = schedule();
        let movie_search = entries
            .iter()
            .find(|e| e.worker == "MovieSearch")
            .expect("MovieSearch cron entry");
        assert_eq!(movie_search.args.as_ref().unwrap()["mode"], "all_monitored");

        let metadata_refresh = entries
            .iter()
            .find(|e| e.worker == "MetadataRefresh")
            .expect("MetadataRefresh cron entry");
        assert_eq!(metadata_refresh.args.as_ref().unwrap()["refresh_all"], true);
    }

    #[test]
    fn workers_without_args_have_none() {
        let entries = schedule();
        let download_monitor = entries
            .iter()
            .find(|e| e.worker == "DownloadMonitor")
            .expect("DownloadMonitor cron entry");
        assert!(download_monitor.args.is_none());
    }

    #[test]
    fn queue_assignment_matches_oban() {
        let entries = schedule();
        let queue_of = |w: &str| entries.iter().find(|e| e.worker == w).map(|e| e.queue);
        assert_eq!(queue_of("MovieSearch"), Some(Queue::Search));
        assert_eq!(queue_of("FileAnalysis"), Some(Queue::Analysis));
        assert_eq!(queue_of("TraktTokenRefresh"), Some(Queue::Integrations));
        assert_eq!(queue_of("ImportListScheduler"), Some(Queue::ImportLists));
        assert_eq!(queue_of("EventCleanup"), Some(Queue::Maintenance));
    }
}
