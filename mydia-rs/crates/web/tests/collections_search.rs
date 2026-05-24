//! Integration tests for the U26 collections + search server fns.
//!
//! Mirrors `media_list.rs` / `user_pages.rs` in shape — drives the
//! server-fn SQL helpers against a real in-memory `SQLite` pool with a
//! hand-rolled schema covering only the columns the queries touch.
//! Coverage:
//!
//!   - collections list: returns own + shared, hides private from
//!     other users, search narrows by name, kind filter narrows by
//!     type, empty result renders cleanly.
//!   - collections detail: returns the row when accessible, errors
//!     when the user can't see it.
//!   - collection members: walks the join in position order for manual
//!     collections, returns an empty list for smart collections.
//!   - search: returns nothing for queries shorter than two chars,
//!     ranks exact > prefix > substring, never returns music / books
//!     / adult rows even when one exists in the table.

#![cfg(feature = "server")]

mod common;

use chrono::Utc;
use common::{apply_sql, fresh_db};
use mydia_rs_db::DatabaseConnection;
use sea_orm::ConnectionTrait;
use mydia_rs_web::server_fns::collections::server::{
    fetch_collection_detail, fetch_collection_items, fetch_collections,
};
use mydia_rs_web::server_fns::collections::CollectionListQuery;
use mydia_rs_web::server_fns::search::server::execute_search;

const SETUP_SQL: &str = "
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    role TEXT NOT NULL DEFAULT 'user',
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_items (
    id TEXT PRIMARY KEY,
    type TEXT NOT NULL,
    title TEXT NOT NULL,
    original_title TEXT,
    year INTEGER,
    tmdb_id INTEGER,
    tvdb_id INTEGER,
    imdb_id TEXT,
    metadata TEXT,
    monitored INTEGER DEFAULT 1,
    monitoring_preset TEXT,
    category TEXT,
    category_override INTEGER NOT NULL DEFAULT 0,
    seasons_refreshed_at TEXT,
    quality_profile_id TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS collections (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    type TEXT NOT NULL DEFAULT 'manual',
    poster_path TEXT,
    sort_order TEXT NOT NULL DEFAULT 'position',
    smart_rules TEXT,
    visibility TEXT NOT NULL DEFAULT 'private',
    is_system INTEGER NOT NULL DEFAULT 0,
    position INTEGER NOT NULL DEFAULT 0,
    user_id TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS collection_items (
    id TEXT PRIMARY KEY,
    collection_id TEXT NOT NULL,
    media_item_id TEXT NOT NULL,
    position INTEGER NOT NULL DEFAULT 0,
    inserted_at TEXT NOT NULL
);
";

async fn fixture() -> DatabaseConnection {
    let db = fresh_db().await;
    apply_sql(&db, SETUP_SQL).await;
    db
}

/// Escape a string for inlining inside single-quoted SQL string
/// literal. Test inputs are controlled but a couple of fixture names
/// contain apostrophes (`Bob's …`); doubling the quote is the
/// standard-SQL escape that `SQLite` + Postgres both accept.
fn esc(s: &str) -> String {
    s.replace('\'', "''")
}

async fn insert_user(db: &DatabaseConnection) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    db.execute_unprepared(&format!(
        "INSERT INTO users (id, role, inserted_at, updated_at) VALUES ('{id}', 'user', '{now}', '{now}')"
    ))
    .await
    .expect("insert user");
    id
}

#[allow(clippy::too_many_arguments)]
async fn insert_collection(
    db: &DatabaseConnection,
    user_id: &str,
    name: &str,
    kind: &str,
    visibility: &str,
    is_system: bool,
    position: i64,
) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let is_system_int = i64::from(is_system);
    let name_e = esc(name);
    db.execute_unprepared(&format!(
        "INSERT INTO collections (id, name, type, visibility, is_system, position, user_id, \
         sort_order, inserted_at, updated_at) \
         VALUES ('{id}', '{name_e}', '{kind}', '{visibility}', {is_system_int}, {position}, \
         '{user_id}', 'position', '{now}', '{now}')"
    ))
    .await
    .expect("insert collection");
    id
}

async fn insert_media(
    db: &DatabaseConnection,
    kind: &str,
    title: &str,
    year: Option<i32>,
) -> String {
    insert_media_with_metadata(db, kind, title, None, year, None).await
}

async fn insert_media_with_metadata(
    db: &DatabaseConnection,
    kind: &str,
    title: &str,
    original_title: Option<&str>,
    year: Option<i32>,
    metadata_json: Option<&str>,
) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let title_e = esc(title);
    let original_title_sql = match original_title {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    let year_sql = match year {
        Some(y) => y.to_string(),
        None => "NULL".to_owned(),
    };
    let metadata_sql = match metadata_json {
        Some(s) => format!("'{}'", esc(s)),
        None => "NULL".to_owned(),
    };
    db.execute_unprepared(&format!(
        "INSERT INTO media_items (id, type, title, original_title, year, metadata, monitored, \
         inserted_at, updated_at) VALUES ('{id}', '{kind}', '{title_e}', {original_title_sql}, \
         {year_sql}, {metadata_sql}, 1, '{now}', '{now}')"
    ))
    .await
    .expect("insert media");
    id
}

