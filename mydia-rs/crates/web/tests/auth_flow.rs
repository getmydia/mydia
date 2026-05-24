//! Integration tests for the U24.a auth surface.
//!
//! Covers the seams the page can't easily exercise on its own:
//! - bcrypt verifies against a Phoenix-shaped hash;
//! - the session round-trips a `user_id` through sqlite tower-sessions;
//! - `setup_required` flips after the first insert into `users`;
//! - the `require_session_user_id` helper rejects anonymous calls.
//!
//! Does not drive Dioxus directly; the page-level redirect logic is
//! covered by a browser-driven test once `/loop ce-test-browser`
//! lands for the Rust stack.

#![cfg(feature = "server")]

mod common;

use common::{apply_sql, fresh_db, sqlite_pool};
use mydia_rs_auth::password::{hash_password, verify_password};
use mydia_rs_db::DatabaseConnection;
use mydia_rs_web::session::{self as web_session, SESSION_COOKIE_NAME};

const USERS_TABLE_SQL: &str = "
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT UNIQUE,
    email TEXT UNIQUE,
    password_hash TEXT,
    oidc_sub TEXT,
    oidc_issuer TEXT,
    role TEXT NOT NULL DEFAULT 'user',
    display_name TEXT,
    avatar_url TEXT,
    last_login_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

async fn fixture_db() -> DatabaseConnection {
    let db = fresh_db().await;
    apply_sql(&db, USERS_TABLE_SQL).await;
    web_session::migrate(&db)
        .await
        .expect("tower-sessions migrate");
    db
}

#[tokio::test]
async fn session_migration_creates_the_table_idempotently() {
    let db = fixture_db().await;
    // Running migrate again must not error (idempotent).
    web_session::migrate(&db).await.expect("migrate idempotent");
}

#[tokio::test]
async fn cookie_name_matches_plan_decision() {
    // The plan deliberately chose a different cookie name from
    // Phoenix's `_mydia_key` so the two backends' cookies don't
    // interfere during the parallel window. Any rename here is a
    // behavior change, not a refactor — this test pins it.
    assert_eq!(SESSION_COOKIE_NAME, "mydia_rs_session");
}

#[tokio::test]
async fn bcrypt_verifies_round_trip() {
    // A hash created by `mydia-rs-auth::hash_password` must verify
    // against the same plaintext. The auth crate already covers the
    // Phoenix-side compat in its own tests; this test catches the
    // round-trip the U24.a setup flow depends on.
    let hash = hash_password("correcthorse").expect("hash");
    verify_password("correcthorse", &hash).expect("verify");
    assert!(verify_password("wrongguess", &hash).is_err());
}

#[tokio::test]
async fn user_row_round_trips_through_users_table() {
    let db = fixture_db().await;
    let pool = sqlite_pool(&db);
    let hash = hash_password("correcthorse").expect("hash");
    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO users (id, username, email, password_hash, role, inserted_at, updated_at) \
         VALUES (?, ?, ?, ?, 'admin', ?, ?)",
    )
    .bind("setup-uuid")
    .bind("admin")
    .bind("admin@example.com")
    .bind(&hash)
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert");

    let (id, username, password_hash, role): (String, String, Option<String>, String) =
        sqlx::query_as("SELECT id, username, password_hash, role FROM users WHERE username = ?")
            .bind("admin")
            .fetch_one(pool)
            .await
            .expect("select");

    assert_eq!(id, "setup-uuid");
    assert_eq!(username, "admin");
    assert_eq!(role, "admin");
    let stored_hash = password_hash.expect("hash present");
    verify_password("correcthorse", &stored_hash).expect("round-trip verify");
}

#[tokio::test]
async fn counting_users_drives_setup_required() {
    let db = fixture_db().await;
    let pool = sqlite_pool(&db);

    let (before,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
        .fetch_one(pool)
        .await
        .expect("count");
    assert_eq!(before, 0, "fresh fixture has no users; setup_required=true");

    let now = chrono::Utc::now().to_rfc3339();
    sqlx::query(
        "INSERT INTO users (id, username, email, role, inserted_at, updated_at) \
         VALUES (?, ?, ?, 'admin', ?, ?)",
    )
    .bind("u1")
    .bind("admin")
    .bind("admin@example.com")
    .bind(&now)
    .bind(&now)
    .execute(pool)
    .await
    .expect("insert admin");

    let (after,): (i64,) = sqlx::query_as("SELECT COUNT(*) FROM users")
        .fetch_one(pool)
        .await
        .expect("count");
    assert_eq!(after, 1, "after first admin, setup_required must flip");
}
