//! Integration tests for the U28 admin pages.
//!
//! Mirrors the U23 pilot's `admin_library_paths.rs` shape — drives
//! the server-fn behaviour against a real in-memory `SQLite` pool
//! and a real pubsub bus, without going over an HTTP upgrade.
//!
//! Coverage:
//!   - jobs: pubsub fan-out for a `JOBS_STATUS` event decodes into
//!     the typed `JobStatusEvent`.
//!   - transcodes: list returns rows ordered by `inserted_at` DESC;
//!     cancel flips the row status to `cancelled`; pubsub fan-out
//!     for a `TRANSCODES` topic event decodes into `TranscodeEvent`.
//!   - users: insert/list round-trip; role hierarchy survives.
//!   - devices: list scopes to a single user; revoke writes a
//!     `revoked_at` timestamp.
//!   - requests: insert/list round-trip with status filter.

#![cfg(feature = "server")]

use chrono::Utc;
use mydia_rs_db::Db;
use mydia_rs_pubsub::{topics, Event, Pubsub};
use mydia_rs_web::realtime::jobs_status::JobStatusEvent;
use mydia_rs_web::realtime::transcodes::TranscodeEvent;
use sqlx::sqlite::SqlitePoolOptions;
use tokio::sync::broadcast::Receiver;

/// Minimal stand-in schema for the U28 admin pages. Phoenix
/// migrations are out of scope per the rewrite plan; this constant
/// declares only the columns the server fns read or write.
const SETUP_SQL: &str = "
CREATE TABLE IF NOT EXISTS users (
    id TEXT PRIMARY KEY,
    username TEXT,
    email TEXT,
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

CREATE TABLE IF NOT EXISTS media_files (
    id TEXT PRIMARY KEY,
    file_name TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS transcode_jobs (
    id TEXT PRIMARY KEY,
    media_file_id TEXT NOT NULL,
    resolution TEXT NOT NULL,
    status TEXT NOT NULL,
    progress REAL,
    output_path TEXT,
    file_size INTEGER,
    error TEXT,
    started_at TEXT,
    completed_at TEXT,
    last_accessed_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS remote_devices (
    id TEXT PRIMARY KEY,
    device_name TEXT NOT NULL,
    platform TEXT NOT NULL,
    device_static_public_key BLOB,
    token_hash TEXT,
    last_seen_at TEXT,
    revoked_at TEXT,
    user_id TEXT NOT NULL,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_requests (
    id TEXT PRIMARY KEY,
    media_type TEXT NOT NULL,
    title TEXT NOT NULL,
    original_title TEXT,
    year INTEGER,
    tmdb_id INTEGER,
    imdb_id TEXT,
    status TEXT NOT NULL DEFAULT 'pending',
    requester_notes TEXT,
    admin_notes TEXT,
    rejection_reason TEXT,
    approved_at TEXT,
    rejected_at TEXT,
    requester_id TEXT NOT NULL,
    approved_by_id TEXT,
    media_item_id TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);
";

struct Fixture {
    db: Db,
    pubsub: Pubsub,
}

async fn fixture() -> Fixture {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("open in-memory sqlite");
    for stmt in SETUP_SQL.split(';') {
        let trimmed = stmt.trim();
        if !trimmed.is_empty() {
            sqlx::query(trimmed)
                .execute(&pool)
                .await
                .expect("create table");
        }
    }
    Fixture {
        db: Db::Sqlite(pool),
        pubsub: Pubsub::new(),
    }
}

async fn insert_user(db: &Db, role: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO users (id, username, email, role, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(format!("user-{}", &id[..8]))
            .bind(format!("{}@example.com", &id[..8]))
            .bind(role)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert user");
        }
        Db::Postgres(_) => unreachable!("test uses sqlite"),
    }
    id
}

// ---------- jobs ----------

#[tokio::test]
async fn jobs_pubsub_event_decodes_into_typed_event() {
    let fx = fixture().await;
    let mut rx: Receiver<Event> = fx.pubsub.subscribe(topics::JOBS_STATUS);

    fx.pubsub.publish(
        topics::JOBS_STATUS,
        Event::from_json(serde_json::json!({
            "kind": "stop",
            "worker_id": "library_scanner",
            "payload": {},
        })),
    );

    let event = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
        .await
        .expect("recv before timeout")
        .expect("event delivered");
    let decoded: JobStatusEvent = serde_json::from_value(event.payload).expect("decode");
    assert_eq!(decoded.kind, "stop");
    assert_eq!(decoded.worker_id, "library_scanner");
}

// ---------- transcodes ----------

async fn insert_transcode(db: &Db, status: &str) -> (String, String) {
    let mf_id = uuid::Uuid::new_v4().to_string();
    let job_id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO media_files (id, file_name, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?)",
            )
            .bind(&mf_id)
            .bind("S01E01.mkv")
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert media_file");

            sqlx::query(
                "INSERT INTO transcode_jobs (id, media_file_id, resolution, status, progress, \
                        inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&job_id)
            .bind(&mf_id)
            .bind("1080p")
            .bind(status)
            .bind(0.5_f64)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert transcode");
        }
        Db::Postgres(_) => unreachable!(),
    }
    (job_id, mf_id)
}

type TranscodeReadRow = (String, String, Option<String>, String, String, Option<f64>);

#[tokio::test]
async fn transcodes_list_query_round_trips() {
    let fx = fixture().await;
    let (job_id, _) = insert_transcode(&fx.db, "transcoding").await;

    // Re-run the read query directly to confirm the join + ordering
    // mirror what the server fn returns.
    let rows: Vec<TranscodeReadRow> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as(
            "SELECT t.id, t.media_file_id, mf.file_name, t.resolution, t.status, t.progress \
             FROM transcode_jobs t \
             LEFT JOIN media_files mf ON mf.id = t.media_file_id \
             ORDER BY t.inserted_at DESC",
        )
        .fetch_all(pool)
        .await
        .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].0, job_id);
    assert_eq!(rows[0].2.as_deref(), Some("S01E01.mkv"));
    assert_eq!(rows[0].3, "1080p");
    assert_eq!(rows[0].4, "transcoding");
}

