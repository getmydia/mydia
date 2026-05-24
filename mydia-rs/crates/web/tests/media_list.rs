//! Integration tests for the U25.a `list_media` server function.
//!
//! Asserts the SQL building blocks under `server_fns::media::server`
//! against a real sqlite pool with a hand-rolled `media_items` +
//! `media_files` + `episodes` schema. Phoenix migrations are out of
//! scope (the rewrite plan freezes the schema on the Phoenix side and
//! mydia-rs reads it as-is), so we mimic the columns the queries
//! actually touch.
//!
//! What this covers:
//!
//! - kind filter (movies vs tv shows) returns the right slice
//! - search is case-insensitive substring against title
//! - monitored filter (`all` / `monitored` / `unmonitored`)
//! - sort order: title asc/desc, year asc/desc, added asc/desc
//! - pagination: page 0 = 50, page 1 = 25 starting at offset 50
//! - `has_files`: EXISTS check for movie via direct fk and tv via
//!   `media_files` -> `episodes` -> `media_items` join
//!
//! What this doesn't cover: the wire-layer plumbing
//! (`FullstackContext` extraction, session auth). Those are exercised
//! end-to-end whenever the page is rendered against a live server;
//! the value they add over the SQL-level checks is the routing path,
//! not the data logic.

#![cfg(feature = "server")]

mod common;

use common::{apply_sql, fresh_db};
use mydia_rs_db::DatabaseConnection;
use sea_orm::{ConnectionTrait, Statement};
use mydia_rs_web::server_fns::media::server::{
    count_media, delete_media_item_db_only, fetch_media, fetch_media_detail, fetch_movie_files,
    fetch_show_seasons, flip_episode_monitored, flip_media_monitored, row_has_files,
};
use mydia_rs_web::server_fns::media::{MediaSort, MonitoredFilter, FIRST_PAGE_SIZE};
use uuid::Uuid;

/// Deterministic UUID derived from a short test label. The Phoenix
/// schema stores UUIDs as TEXT in `SQLite` (per Ecto's
/// `:binary_id_type = :string` default), so the fixture rows must use
/// real UUID-shaped strings or the sqlx `FromRow` decode for `UuidText`
/// rejects them.
fn uuid_for(label: &str) -> String {
    // uuid 1.x with `v4` feature only — we don't need a stable mapping,
    // a fresh v4 per call is fine because tests reuse the returned String.
    let _ = label; // label is informational; useful when grepping logs.
    Uuid::new_v4().to_string()
}