async fn add_to_collection(
    db: &DatabaseConnection,
    collection_id: &str,
    media_id: &str,
    position: i64,
) {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    db.execute_unprepared(&format!(
        "INSERT INTO collection_items (id, collection_id, media_item_id, position, inserted_at) \
         VALUES ('{id}', '{collection_id}', '{media_id}', {position}, '{now}')"
    ))
    .await
    .expect("insert collection_item");
}

// ---------- collections list ----------

#[tokio::test]
async fn list_returns_own_and_shared_collections() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let bob = insert_user(&db).await;

    // Alice owns one private + one shared.
    let alice_private =
        insert_collection(&db, &alice, "Alice Private", "manual", "private", false, 0).await;
    let alice_shared =
        insert_collection(&db, &alice, "Alice Shared", "manual", "shared", false, 0).await;
    // Bob owns one private (not visible to Alice) + one shared.
    let _bob_private =
        insert_collection(&db, &bob, "Bob Private", "manual", "private", false, 0).await;
    let bob_shared = insert_collection(&db, &bob, "Bob Shared", "manual", "shared", false, 0).await;

    let q = CollectionListQuery::default();
    let rows = fetch_collections(&db, &alice, &q).await.expect("list");
    let ids: Vec<_> = rows.iter().map(|r| r.id.as_str()).collect();
    assert!(ids.contains(&alice_private.as_str()));
    assert!(ids.contains(&alice_shared.as_str()));
    assert!(ids.contains(&bob_shared.as_str()));
    // Bob's private must NOT appear in Alice's list.
    assert_eq!(rows.len(), 3, "Alice sees own + shared");

    // Owned flag is set correctly.
    let alice_row = rows
        .iter()
        .find(|r| r.id == alice_private)
        .expect("alice's own row");
    assert!(alice_row.owned);
    let bob_row = rows
        .iter()
        .find(|r| r.id == bob_shared)
        .expect("bob's shared row");
    assert!(!bob_row.owned);
}

#[tokio::test]
async fn list_returns_empty_when_no_collections_exist() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let rows = fetch_collections(&db, &alice, &CollectionListQuery::default())
        .await
        .expect("list");
    assert!(rows.is_empty());
}

#[tokio::test]
async fn list_search_narrows_by_name() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    insert_collection(&db, &alice, "Favorites", "manual", "private", false, 0).await;
    insert_collection(&db, &alice, "Action Movies", "manual", "private", false, 0).await;
    insert_collection(&db, &alice, "Cartoons", "manual", "private", false, 0).await;

    let q = CollectionListQuery {
        search: "ACTION".to_owned(),
        ..Default::default()
    };
    let rows = fetch_collections(&db, &alice, &q).await.expect("list");
    assert_eq!(rows.len(), 1, "case-insensitive substring match");
    assert_eq!(rows[0].name, "Action Movies");
}

#[tokio::test]
async fn list_kind_filter_narrows_by_type() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    insert_collection(&db, &alice, "Manual A", "manual", "private", false, 0).await;
    insert_collection(&db, &alice, "Smart A", "smart", "private", false, 0).await;
    insert_collection(&db, &alice, "Manual B", "manual", "private", false, 0).await;

    let q = CollectionListQuery {
        kind: Some("smart".to_owned()),
        ..Default::default()
    };
    let rows = fetch_collections(&db, &alice, &q).await.expect("list");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].name, "Smart A");
    assert_eq!(rows[0].kind, "smart");
}

#[tokio::test]
async fn list_invalid_kind_filter_is_treated_as_no_filter() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    insert_collection(&db, &alice, "M", "manual", "private", false, 0).await;
    insert_collection(&db, &alice, "S", "smart", "private", false, 0).await;

    let q = CollectionListQuery {
        kind: Some("bogus".to_owned()),
        ..Default::default()
    };
    let rows = fetch_collections(&db, &alice, &q).await.expect("list");
    assert_eq!(rows.len(), 2, "unknown kind falls through to no filter");
}