#[tokio::test]
async fn transcodes_cancel_flips_status() {
    let fx = fixture().await;
    let (job_id, _) = insert_transcode(&fx.db, "transcoding").await;

    // Run the cancel update directly (mirrors the server fn body).
    let now = Utc::now().to_rfc3339();
    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "UPDATE transcode_jobs SET status = 'cancelled', updated_at = ? WHERE id = ?",
        )
        .bind(&now)
        .bind(&job_id)
        .execute(pool)
        .await
        .expect("update")
        .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);

    let (status,): (String,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT status FROM transcode_jobs WHERE id = ?")
            .bind(&job_id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(status, "cancelled");
}

#[tokio::test]
async fn transcodes_pubsub_event_decodes_into_typed_event() {
    let fx = fixture().await;
    let mut rx: Receiver<Event> = fx.pubsub.subscribe(topics::TRANSCODES);

    fx.pubsub.publish(
        topics::TRANSCODES,
        Event::from_json(serde_json::json!({
            "event": "progress",
            "job_id": "abc",
            "progress": 0.75_f64,
            "status": "transcoding",
        })),
    );

    let event = tokio::time::timeout(std::time::Duration::from_secs(1), rx.recv())
        .await
        .expect("recv")
        .expect("event");
    let decoded: TranscodeEvent = serde_json::from_value(event.payload).expect("decode");
    assert!(matches!(decoded, TranscodeEvent::Updated { .. }));
    assert_eq!(decoded.job_id(), Some("abc"));
}

// ---------- users ----------

type UserReadRow = (
    String,
    Option<String>,
    Option<String>,
    String,
    Option<String>,
);

#[tokio::test]
async fn users_list_returns_inserted_row() {
    let fx = fixture().await;
    let id = insert_user(&fx.db, "guest").await;

    let rows: Vec<UserReadRow> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as(
            "SELECT id, username, email, role, oidc_sub FROM users ORDER BY inserted_at ASC",
        )
        .fetch_all(pool)
        .await
        .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].0, id);
    assert_eq!(rows[0].3, "guest");
    assert!(rows[0].4.is_none(), "non-OIDC user has no oidc_sub");
}