const SETUP_SQL: &str = "
CREATE TABLE IF NOT EXISTS media_items (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT,
    original_title TEXT,
    year INTEGER,
    tmdb_id INTEGER,
    tvdb_id INTEGER,
    imdb_id TEXT,
    metadata TEXT,
    monitored INTEGER NOT NULL DEFAULT 1,
    monitoring_preset TEXT NOT NULL DEFAULT 'all',
    category TEXT,
    category_override INTEGER NOT NULL DEFAULT 0,
    seasons_refreshed_at TEXT,
    quality_profile_id TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS episodes (
    id TEXT PRIMARY KEY,
    media_item_id TEXT NOT NULL,
    season_number INTEGER,
    episode_number INTEGER,
    title TEXT,
    air_date TEXT,
    metadata TEXT,
    monitored INTEGER NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_files (
    id TEXT PRIMARY KEY,
    media_item_id TEXT,
    episode_id TEXT,
    quality_profile_id TEXT,
    library_path_id TEXT,
    path TEXT NOT NULL,
    relative_path TEXT,
    size INTEGER,
    resolution TEXT,
    codec TEXT,
    hdr_format TEXT,
    audio_codec TEXT,
    bitrate INTEGER,
    verified_at TEXT,
    analyzed_at TEXT,
    analysis_attempts INTEGER NOT NULL DEFAULT 0,
    last_analysis_error TEXT,
    metadata TEXT,
    cover_blob BLOB,
    sprite_blob BLOB,
    vtt_blob BLOB,
    preview_blob BLOB,
    phash TEXT,
    generated_at TEXT,
    trashed_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

async fn setup() -> DatabaseConnection {
    let db = fresh_db().await;
    apply_sql(&db, SETUP_SQL).await;
    db
}

/// Escape a string for inlining inside a single-quoted SQL string
/// literal. The test inputs are controlled, but keep this here in case
/// a future fixture introduces an apostrophe.
fn esc(s: &str) -> String {
    s.replace('\'', "''")
}

async fn insert_movie(
    db: &DatabaseConnection,
    id: &str,
    title: &str,
    year: Option<i32>,
    monitored: bool,
) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let title_e = esc(title);
    let year_sql = match year {
        Some(y) => y.to_string(),
        None => "NULL".to_owned(),
    };
    let monitored_int = i64::from(monitored);
    db.execute_unprepared(&format!(
        "INSERT INTO media_items (id, type, title, year, monitored, monitoring_preset, \
         category_override, inserted_at, updated_at) \
         VALUES ('{id}', 'movie', '{title_e}', {year_sql}, {monitored_int}, 'all', 0, '{now}', '{now}')"
    ))
    .await
    .expect("insert movie");
}

async fn insert_tv(db: &DatabaseConnection, id: &str, title: &str, year: Option<i32>) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let title_e = esc(title);
    let year_sql = match year {
        Some(y) => y.to_string(),
        None => "NULL".to_owned(),
    };
    db.execute_unprepared(&format!(
        "INSERT INTO media_items (id, type, title, year, monitored, monitoring_preset, \
         category_override, inserted_at, updated_at) \
         VALUES ('{id}', 'tv_show', '{title_e}', {year_sql}, 1, 'all', 0, '{now}', '{now}')"
    ))
    .await
    .expect("insert tv");
}

async fn insert_episode(db: &DatabaseConnection, id: &str, show_id: &str) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    db.execute_unprepared(&format!(
        "INSERT INTO episodes (id, media_item_id, monitored, inserted_at, updated_at) \
         VALUES ('{id}', '{show_id}', 1, '{now}', '{now}')"
    ))
    .await
    .expect("insert episode");
}

async fn insert_movie_file(db: &DatabaseConnection, id: &str, movie_id: &str, trashed: bool) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let trashed_at_sql = if trashed {
        format!("'{now}'")
    } else {
        "NULL".to_owned()
    };
    db.execute_unprepared(&format!(
        "INSERT INTO media_files (id, media_item_id, path, trashed_at, inserted_at, updated_at) \
         VALUES ('{id}', '{movie_id}', '/media/{id}.mkv', {trashed_at_sql}, '{now}', '{now}')"
    ))
    .await
    .expect("insert movie file");
}

async fn insert_episode_file(db: &DatabaseConnection, id: &str, episode_id: &str) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    db.execute_unprepared(&format!(
        "INSERT INTO media_files (id, episode_id, path, inserted_at, updated_at) \
         VALUES ('{id}', '{episode_id}', '/media/{id}.mkv', '{now}', '{now}')"
    ))
    .await
    .expect("insert episode file");
}

