//! 24 apalis workers ported from `lib/mydia/jobs/`.
//!
//! Each worker lives in its own submodule and follows the shape:
//!
//! ```ignore
//! pub struct FooArgs { /* typed fields, NEVER `serde_json::Value` */ }
//! pub const QUEUE: Queue = Queue::Media;
//! pub const MAX_ATTEMPTS: u32 = 3;
//! pub async fn handle(args: FooArgs, data: Data<AppContext>) -> Result<(), JobsError> { ... }
//! ```
//!
//! `Args` deserializes from the same JSON shape Phoenix Oban writes —
//! the parallel window during U30 reads jobs across the apalis/Oban
//! coexistence boundary using the wire-compatible JSON shape.
//!
//! Settings (`LibraryPath`, `QualityProfile`, ...) are re-resolved at
//! execution time from the [`AppContext`] DB pool, never trusted from
//! the args payload. This matches the typed-args pattern from
//! `docs/plans/2026-03-23-refactor-comprehensive-type-safety-plan.md`.

pub mod blacklist_cleanup;
pub mod cardigann_health_check;
pub mod definition_sync;
pub mod download_monitor;
pub mod event_cleanup;
pub mod fetch_album_cover;
pub mod file_analysis;
pub mod import_list_auto_add;
pub mod import_list_scheduler;
pub mod import_list_sync;
pub mod import_session_cleanup;
pub mod library_reorganize;
pub mod library_scanner;
pub mod media_import;
pub mod media_reclassify;
pub mod media_server_watched_sync;
pub mod metadata_refresh;
pub mod movie_search;
pub mod thumbnail_generation;
pub mod trakt_sync;
pub mod trakt_token_refresh;
pub mod trash_cleanup;
pub mod tv_show_search;
pub mod tvdb_id_backfill;

pub use blacklist_cleanup::{blacklist_cleanup, BlacklistCleanupArgs};
pub use cardigann_health_check::{cardigann_health_check, CardigannHealthCheckArgs};
pub use definition_sync::{definition_sync, DefinitionSyncArgs};
pub use download_monitor::{download_monitor, DownloadMonitorArgs};
pub use event_cleanup::{event_cleanup, EventCleanupArgs};
pub use fetch_album_cover::{fetch_album_cover, FetchAlbumCoverArgs};
pub use file_analysis::{file_analysis, FileAnalysisArgs};
pub use import_list_auto_add::{import_list_auto_add, ImportListAutoAddArgs};
pub use import_list_scheduler::{import_list_scheduler, ImportListSchedulerArgs};
pub use import_list_sync::{import_list_sync, ImportListSyncArgs};
pub use import_session_cleanup::{import_session_cleanup, ImportSessionCleanupArgs};
pub use library_reorganize::{library_reorganize, LibraryReorganizeArgs};
pub use library_scanner::{library_scanner, LibraryScannerArgs};
pub use media_import::{media_import, MediaImportArgs};
pub use media_reclassify::{media_reclassify, MediaReclassifyArgs};
pub use media_server_watched_sync::{media_server_watched_sync, MediaServerWatchedSyncArgs};
pub use metadata_refresh::{metadata_refresh, MetadataRefreshArgs};
pub use movie_search::{movie_search, MovieSearchArgs};
pub use thumbnail_generation::{thumbnail_generation, ThumbnailGenerationArgs};
pub use trakt_sync::{trakt_sync, TraktSyncArgs};
pub use trakt_token_refresh::{trakt_token_refresh, TraktTokenRefreshArgs};
pub use trash_cleanup::{trash_cleanup, TrashCleanupArgs};
pub use tv_show_search::{tv_show_search, TvShowSearchArgs};
pub use tvdb_id_backfill::{tvdb_id_backfill, TvdbIdBackfillArgs};
