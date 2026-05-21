//! Integration tests covering the 24 apalis workers.
//!
//! Each worker family gets at least one happy-path test that pushes
//! an args payload through the matching `handle` fn. The test
//! fixture spins up an in-memory `SQLite` pool, registers the apalis
//! migration set, and creates the minimal schema tables the worker
//! reads.
//!
//! Workers whose write half is delegated to Phoenix during the
//! parallel-window cutover are exercised through their entry path —
//! the test verifies the args struct deserializes and the worker
//! returns `Ok(())` (or the expected `WorkerError` for invalid
//! arguments).

use std::sync::Arc;

use apalis::prelude::Data;
use mydia_rs_db::Db;
use mydia_rs_downloads::ClientRegistry;
use mydia_rs_indexers::IndexerRegistry;
use mydia_rs_jobs::workers::{
    blacklist_cleanup, cardigann_health_check, definition_sync, download_monitor, event_cleanup,
    fetch_album_cover, file_analysis, import_list_auto_add, import_list_scheduler,
    import_list_sync, import_session_cleanup, library_reorganize, library_scanner, media_import,
    media_reclassify, media_server_watched_sync, metadata_refresh, movie_search,
    thumbnail_generation, trakt_sync, trakt_token_refresh, trash_cleanup, tv_show_search,
    tvdb_id_backfill,
};
use mydia_rs_jobs::workers::{
    BlacklistCleanupArgs, CardigannHealthCheckArgs, DefinitionSyncArgs, DownloadMonitorArgs,
    EventCleanupArgs, FetchAlbumCoverArgs, FileAnalysisArgs, ImportListAutoAddArgs,
    ImportListSchedulerArgs, ImportListSyncArgs, ImportSessionCleanupArgs, LibraryReorganizeArgs,
    LibraryScannerArgs, MediaImportArgs, MediaReclassifyArgs, MediaServerWatchedSyncArgs,
    MetadataRefreshArgs, MovieSearchArgs, ThumbnailGenerationArgs, TraktSyncArgs,
    TraktTokenRefreshArgs, TrashCleanupArgs, TvShowSearchArgs, TvdbIdBackfillArgs,
};
use mydia_rs_jobs::AppContext;
use mydia_rs_metadata::ProviderRegistry;
use mydia_rs_pubsub::{topics, Pubsub};
use sqlx::sqlite::SqlitePoolOptions;

/// Create an in-memory `SQLite` `Db` and apply the minimal tables the
/// workers reach for. The fixture is intentionally light — the apalis
/// migration set is NOT applied because the workers tested here only
/// read application tables.
async fn fixture_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("open in-memory sqlite");

    // Minimal schema for the workers under test. The shapes mirror the
    // Phoenix migrations relevant to this Unit; only the columns
    // workers SELECT/UPDATE are present.
    for stmt in [
        "CREATE TABLE library_paths (
            id TEXT PRIMARY KEY,
            path TEXT NOT NULL,
            type TEXT NOT NULL,
            monitored INTEGER NOT NULL DEFAULT 1,
            last_scan_status TEXT,
            last_scan_at TEXT,
            last_scan_error TEXT,
            inserted_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        "CREATE TABLE media_files (
            id TEXT PRIMARY KEY,
            media_item_id TEXT,
            path TEXT NOT NULL,
            deleted_at TEXT,
            analyzed_at TEXT,
            duration REAL,
            analysis_attempts INTEGER NOT NULL DEFAULT 0,
            inserted_at TEXT NOT NULL DEFAULT (datetime('now')),
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        "CREATE TABLE media_items (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL,
            title TEXT NOT NULL,
            year INTEGER,
            tvdb_id TEXT,
            monitored INTEGER NOT NULL DEFAULT 1,
            updated_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        "CREATE TABLE download_release_blacklist (
            id TEXT PRIMARY KEY,
            expires_at TEXT
        )",
        "CREATE TABLE import_sessions (
            id TEXT PRIMARY KEY,
            status TEXT,
            expires_at TEXT,
            completed_at TEXT
        )",
        "CREATE TABLE user_integrations (
            id TEXT PRIMARY KEY,
            user_id TEXT NOT NULL,
            provider TEXT NOT NULL,
            access_token TEXT,
            refresh_token TEXT,
            token_expires_at TEXT,
            enabled INTEGER NOT NULL DEFAULT 1
        )",
        "CREATE TABLE events (
            id TEXT PRIMARY KEY,
            inserted_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
        "CREATE TABLE import_lists (
            id TEXT PRIMARY KEY,
            enabled INTEGER NOT NULL DEFAULT 1,
            auto_add INTEGER NOT NULL DEFAULT 0,
            type TEXT NOT NULL DEFAULT 'tmdb_trending',
            last_sync_at TEXT,
            sync_interval_hours INTEGER NOT NULL DEFAULT 6,
            inserted_at TEXT NOT NULL DEFAULT (datetime('now'))
        )",
    ] {
        sqlx::query(stmt)
            .execute(&pool)
            .await
            .expect("create fixture table");
    }

    Db::Sqlite(pool)
}