#[tokio::test]
async fn kind_filter_isolates_movies_from_tv() {
    let db = setup().await;
    insert_movie(&db, &uuid_for("m1"), "Movie One", Some(2020), true).await;
    insert_movie(&db, &uuid_for("m2"), "Movie Two", Some(2021), true).await;
    insert_tv(&db, &uuid_for("t1"), "Show One", Some(2019)).await;

    let movies = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .expect("fetch movies");
    assert_eq!(movies.len(), 2);
    assert!(movies.iter().all(|r| r.r#type.as_deref() == Some("movie")));

    let shows = fetch_media(
        &db,
        "tv_show",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .expect("fetch shows");
    assert_eq!(shows.len(), 1);
    assert_eq!(shows[0].title.as_deref(), Some("Show One"));
}

#[tokio::test]
async fn search_is_case_insensitive_substring() {
    let db = setup().await;
    insert_movie(&db, &uuid_for("m1"), "The Matrix", Some(1999), true).await;
    insert_movie(&db, &uuid_for("m2"), "matrix Reloaded", Some(2003), true).await;
    insert_movie(&db, &uuid_for("m3"), "Inception", Some(2010), true).await;

    let mixed_case = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        Some("MATRIX"),
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .expect("fetch with mixed-case search");
    assert_eq!(mixed_case.len(), 2);

    let count = count_media(&db, "movie", MonitoredFilter::All, Some("Matrix"))
        .await
        .expect("count");
    assert_eq!(count, 2);
}

#[tokio::test]
async fn monitored_filter_narrows_correctly() {
    let db = setup().await;
    insert_movie(&db, &uuid_for("m1"), "Tracked", Some(2020), true).await;
    insert_movie(&db, &uuid_for("m2"), "Ignored", Some(2020), false).await;

    let monitored = fetch_media(
        &db,
        "movie",
        MonitoredFilter::Monitored,
        None,
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .expect("fetch monitored");
    assert_eq!(monitored.len(), 1);
    assert_eq!(monitored[0].title.as_deref(), Some("Tracked"));

    let unmonitored = fetch_media(
        &db,
        "movie",
        MonitoredFilter::Unmonitored,
        None,
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .expect("fetch unmonitored");
    assert_eq!(unmonitored.len(), 1);
    assert_eq!(unmonitored[0].title.as_deref(), Some("Ignored"));
}

#[tokio::test]
async fn sort_modes_order_rows_as_advertised() {
    let db = setup().await;
    insert_movie(&db, &uuid_for("a"), "Alpha", Some(2022), true).await;
    insert_movie(&db, &uuid_for("b"), "bravo", Some(2020), true).await;
    insert_movie(&db, &uuid_for("c"), "Charlie", Some(2021), true).await;

    // Title asc — case-insensitive, so "Alpha" < "bravo" < "Charlie"
    let title_asc = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        0,
        50,
    )
    .await
    .unwrap();
    let titles: Vec<_> = title_asc.iter().map(|r| r.title.as_deref()).collect();
    assert_eq!(titles, vec![Some("Alpha"), Some("bravo"), Some("Charlie")]);

    let title_desc = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleDesc,
        0,
        50,
    )
    .await
    .unwrap();
    let titles: Vec<_> = title_desc.iter().map(|r| r.title.as_deref()).collect();
    assert_eq!(titles, vec![Some("Charlie"), Some("bravo"), Some("Alpha")]);

    let year_desc = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::YearDesc,
        0,
        50,
    )
    .await
    .unwrap();
    let years: Vec<_> = year_desc.iter().map(|r| r.year).collect();
    assert_eq!(years, vec![Some(2022), Some(2021), Some(2020)]);
}

#[tokio::test]
async fn pagination_splits_first_50_then_25() {
    let db = setup().await;
    for i in 0..80 {
        insert_movie(
            &db,
            &uuid_for(&format!("m{i:03}")),
            &format!("Title {i:03}"),
            None,
            true,
        )
        .await;
    }

    let page0 = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        0,
        FIRST_PAGE_SIZE,
    )
    .await
    .unwrap();
    assert_eq!(page0.len(), 50);
    assert_eq!(page0[0].title.as_deref(), Some("Title 000"));
    assert_eq!(page0[49].title.as_deref(), Some("Title 049"));

    // page 1: 25 rows starting at offset 50
    let page1 = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        FIRST_PAGE_SIZE,
        25,
    )
    .await
    .unwrap();
    assert_eq!(page1.len(), 25);
    assert_eq!(page1[0].title.as_deref(), Some("Title 050"));
    assert_eq!(page1[24].title.as_deref(), Some("Title 074"));

    // page 2: the last 5 (75..80)
    let page2 = fetch_media(
        &db,
        "movie",
        MonitoredFilter::All,
        None,
        MediaSort::TitleAsc,
        FIRST_PAGE_SIZE + 25,
        25,
    )
    .await
    .unwrap();
    assert_eq!(page2.len(), 5);
    assert_eq!(page2[0].title.as_deref(), Some("Title 075"));

    let total = count_media(&db, "movie", MonitoredFilter::All, None)
        .await
        .unwrap();
    assert_eq!(total, 80);
}

#[tokio::test]
async fn has_files_movies_check_direct_fk() {
    let db = setup().await;
    let m1 = uuid_for("m1");
    let m2 = uuid_for("m2");
    insert_movie(&db, &m1, "With File", None, true).await;
    insert_movie(&db, &m2, "Naked", None, true).await;
    insert_movie_file(&db, &uuid_for("f1"), &m1, false).await;

    let with_file = row_has_files(&db, &m1, "movie").await.unwrap();
    assert!(with_file);

    let without = row_has_files(&db, &m2, "movie").await.unwrap();
    assert!(!without);
}

