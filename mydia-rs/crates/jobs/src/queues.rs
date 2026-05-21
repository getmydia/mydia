//! Background-job queue identifiers and per-queue concurrency limits.
//!
//! Phoenix runs nine Oban queues with the concurrency caps declared in
//! `config/config.exs:255-265`. mydia-rs mirrors the names and limits
//! exactly — workers in U17 declare which queue they live on, and the
//! apalis worker builders honor the same concurrency caps so cross-
//! backend behavior at cutover is identical.

use std::fmt;

/// Background queue identity. The ordering and naming intentionally
/// matches the Oban `queues:` list in `config/config.exs` so a
/// `Queue::name()` round-trips against any persisted job row produced
/// during the parallel-window dogfood.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Queue {
    /// `critical` — high-priority short jobs (e.g., `MediaImport` after
    /// a manual user action). Concurrency 10.
    Critical,
    /// `default` — catch-all for jobs without a domain home.
    /// Concurrency 5.
    Default,
    /// `media` — library scanner, reorganize, reclassify, file
    /// analysis. Concurrency 3.
    Media,
    /// `search` — Movie/TV-show release search workers. Concurrency 2.
    Search,
    /// `analysis` — ffprobe-driven media-file analysis (single-file).
    /// Concurrency 2.
    Analysis,
    /// `notifications` — outbound notifier fan-out. Concurrency 1.
    Notifications,
    /// `maintenance` — event cleanup, blacklist cleanup, trash
    /// cleanup, definition sync, health check. Concurrency 1.
    Maintenance,
    /// `import_lists` — TMDB-watchlist and custom-URL list sync
    /// workers. Concurrency 2.
    ImportLists,
    /// `integrations` — Trakt sync, Trakt token refresh, media-server
    /// watched sync. Concurrency 2.
    Integrations,
}

impl Queue {
    /// Wire name. Matches the Phoenix `config :mydia, Oban, queues:`
    /// keyword list verbatim so a job row inserted by one backend
    /// reads correctly from the other during the parallel window (the
    /// apalis-sql storage and Oban table schemas do not overlap, but
    /// the name strings are the canonical reference operators see).
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Critical => "critical",
            Self::Default => "default",
            Self::Media => "media",
            Self::Search => "search",
            Self::Analysis => "analysis",
            Self::Notifications => "notifications",
            Self::Maintenance => "maintenance",
            Self::ImportLists => "import_lists",
            Self::Integrations => "integrations",
        }
    }

    /// Concurrency cap matching `config/config.exs:255-265`. Apalis
    /// worker builders pass this to `.concurrency(n)`.
    #[must_use]
    pub const fn concurrency(self) -> usize {
        match self {
            Self::Critical => 10,
            Self::Default => 5,
            Self::Media => 3,
            Self::Search | Self::Analysis | Self::ImportLists | Self::Integrations => 2,
            Self::Notifications | Self::Maintenance => 1,
        }
    }

    /// Iterate every queue. The ordering matches `config/config.exs`
    /// so the supervision-tree wire-up and operator logs read in the
    /// same order the Phoenix shape uses.
    pub fn all() -> impl Iterator<Item = Self> {
        [
            Self::Critical,
            Self::Default,
            Self::Media,
            Self::Search,
            Self::Analysis,
            Self::Notifications,
            Self::Maintenance,
            Self::ImportLists,
            Self::Integrations,
        ]
        .into_iter()
    }
}

impl fmt::Display for Queue {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.name())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_match_oban_config() {
        // Names verbatim from `config/config.exs:255-265`. If a queue
        // name drifts, dual-backend operator docs and admin LiveView
        // labels break together.
        assert_eq!(Queue::Critical.name(), "critical");
        assert_eq!(Queue::Default.name(), "default");
        assert_eq!(Queue::Media.name(), "media");
        assert_eq!(Queue::Search.name(), "search");
        assert_eq!(Queue::Analysis.name(), "analysis");
        assert_eq!(Queue::Notifications.name(), "notifications");
        assert_eq!(Queue::Maintenance.name(), "maintenance");
        assert_eq!(Queue::ImportLists.name(), "import_lists");
        assert_eq!(Queue::Integrations.name(), "integrations");
    }

    #[test]
    fn concurrencies_match_oban_config() {
        assert_eq!(Queue::Critical.concurrency(), 10);
        assert_eq!(Queue::Default.concurrency(), 5);
        assert_eq!(Queue::Media.concurrency(), 3);
        assert_eq!(Queue::Search.concurrency(), 2);
        assert_eq!(Queue::Analysis.concurrency(), 2);
        assert_eq!(Queue::Notifications.concurrency(), 1);
        assert_eq!(Queue::Maintenance.concurrency(), 1);
        assert_eq!(Queue::ImportLists.concurrency(), 2);
        assert_eq!(Queue::Integrations.concurrency(), 2);
    }

    #[test]
    fn all_iterator_covers_every_variant() {
        let queues: Vec<_> = Queue::all().collect();
        assert_eq!(queues.len(), 9);
    }

    #[test]
    fn display_matches_name() {
        assert_eq!(Queue::Media.to_string(), "media");
    }
}