fn fixture_ctx(db: Db) -> AppContext {
    AppContext::new(
        db,
        Pubsub::new(),
        Arc::new(ProviderRegistry::empty()),
        Arc::new(IndexerRegistry::new()),
        Arc::new(ClientRegistry::new()),
    )
}

// -- Maintenance workers --------------------------------------------------

#[tokio::test]
async fn blacklist_cleanup_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    blacklist_cleanup(BlacklistCleanupArgs::default(), Data::new(ctx))
        .await
        .expect("blacklist cleanup succeeds with no rows");
}

#[tokio::test]
async fn blacklist_cleanup_deletes_expired_rows() {
    let db = fixture_db().await;
    let Db::Sqlite(ref pool) = db else {
        panic!("expected SQLite fixture")
    };
    sqlx::query("INSERT INTO download_release_blacklist (id, expires_at) VALUES (?, ?)")
        .bind("expired")
        .bind("2020-01-01T00:00:00Z")
        .execute(pool)
        .await
        .unwrap();
    sqlx::query("INSERT INTO download_release_blacklist (id, expires_at) VALUES (?, NULL)")
        .bind("permanent")
        .execute(pool)
        .await
        .unwrap();

    let ctx = fixture_ctx(db.clone());
    blacklist_cleanup(BlacklistCleanupArgs::default(), Data::new(ctx))
        .await
        .unwrap();

    let (count,): (i64,) = sqlx::query_as("SELECT count(*) FROM download_release_blacklist")
        .fetch_one(pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "permanent row survives, expired row gone");
}

#[tokio::test]
async fn trash_cleanup_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    trash_cleanup(TrashCleanupArgs::default(), Data::new(ctx))
        .await
        .expect("trash cleanup succeeds on empty trash");
}

#[tokio::test]
async fn trash_cleanup_rejects_zero_retention() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = trash_cleanup(
        TrashCleanupArgs {
            retention_days: Some(0),
        },
        Data::new(ctx),
    )
    .await
    .expect_err("zero retention should error");
    assert!(format!("{err:?}").contains("retention_days"));
}

#[tokio::test]
async fn event_cleanup_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    event_cleanup(EventCleanupArgs::default(), Data::new(ctx))
        .await
        .expect("event cleanup succeeds with no rows");
}

#[tokio::test]
async fn import_session_cleanup_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    import_session_cleanup(ImportSessionCleanupArgs::default(), Data::new(ctx))
        .await
        .expect("import session cleanup succeeds with no rows");
}

#[tokio::test]
async fn cardigann_health_check_skips_when_disabled() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    // ENABLE_CARDIGANN unset (the default), so the worker skips.
    cardigann_health_check(CardigannHealthCheckArgs::default(), Data::new(ctx))
        .await
        .expect("disabled cardigann check is a no-op");
}

#[tokio::test]
async fn definition_sync_skips_when_disabled() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    definition_sync(DefinitionSyncArgs::default(), Data::new(ctx))
        .await
        .expect("disabled cardigann definition sync is a no-op");
}

// -- Library workers ------------------------------------------------------

#[tokio::test]
async fn library_scanner_handles_missing_path_id() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    // Single-library mode with a non-existent id should surface a
    // NotFound error.
    let err = library_scanner(
        LibraryScannerArgs {
            library_path_id: Some("does-not-exist".into()),
            library_type: None,
            skip_delay: true,
        },
        Data::new(ctx),
    )
    .await
    .expect_err("missing library path id should error");
    assert!(format!("{err:?}").contains("library_path"));
}

#[tokio::test]
async fn library_scanner_scan_all_with_no_paths_is_ok() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    library_scanner(
        LibraryScannerArgs {
            library_path_id: None,
            library_type: None,
            skip_delay: true,
        },
        Data::new(ctx),
    )
    .await
    .expect("scan-all with no monitored paths is a no-op");
}

#[tokio::test]
async fn library_reorganize_emits_pubsub_events() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let mut rx = ctx.pubsub.subscribe(topics::LIBRARY_SCANNER);
    library_reorganize(
        LibraryReorganizeArgs {
            library_path_id: "fake".into(),
        },
        Data::new(ctx),
    )
    .await
    .expect("library reorganize completes");
    // Two events expected: started + completed.
    let first = rx.try_recv().expect("started event");
    assert_eq!(first.payload["event"], "library_reorganize_started");
    let second = rx.try_recv().expect("completed event");
    assert_eq!(second.payload["event"], "library_reorganize_completed");
}