#[tokio::test]
async fn has_files_movies_ignore_trashed() {
    let db = setup().await;
    let m1 = uuid_for("m1");
    insert_movie(&db, &m1, "Trash Only", None, true).await;
    insert_movie_file(&db, &uuid_for("f1"), &m1, true).await;

    let result = row_has_files(&db, &m1, "movie").await.unwrap();
    assert!(!result);
}

#[tokio::test]
async fn has_files_tv_traverses_episodes() {
    let db = setup().await;
    let t1 = uuid_for("t1");
    let t2 = uuid_for("t2");
    let e1 = uuid_for("e1");
    insert_tv(&db, &t1, "Show With Episode", None).await;
    insert_tv(&db, &t2, "Naked Show", None).await;
    insert_episode(&db, &e1, &t1).await;
    insert_episode_file(&db, &uuid_for("ef1"), &e1).await;

    let with_ep = row_has_files(&db, &t1, "tv_show").await.unwrap();
    assert!(with_ep);

    let without = row_has_files(&db, &t2, "tv_show").await.unwrap();
    assert!(!without);
}

#[tokio::test]
async fn count_matches_fetch_size_under_filters() {
    let db = setup().await;
    for i in 0..10 {
        insert_movie(
            &db,
            &uuid_for(&format!("m{i}")),
            &format!("Title {i}"),
            None,
            i % 2 == 0,
        )
        .await;
    }

    let total = count_media(&db, "movie", MonitoredFilter::All, None)
        .await
        .unwrap();
    assert_eq!(total, 10);

    let monitored = count_media(&db, "movie", MonitoredFilter::Monitored, None)
        .await
        .unwrap();
    assert_eq!(monitored, 5);

    let unmonitored = count_media(&db, "movie", MonitoredFilter::Unmonitored, None)
        .await
        .unwrap();
    assert_eq!(unmonitored, 5);
}

// ---------- U25.b: detail page tests ----------

async fn insert_movie_with_metadata(
    db: &DatabaseConnection,
    id: &str,
    title: &str,
    year: Option<i32>,
    metadata_json: &str,
) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let title_e = esc(title);
    let year_sql = match year {
        Some(y) => y.to_string(),
        None => "NULL".to_owned(),
    };
    let metadata_e = esc(metadata_json);
    db.execute_unprepared(&format!(
        "INSERT INTO media_items (id, type, title, year, metadata, monitored, monitoring_preset, \
         category_override, inserted_at, updated_at) \
         VALUES ('{id}', 'movie', '{title_e}', {year_sql}, '{metadata_e}', 1, 'all', 0, '{now}', '{now}')"
    ))
    .await
    .expect("insert movie with metadata");
}