#[tokio::test]
async fn list_item_count_reflects_collection_items_for_manual_only() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let manual = insert_collection(&db, &alice, "M", "manual", "private", false, 0).await;
    let smart = insert_collection(&db, &alice, "S", "smart", "private", false, 0).await;
    let m1 = insert_media(&db, "movie", "One", Some(2020)).await;
    let m2 = insert_media(&db, "movie", "Two", Some(2021)).await;
    add_to_collection(&db, &manual, &m1, 0).await;
    add_to_collection(&db, &manual, &m2, 1).await;

    let q = CollectionListQuery::default();
    let rows = fetch_collections(&db, &alice, &q).await.expect("list");
    let manual_row = rows.iter().find(|r| r.id == manual).unwrap();
    let smart_row = rows.iter().find(|r| r.id == smart).unwrap();
    assert_eq!(manual_row.item_count, 2);
    assert_eq!(smart_row.item_count, 0, "smart count is a placeholder");
}

#[tokio::test]
async fn list_poster_paths_pulls_first_four_from_member_metadata() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let c = insert_collection(&db, &alice, "Mixed", "manual", "private", false, 0).await;
    let with_poster_one = serde_json::json!({"poster_path": "/a.jpg"}).to_string();
    let with_poster_two = serde_json::json!({"poster_path": "/b.jpg"}).to_string();
    let m1 = insert_media_with_metadata(
        &db,
        "movie",
        "One",
        None,
        None,
        Some(with_poster_one.as_str()),
    )
    .await;
    let m2 = insert_media_with_metadata(
        &db,
        "movie",
        "Two",
        None,
        None,
        Some(with_poster_two.as_str()),
    )
    .await;
    let m3 = insert_media(&db, "movie", "No Poster", None).await;
    add_to_collection(&db, &c, &m1, 0).await;
    add_to_collection(&db, &c, &m2, 1).await;
    add_to_collection(&db, &c, &m3, 2).await;

    let rows = fetch_collections(&db, &alice, &CollectionListQuery::default())
        .await
        .unwrap();
    let row = rows.iter().find(|r| r.id == c).unwrap();
    assert_eq!(
        row.poster_paths,
        vec!["/a.jpg".to_owned(), "/b.jpg".to_owned()],
        "skips members without poster_path; keeps order"
    );
}

// ---------- collections detail ----------

#[tokio::test]
async fn detail_returns_row_when_accessible() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let id = insert_collection(&db, &alice, "Owned", "manual", "private", false, 0).await;

    let detail = fetch_collection_detail(&db, &alice, &id)
        .await
        .expect("detail");
    assert_eq!(detail.name, "Owned");
    assert_eq!(detail.kind, "manual");
    assert!(detail.owned);
}

#[tokio::test]
async fn detail_errors_when_collection_is_private_to_another_user() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let bob = insert_user(&db).await;
    let id = insert_collection(&db, &bob, "Bob's Private", "manual", "private", false, 0).await;

    let err = fetch_collection_detail(&db, &alice, &id)
        .await
        .expect_err("not accessible");
    let msg = err.to_string();
    assert!(msg.contains("not found") || msg.contains("Not found") || msg.contains("Collection"));
}

#[tokio::test]
async fn detail_returns_shared_row_for_non_owner() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let bob = insert_user(&db).await;
    let id = insert_collection(&db, &bob, "Bob's Shared", "manual", "shared", false, 0).await;

    let detail = fetch_collection_detail(&db, &alice, &id)
        .await
        .expect("shared collection visible");
    assert_eq!(detail.name, "Bob's Shared");
    assert!(!detail.owned, "Alice doesn't own this row");
}

// ---------- collection members ----------

#[tokio::test]
async fn members_returns_join_rows_in_position_order() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let c = insert_collection(&db, &alice, "C", "manual", "private", false, 0).await;
    let m1 = insert_media(&db, "movie", "First", Some(2020)).await;
    let m2 = insert_media(&db, "tv_show", "Second", Some(2021)).await;
    let m3 = insert_media(&db, "movie", "Third", Some(2022)).await;
    // Insert out of order; the query orders by position.
    add_to_collection(&db, &c, &m3, 2).await;
    add_to_collection(&db, &c, &m1, 0).await;
    add_to_collection(&db, &c, &m2, 1).await;

    let members = fetch_collection_items(&db, &alice, &c)
        .await
        .expect("members");
    let titles: Vec<_> = members.iter().map(|m| m.title.as_str()).collect();
    assert_eq!(titles, vec!["First", "Second", "Third"]);
    assert_eq!(members[0].kind, "movie");
    assert_eq!(members[1].kind, "tv_show");
}

#[tokio::test]
async fn members_returns_empty_for_smart_collection() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let smart = insert_collection(&db, &alice, "Smart", "smart", "private", false, 0).await;

    let members = fetch_collection_items(&db, &alice, &smart)
        .await
        .expect("smart members");
    assert!(members.is_empty(), "engine not ported");
}