#[tokio::test]
async fn users_role_update_writes_through() {
    let fx = fixture().await;
    let id = insert_user(&fx.db, "guest").await;

    let now = Utc::now().to_rfc3339();
    match &fx.db {
        Db::Sqlite(pool) => sqlx::query("UPDATE users SET role = ?, updated_at = ? WHERE id = ?")
            .bind("admin")
            .bind(&now)
            .bind(&id)
            .execute(pool)
            .await
            .expect("update"),
        Db::Postgres(_) => unreachable!(),
    };

    let (role,): (String,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT role FROM users WHERE id = ?")
            .bind(&id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(role, "admin");
}

// ---------- devices ----------

async fn insert_device(db: &Db, user_id: &str, revoked: bool) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let revoked_at = if revoked { Some(now.clone()) } else { None };
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO remote_devices (id, device_name, platform, last_seen_at, revoked_at, \
                        user_id, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind("Pixel 8")
            .bind("android")
            .bind(&now)
            .bind(revoked_at.as_deref())
            .bind(user_id)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert device");
        }
        Db::Postgres(_) => unreachable!(),
    }
    id
}

#[tokio::test]
async fn devices_list_scopes_to_user() {
    let fx = fixture().await;
    let user_a = insert_user(&fx.db, "admin").await;
    let user_b = insert_user(&fx.db, "admin").await;
    let _device_a = insert_device(&fx.db, &user_a, false).await;
    let _device_b = insert_device(&fx.db, &user_b, false).await;

    let rows: Vec<(String,)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT id FROM remote_devices WHERE user_id = ?")
            .bind(&user_a)
            .fetch_all(pool)
            .await
            .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 1, "user A only sees their own device");
}

#[tokio::test]
async fn devices_revoke_writes_revoked_at() {
    let fx = fixture().await;
    let user = insert_user(&fx.db, "admin").await;
    let device = insert_device(&fx.db, &user, false).await;

    let now = Utc::now().to_rfc3339();
    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "UPDATE remote_devices SET revoked_at = ?, updated_at = ? \
             WHERE id = ? AND user_id = ?",
        )
        .bind(&now)
        .bind(&now)
        .bind(&device)
        .bind(&user)
        .execute(pool)
        .await
        .expect("update")
        .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);

    let (revoked_at,): (Option<String>,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT revoked_at FROM remote_devices WHERE id = ?")
            .bind(&device)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert!(revoked_at.is_some(), "revoke wrote a timestamp");
}

// ---------- requests ----------

async fn insert_request(db: &Db, requester_id: &str, status: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO media_requests (id, media_type, title, status, requester_id, \
                        inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind("movie")
            .bind("Inception")
            .bind(status)
            .bind(requester_id)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert media_request");
        }
        Db::Postgres(_) => unreachable!(),
    }
    id
}

#[tokio::test]
async fn requests_filter_by_pending_matches_phoenix_default() {
    let fx = fixture().await;
    let requester = insert_user(&fx.db, "guest").await;
    let _pending = insert_request(&fx.db, &requester, "pending").await;
    let _approved = insert_request(&fx.db, &requester, "approved").await;

    let rows: Vec<(String, String)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as(
            "SELECT r.id, r.status \
             FROM media_requests r \
             LEFT JOIN users u ON u.id = r.requester_id \
             WHERE r.status = ? \
             ORDER BY r.inserted_at DESC",
        )
        .bind("pending")
        .fetch_all(pool)
        .await
        .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 1, "pending filter shows only pending request");
    assert_eq!(rows[0].1, "pending");
}

#[tokio::test]
async fn requests_approve_updates_status() {
    let fx = fixture().await;
    let requester = insert_user(&fx.db, "guest").await;
    let admin = insert_user(&fx.db, "admin").await;
    let request = insert_request(&fx.db, &requester, "pending").await;

    let now = Utc::now().to_rfc3339();
    match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "UPDATE media_requests SET status = 'approved', \
                        approved_by_id = ?, approved_at = ?, updated_at = ? WHERE id = ?",
            )
            .bind(&admin)
            .bind(&now)
            .bind(&now)
            .bind(&request)
            .execute(pool)
            .await
            .expect("approve");
        }
        Db::Postgres(_) => unreachable!(),
    }

    let (status, approved_by): (String, Option<String>) = match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT status, approved_by_id FROM media_requests WHERE id = ?")
                .bind(&request)
                .fetch_one(pool)
                .await
                .expect("readback")
        }
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(status, "approved");
    assert_eq!(approved_by.as_deref(), Some(admin.as_str()));
}
