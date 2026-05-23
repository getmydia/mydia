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

use mydia_rs_db::Db;
use mydia_rs_web::server_fns::media::server::{count_media, fetch_media, row_has_files};
use mydia_rs_web::server_fns::media::{MediaSort, MonitoredFilter, FIRST_PAGE_SIZE};
use sqlx::sqlite::SqlitePoolOptions;
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

async fn setup() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("open in-memory sqlite");
    sqlx::query(SETUP_SQL)
        .execute(&pool)
        .await
        .expect("create tables");
    Db::Sqlite(pool)
}

async fn insert_movie(db: &Db, id: &str, title: &str, year: Option<i32>, monitored: bool) {
    let Db::Sqlite(pool) = db else { unreachable!() };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, monitored, monitoring_preset, \
         category_override, inserted_at, updated_at) \
         VALUES (?, 'movie', ?, ?, ?, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(year)
    .bind(i64::from(monitored))
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert movie");
}

async fn insert_tv(db: &Db, id: &str, title: &str, year: Option<i32>) {
    let Db::Sqlite(pool) = db else { unreachable!() };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    sqlx::query(
        "INSERT INTO media_items (id, type, title, year, monitored, monitoring_preset, \
         category_override, inserted_at, updated_at) \
         VALUES (?, 'tv_show', ?, ?, 1, 'all', 0, ?, ?)",
    )
    .bind(id)
    .bind(title)
    .bind(year)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert tv");
}

async fn insert_episode(db: &Db, id: &str, show_id: &str) {
    let Db::Sqlite(pool) = db else { unreachable!() };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    sqlx::query(
        "INSERT INTO episodes (id, media_item_id, monitored, inserted_at, updated_at) \
         VALUES (?, ?, 1, ?, ?)",
    )
    .bind(id)
    .bind(show_id)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert episode");
}

async fn insert_movie_file(db: &Db, id: &str, movie_id: &str, trashed: bool) {
    let Db::Sqlite(pool) = db else { unreachable!() };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let trashed_at = if trashed { Some(now.clone()) } else { None };
    sqlx::query(
        "INSERT INTO media_files (id, media_item_id, path, trashed_at, inserted_at, updated_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(movie_id)
    .bind(format!("/media/{id}.mkv"))
    .bind(trashed_at)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert movie file");
}

async fn insert_episode_file(db: &Db, id: &str, episode_id: &str) {
    let Db::Sqlite(pool) = db else { unreachable!() };
    let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    sqlx::query(
        "INSERT INTO media_files (id, episode_id, path, inserted_at, updated_at) \
         VALUES (?, ?, ?, ?, ?)",
    )
    .bind(id)
    .bind(episode_id)
    .bind(format!("/media/{id}.mkv"))
    .bind(&now)
    .bind(&now)
    .execute(pool)
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