#[tokio::test]
async fn members_extracts_poster_path_from_metadata_json() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let c = insert_collection(&db, &alice, "C", "manual", "private", false, 0).await;
    let metadata = serde_json::json!({"poster_path": "/poster.jpg"}).to_string();
    let m1 =
        insert_media_with_metadata(&db, "movie", "One", None, Some(2020), Some(&metadata)).await;
    add_to_collection(&db, &c, &m1, 0).await;

    let members = fetch_collection_items(&db, &alice, &c).await.unwrap();
    assert_eq!(members[0].poster_path.as_deref(), Some("/poster.jpg"));
}

#[tokio::test]
async fn members_errors_for_inaccessible_collection() {
    let db = fixture().await;
    let alice = insert_user(&db).await;
    let bob = insert_user(&db).await;
    let id = insert_collection(&db, &bob, "Bob's", "manual", "private", false, 0).await;

    let err = fetch_collection_items(&db, &alice, &id)
        .await
        .expect_err("denied");
    let msg = err.to_string();
    assert!(msg.contains("not found") || msg.contains("Not found") || msg.contains("Collection"));
}

// ---------- search ----------

#[tokio::test]
async fn search_returns_empty_for_short_queries() {
    let db = fixture().await;
    insert_media(&db, "movie", "Matrix", Some(1999)).await;

    let rows = execute_search(&db, "").await.expect("empty query");
    assert!(rows.is_empty());
    let rows = execute_search(&db, "m").await.expect("one char");
    assert!(rows.is_empty(), "single-char queries gated server-side");
}

#[tokio::test]
async fn search_returns_nothing_for_unmatched_term() {
    let db = fixture().await;
    insert_media(&db, "movie", "Matrix", Some(1999)).await;

    let rows = execute_search(&db, "zoinks").await.expect("no match");
    assert!(rows.is_empty());
}

#[tokio::test]
async fn search_ranks_exact_above_prefix_above_substring() {
    let db = fixture().await;
    // Three rows that all match the substring `matrix` but should rank
    // in a specific order: exact > prefix > substring.
    let _exact = insert_media(&db, "movie", "Matrix", Some(2010)).await;
    let _prefix = insert_media(&db, "movie", "Matrix Reloaded", Some(2003)).await;
    let _substr = insert_media(&db, "tv_show", "Enter the Matrix Show", Some(2020)).await;

    let rows = execute_search(&db, "Matrix").await.expect("search");
    assert!(rows.len() >= 3);
    let titles: Vec<_> = rows.iter().take(3).map(|r| r.title.as_str()).collect();
    assert_eq!(titles[0], "Matrix", "exact match wins");
    assert_eq!(titles[1], "Matrix Reloaded", "prefix beats substring");
    assert_eq!(titles[2], "Enter the Matrix Show");
}

#[tokio::test]
async fn search_excludes_non_movie_tv_kinds() {
    let db = fixture().await;
    insert_media(&db, "movie", "Music Stuff", Some(2020)).await;
    insert_media(&db, "tv_show", "Music Stuff Show", Some(2021)).await;
    insert_media(&db, "music", "Music Album", Some(2022)).await;
    insert_media(&db, "book", "Music Book", Some(2023)).await;
    insert_media(&db, "adult", "Music X", Some(2024)).await;

    let rows = execute_search(&db, "music").await.expect("search");
    let kinds: std::collections::HashSet<_> = rows.iter().map(|r| r.kind.as_str()).collect();
    assert!(kinds.contains("movie"));
    assert!(kinds.contains("tv_show"));
    assert!(!kinds.contains("music"), "music excluded");
    assert!(!kinds.contains("book"), "book excluded");
    assert!(!kinds.contains("adult"), "adult excluded");
}

#[tokio::test]
async fn search_matches_original_title_too() {
    let db = fixture().await;
    insert_media_with_metadata(
        &db,
        "movie",
        "English Title",
        Some("Le Titre Français"),
        Some(2020),
        None,
    )
    .await;

    let rows = execute_search(&db, "français").await.expect("search");
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].title, "English Title");
}

#[tokio::test]
async fn search_subtitle_includes_year_and_kind() {
    let db = fixture().await;
    insert_media(&db, "movie", "Test Movie", Some(2020)).await;
    insert_media(&db, "tv_show", "Test Show", None).await;

    let rows = execute_search(&db, "test").await.unwrap();
    let movie = rows.iter().find(|r| r.kind == "movie").unwrap();
    let show = rows.iter().find(|r| r.kind == "tv_show").unwrap();
    assert_eq!(movie.subtitle, "2020 · Movie");
    assert_eq!(show.subtitle, "TV Show");
}

#[tokio::test]
async fn search_pulls_poster_path_from_metadata() {
    let db = fixture().await;
    let metadata = serde_json::json!({"poster_path": "/pp.jpg"}).to_string();
    insert_media_with_metadata(&db, "movie", "Posterful", None, Some(2020), Some(&metadata)).await;

    let rows = execute_search(&db, "Posterful").await.unwrap();
    assert_eq!(rows[0].poster_path.as_deref(), Some("/pp.jpg"));
}