#[tokio::test]
async fn media_reclassify_emits_pubsub_events() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let mut rx = ctx.pubsub.subscribe(topics::LIBRARY_SCANNER);
    media_reclassify(
        MediaReclassifyArgs {
            library_path_id: "fake".into(),
        },
        Data::new(ctx),
    )
    .await
    .unwrap();
    let first = rx.try_recv().expect("started event");
    assert_eq!(first.payload["event"], "media_reclassify_started");
}

#[tokio::test]
async fn media_import_no_op_for_missing_download() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    media_import(
        MediaImportArgs {
            download_id: "no-such-download".into(),
            target_files: None,
            save_path: None,
            snooze_count: 0,
            use_hardlinks: true,
            move_files: false,
            rename_files: false,
        },
        Data::new(ctx),
    )
    .await
    .expect("media_import is delegated and returns Ok");
}

#[tokio::test]
async fn file_analysis_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    file_analysis(FileAnalysisArgs::default(), Data::new(ctx))
        .await
        .expect("file analysis on empty table is a no-op");
}

#[tokio::test]
async fn thumbnail_generation_publishes_lifecycle_events() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let mut rx = ctx.pubsub.subscribe(topics::THUMBNAIL_GENERATION);
    thumbnail_generation(
        ThumbnailGenerationArgs {
            media_file_id: Some("foo".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .unwrap();
    let started = rx.try_recv().expect("started event");
    assert_eq!(started.payload["event"], "generation_started");
}

#[tokio::test]
async fn fetch_album_cover_completes() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    fetch_album_cover(
        FetchAlbumCoverArgs {
            album_id: "album-id".into(),
        },
        Data::new(ctx),
    )
    .await
    .expect("fetch_album_cover delegated path returns Ok");
}

#[tokio::test]
async fn tvdb_id_backfill_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    tvdb_id_backfill(TvdbIdBackfillArgs::default(), Data::new(ctx))
        .await
        .expect("tvdb id backfill on empty table is a no-op");
}

// -- Search / metadata ----------------------------------------------------