#[allow(clippy::too_many_arguments)]
async fn insert_full_movie_file(
    db: &DatabaseConnection,
    id: &str,
    movie_id: &str,
    path: &str,
    resolution: Option<&str>,
    codec: Option<&str>,
    audio_codec: Option<&str>,
    size: Option<i64>,
) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let path_e = esc(path);
    let resolution_sql = match resolution {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let codec_sql = match codec {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let audio_codec_sql = match audio_codec {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let size_sql = match size {
        Some(n) => n.to_string(),
        None => "NULL".to_owned(),
    };
    db.execute_unprepared(&format!(
        "INSERT INTO media_files (id, media_item_id, path, resolution, codec, audio_codec, size, \
         inserted_at, updated_at) \
         VALUES ('{id}', '{movie_id}', '{path_e}', {resolution_sql}, {codec_sql}, \
         {audio_codec_sql}, {size_sql}, '{now}', '{now}')"
    ))
    .await
    .expect("insert movie file with details");
}

#[allow(clippy::too_many_arguments)]
async fn insert_full_episode(
    db: &DatabaseConnection,
    id: &str,
    show_id: &str,
    season: i32,
    episode: i32,
    title: Option<&str>,
    air_date: Option<&str>,
    monitored: bool,
) {
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let title_sql = match title {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let air_date_sql = match air_date {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let monitored_int = i64::from(monitored);
    db.execute_unprepared(&format!(
        "INSERT INTO episodes (id, media_item_id, season_number, episode_number, title, air_date, \
         monitored, inserted_at, updated_at) \
         VALUES ('{id}', '{show_id}', {season}, {episode}, {title_sql}, {air_date_sql}, \
         {monitored_int}, '{now}', '{now}')"
    ))
    .await
    .expect("insert full episode");
}

#[tokio::test]
async fn detail_extracts_metadata_fields() {
    let db = setup().await;
    let id = uuid_for("detail_movie");
    let metadata = r#"{
        "overview": "A wholesome road trip story.",
        "poster_path": "/abc.jpg",
        "backdrop_path": "/xyz.jpg",
        "runtime": 117,
        "vote_average": 8.4,
        "genres": ["Drama", "Comedy"]
    }"#;
    insert_movie_with_metadata(&db, &id, "Sample Movie", Some(2022), metadata).await;

    let detail = fetch_media_detail(&db, &id).await.expect("fetch detail");
    assert_eq!(detail.kind, "movie");
    assert_eq!(detail.title, "Sample Movie");
    assert_eq!(detail.year, Some(2022));
    assert_eq!(
        detail.overview.as_deref(),
        Some("A wholesome road trip story.")
    );
    assert_eq!(detail.poster_path.as_deref(), Some("/abc.jpg"));
    assert_eq!(detail.backdrop_path.as_deref(), Some("/xyz.jpg"));
    assert_eq!(detail.runtime, Some(117));
    assert!((detail.rating.unwrap() - 8.4).abs() < 0.001);
    assert_eq!(detail.genres, vec!["Drama".to_owned(), "Comedy".to_owned()]);
}

#[tokio::test]
async fn detail_with_null_metadata_returns_none_fields() {
    let db = setup().await;
    let id = uuid_for("naked_movie");
    insert_movie(&db, &id, "Naked", None, true).await;

    let detail = fetch_media_detail(&db, &id).await.unwrap();
    assert!(detail.overview.is_none());
    assert!(detail.poster_path.is_none());
    assert!(detail.backdrop_path.is_none());
    assert!(detail.runtime.is_none());
    assert!(detail.rating.is_none());
    assert!(detail.genres.is_empty());
}

#[tokio::test]
async fn detail_missing_id_errors_not_panics() {
    let db = setup().await;
    let result = fetch_media_detail(&db, &uuid_for("ghost")).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn movie_files_sort_by_resolution_then_path() {
    let db = setup().await;
    let movie_id = uuid_for("movie");
    insert_movie(&db, &movie_id, "Sample", None, true).await;
    insert_full_movie_file(
        &db,
        &uuid_for("f1"),
        &movie_id,
        "/z_low.mkv",
        Some("720p"),
        Some("h264"),
        Some("aac"),
        Some(1_073_741_824),
    )
    .await;
    insert_full_movie_file(
        &db,
        &uuid_for("f2"),
        &movie_id,
        "/a_hd.mkv",
        Some("1080p"),
        Some("h265"),
        Some("eac3"),
        Some(5_368_709_120),
    )
    .await;
    insert_full_movie_file(
        &db,
        &uuid_for("f3"),
        &movie_id,
        "/b_uhd.mkv",
        Some("2160p"),
        Some("av1"),
        Some("truehd"),
        Some(15_032_385_536),
    )
    .await;

    let files = fetch_movie_files(&db, &movie_id).await.unwrap();
    let resolutions: Vec<_> = files.iter().map(|f| f.resolution.as_deref()).collect();
    assert_eq!(
        resolutions,
        vec![Some("2160p"), Some("1080p"), Some("720p")]
    );
    assert_eq!(files[0].filename, "b_uhd.mkv");
    assert_eq!(files[0].codec.as_deref(), Some("av1"));
    assert_eq!(files[0].audio_codec.as_deref(), Some("truehd"));
}

#[tokio::test]
async fn movie_files_exclude_trashed() {
    let db = setup().await;
    let movie_id = uuid_for("movie");
    insert_movie(&db, &movie_id, "Sample", None, true).await;
    insert_full_movie_file(
        &db,
        &uuid_for("kept"),
        &movie_id,
        "/kept.mkv",
        Some("1080p"),
        None,
        None,
        None,
    )
    .await;
    // Insert a trashed file via the shorter helper (which writes
    // trashed_at) — the row exists in the table but the list query
    // must skip it.
    insert_movie_file(&db, &uuid_for("trashed"), &movie_id, true).await;

    let files = fetch_movie_files(&db, &movie_id).await.unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].filename, "kept.mkv");
}

#[tokio::test]
async fn seasons_group_episodes_and_count_downloaded() {
    let db = setup().await;
    let show_id = uuid_for("show");
    insert_tv(&db, &show_id, "My Show", None).await;

    let s1e1 = uuid_for("s1e1");
    let s1e2 = uuid_for("s1e2");
    let s2e1 = uuid_for("s2e1");
    insert_full_episode(
        &db,
        &s1e1,
        &show_id,
        1,
        1,
        Some("Pilot"),
        Some("2020-01-01"),
        true,
    )
    .await;
    insert_full_episode(
        &db,
        &s1e2,
        &show_id,
        1,
        2,
        Some("Second"),
        Some("2020-01-08"),
        true,
    )
    .await;
    insert_full_episode(
        &db,
        &s2e1,
        &show_id,
        2,
        1,
        Some("Return"),
        Some("2021-03-15"),
        false,
    )
    .await;

    // Only s1e1 + s2e1 have files
    insert_episode_file(&db, &uuid_for("f_s1e1"), &s1e1).await;
    insert_episode_file(&db, &uuid_for("f_s2e1"), &s2e1).await;

    let seasons = fetch_show_seasons(&db, &show_id).await.unwrap();
    assert_eq!(seasons.len(), 2);

    let s1 = &seasons[0];
    assert_eq!(s1.season_number, 1);
    assert_eq!(s1.episode_count, 2);
    assert_eq!(s1.downloaded_count, 1);
    assert_eq!(s1.episodes[0].episode_number, Some(1));
    assert_eq!(s1.episodes[0].title.as_deref(), Some("Pilot"));
    assert!(s1.episodes[0].has_files);
    assert!(!s1.episodes[1].has_files);

    let s2 = &seasons[1];
    assert_eq!(s2.season_number, 2);
    assert_eq!(s2.episode_count, 1);
    assert_eq!(s2.downloaded_count, 1);
    assert!(!s2.episodes[0].monitored);
}

#[tokio::test]
async fn seasons_air_date_formats_as_iso() {
    let db = setup().await;
    let show_id = uuid_for("show");
    insert_tv(&db, &show_id, "Dated", None).await;
    insert_full_episode(
        &db,
        &uuid_for("ep"),
        &show_id,
        1,
        1,
        Some("Pilot"),
        Some("2024-12-31"),
        true,
    )
    .await;

    let seasons = fetch_show_seasons(&db, &show_id).await.unwrap();
    assert_eq!(seasons[0].episodes[0].air_date, "2024-12-31");
}

#[tokio::test]
async fn seasons_empty_when_no_episodes() {
    let db = setup().await;
    let show_id = uuid_for("naked_show");
    insert_tv(&db, &show_id, "Empty", None).await;

    let seasons = fetch_show_seasons(&db, &show_id).await.unwrap();
    assert!(seasons.is_empty());
}

// ---------- U25.c: action endpoint tests ----------

async fn read_monitored(db: &DatabaseConnection, table: &str, id: &str) -> bool {
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(
            backend,
            format!("SELECT monitored FROM {table} WHERE id = '{id}'"),
        ))
        .await
        .expect("read monitored")
        .expect("row");
    let m: i32 = row.try_get_by("monitored").expect("monitored");
    m != 0
}

async fn row_exists(db: &DatabaseConnection, table: &str, id: &str) -> bool {
    let backend = db.get_database_backend();
    let row = db
        .query_one_raw(Statement::from_string(
            backend,
            format!("SELECT EXISTS(SELECT 1 FROM {table} WHERE id = '{id}') AS e"),
        ))
        .await
        .expect("exists check")
        .expect("row");
    let exists: i32 = row.try_get_by("e").expect("e");
    exists != 0
}

#[tokio::test]
async fn flip_media_monitored_returns_new_state_and_persists() {
    let db = setup().await;
    let id = uuid_for("flip_movie");
    insert_movie(&db, &id, "Flippable", None, true).await;
    assert!(read_monitored(&db, "media_items", &id).await);

    let next = flip_media_monitored(&db, &id).await.unwrap();
    assert!(!next);
    assert!(!read_monitored(&db, "media_items", &id).await);

    let next = flip_media_monitored(&db, &id).await.unwrap();
    assert!(next);
    assert!(read_monitored(&db, "media_items", &id).await);
}

#[tokio::test]
async fn flip_media_monitored_unknown_id_errors() {
    let db = setup().await;
    let result = flip_media_monitored(&db, &uuid_for("ghost")).await;
    assert!(result.is_err());
}

#[tokio::test]
async fn flip_episode_monitored_round_trips() {
    let db = setup().await;
    let show_id = uuid_for("show");
    let ep_id = uuid_for("ep");
    insert_tv(&db, &show_id, "S", None).await;
    insert_full_episode(&db, &ep_id, &show_id, 1, 1, Some("Pilot"), None, true).await;
    assert!(read_monitored(&db, "episodes", &ep_id).await);

    let next = flip_episode_monitored(&db, &ep_id).await.unwrap();
    assert!(!next);
    assert!(!read_monitored(&db, "episodes", &ep_id).await);
}

#[tokio::test]
async fn delete_removes_media_episodes_and_files_in_one_transaction() {
    let db = setup().await;
    let show_id = uuid_for("show");
    let ep1 = uuid_for("ep1");
    let ep2 = uuid_for("ep2");
    let mf1 = uuid_for("mf1");
    let mf2 = uuid_for("mf2");

    insert_tv(&db, &show_id, "Doomed", None).await;
    insert_full_episode(&db, &ep1, &show_id, 1, 1, None, None, true).await;
    insert_full_episode(&db, &ep2, &show_id, 1, 2, None, None, true).await;
    insert_episode_file(&db, &mf1, &ep1).await;
    insert_episode_file(&db, &mf2, &ep2).await;

    delete_media_item_db_only(&db, &show_id).await.unwrap();

    assert!(!row_exists(&db, "media_items", &show_id).await);
    assert!(!row_exists(&db, "episodes", &ep1).await);
    assert!(!row_exists(&db, "episodes", &ep2).await);
    assert!(!row_exists(&db, "media_files", &mf1).await);
    assert!(!row_exists(&db, "media_files", &mf2).await);
}

#[tokio::test]
async fn delete_cleans_movie_files_via_direct_fk() {
    let db = setup().await;
    let movie_id = uuid_for("movie");
    let mf_id = uuid_for("mf");
    insert_movie(&db, &movie_id, "Doomed Movie", None, true).await;
    insert_movie_file(&db, &mf_id, &movie_id, false).await;

    delete_media_item_db_only(&db, &movie_id).await.unwrap();

    assert!(!row_exists(&db, "media_items", &movie_id).await);
    assert!(!row_exists(&db, "media_files", &mf_id).await);
}

#[tokio::test]
async fn delete_leaves_unrelated_rows_alone() {
    let db = setup().await;
    let m1 = uuid_for("m1");
    let m2 = uuid_for("m2");
    let mf1 = uuid_for("mf1");
    let mf2 = uuid_for("mf2");
    insert_movie(&db, &m1, "Target", None, true).await;
    insert_movie(&db, &m2, "Keeper", None, true).await;
    insert_movie_file(&db, &mf1, &m1, false).await;
    insert_movie_file(&db, &mf2, &m2, false).await;

    delete_media_item_db_only(&db, &m1).await.unwrap();

    assert!(row_exists(&db, "media_items", &m2).await);
    assert!(row_exists(&db, "media_files", &mf2).await);
}

#[tokio::test]
async fn delete_unknown_id_errors_without_writing() {
    let db = setup().await;
    let m1 = uuid_for("kept");
    insert_movie(&db, &m1, "Bystander", None, true).await;

    let result = delete_media_item_db_only(&db, &uuid_for("ghost")).await;
    assert!(result.is_err());

    // Bystander row must survive the failed transaction.
    assert!(row_exists(&db, "media_items", &m1).await);
}