#[tokio::test]
async fn movie_search_all_monitored_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    movie_search(
        MovieSearchArgs {
            mode: Some("all_monitored".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect("all_monitored mode on empty table is a no-op");
}

#[tokio::test]
async fn movie_search_specific_requires_id() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = movie_search(
        MovieSearchArgs {
            mode: Some("specific".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect_err("specific mode without id should error");
    assert!(format!("{err:?}").contains("media_item_id"));
}

#[tokio::test]
async fn tv_show_search_all_monitored_runs() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    tv_show_search(
        TvShowSearchArgs {
            mode: Some("all_monitored".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn tv_show_search_specific_requires_episode_id() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = tv_show_search(
        TvShowSearchArgs {
            mode: Some("specific".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect_err("specific mode without episode id should error");
    assert!(format!("{err:?}").contains("episode_id"));
}

#[tokio::test]
async fn metadata_refresh_refresh_all_skips_delay() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    metadata_refresh(
        MetadataRefreshArgs {
            refresh_all: true,
            skip_delay: true,
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect("refresh_all with skip_delay completes");
}

#[tokio::test]
async fn metadata_refresh_for_missing_item_errors() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = metadata_refresh(
        MetadataRefreshArgs {
            media_item_id: Some("does-not-exist".into()),
            fetch_episodes: false,
            skip_delay: true,
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect_err("missing media item should error");
    assert!(format!("{err:?}").contains("media_item"));
}

// -- Downloads ------------------------------------------------------------

#[tokio::test]
async fn download_monitor_skips_when_no_clients() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    download_monitor(DownloadMonitorArgs::default(), Data::new(ctx))
        .await
        .expect("no-client setup skips cleanly");
}

// -- Import lists ---------------------------------------------------------

#[tokio::test]
async fn import_list_scheduler_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    import_list_scheduler(ImportListSchedulerArgs::default(), Data::new(ctx))
        .await
        .expect("scheduler on empty table is a no-op");
}

#[tokio::test]
async fn import_list_sync_handles_missing_list() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    import_list_sync(
        ImportListSyncArgs {
            import_list_id: "no-such-list".into(),
            auto_add: false,
        },
        Data::new(ctx),
    )
    .await
    .expect("missing list logs and returns Ok");
}

#[tokio::test]
async fn import_list_sync_picks_up_existing_row() {
    let db = fixture_db().await;
    let Db::Sqlite(ref pool) = db else {
        panic!("expected SQLite fixture")
    };
    sqlx::query(
        "INSERT INTO import_lists (id, enabled, auto_add, type) \
         VALUES (?, 1, 0, 'tmdb_trending')",
    )
    .bind("the-list")
    .execute(pool)
    .await
    .unwrap();

    let ctx = fixture_ctx(db.clone());
    let mut rx = ctx.pubsub.subscribe(topics::IMPORT_LISTS);
    import_list_sync(
        ImportListSyncArgs {
            import_list_id: "the-list".into(),
            auto_add: false,
        },
        Data::new(ctx),
    )
    .await
    .unwrap();
    let event = rx.try_recv().expect("import list sync emits event");
    assert_eq!(event.payload["event"], "import_list_sync_complete");
    assert_eq!(event.payload["import_list_id"], "the-list");
}

#[tokio::test]
async fn import_list_auto_add_completes() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    import_list_auto_add(
        ImportListAutoAddArgs {
            import_list_id: "list-id".into(),
        },
        Data::new(ctx),
    )
    .await
    .expect("auto-add delegated path returns Ok");
}

// -- Integrations ---------------------------------------------------------

#[tokio::test]
async fn trakt_sync_rejects_unknown_sync_type() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = trakt_sync(
        TraktSyncArgs {
            user_id: "u".into(),
            sync_type: "unknown".into(),
        },
        Data::new(ctx),
    )
    .await
    .expect_err("unknown sync type should error");
    assert!(format!("{err:?}").contains("Unknown sync type"));
}

#[tokio::test]
async fn trakt_sync_accepts_known_types() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    for sync_type in ["full", "history", "ratings", "collection", "watchlist"] {
        trakt_sync(
            TraktSyncArgs {
                user_id: "user-1".into(),
                sync_type: sync_type.into(),
            },
            Data::new(ctx.clone()),
        )
        .await
        .unwrap_or_else(|err| panic!("sync_type={sync_type} should be accepted: {err:?}"));
    }
}

#[tokio::test]
async fn trakt_token_refresh_runs_on_empty_table() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    trakt_token_refresh(TraktTokenRefreshArgs::default(), Data::new(ctx))
        .await
        .expect("trakt token refresh with no integrations is a no-op");
}

#[tokio::test]
async fn media_server_watched_sync_fan_out_mode() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    media_server_watched_sync(
        MediaServerWatchedSyncArgs {
            mode: Some("all_enabled".into()),
            ..Default::default()
        },
        Data::new(ctx),
    )
    .await
    .expect("fan-out mode logs and returns Ok");
}

#[tokio::test]
async fn media_server_watched_sync_single_pair_requires_both_ids() {
    let db = fixture_db().await;
    let ctx = fixture_ctx(db);
    let err = media_server_watched_sync(
        MediaServerWatchedSyncArgs {
            mode: None,
            config_id: Some("cfg".into()),
            user_id: None,
        },
        Data::new(ctx),
    )
    .await
    .expect_err("single pair without user_id should error");
    assert!(format!("{err:?}").contains("config_id"));
}

// -- Args serialization round-trips --------------------------------------

#[test]
fn library_scanner_args_round_trip_through_json() {
    let json =
        serde_json::json!({ "library_path_id": "abc", "library_type": null, "skip_delay": true });
    let args: LibraryScannerArgs = serde_json::from_value(json).unwrap();
    assert_eq!(args.library_path_id.as_deref(), Some("abc"));
    assert!(args.skip_delay);
}

#[test]
fn movie_search_args_round_trip() {
    let json = serde_json::json!({
        "mode": "specific",
        "media_item_id": "uuid-1",
        "min_seeders": 5,
        "blocked_tags": ["cam", "ts"]
    });
    let args: MovieSearchArgs = serde_json::from_value(json).unwrap();
    assert_eq!(args.mode.as_deref(), Some("specific"));
    assert_eq!(args.media_item_id.as_deref(), Some("uuid-1"));
    assert_eq!(args.min_seeders, Some(5));
    assert_eq!(args.blocked_tags.as_ref().unwrap().len(), 2);
}

#[test]
fn media_import_args_default_use_hardlinks_true() {
    let json = serde_json::json!({ "download_id": "d1" });
    let args: MediaImportArgs = serde_json::from_value(json).unwrap();
    assert!(args.use_hardlinks, "use_hardlinks defaults to true");
    assert!(!args.move_files, "move_files defaults to false");
    assert_eq!(args.snooze_count, 0);
}

#[test]
fn metadata_refresh_args_default_fetch_episodes_true() {
    let json = serde_json::json!({ "refresh_all": true });
    let args: MetadataRefreshArgs = serde_json::from_value(json).unwrap();
    assert!(args.refresh_all);
    assert!(
        args.fetch_episodes,
        "fetch_episodes defaults to true even on refresh_all"
    );
}
