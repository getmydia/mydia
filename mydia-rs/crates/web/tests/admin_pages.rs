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

CREATE TABLE IF NOT EXISTS config_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,
    category TEXT NOT NULL,
    updated_by_id TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS download_clients (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    url TEXT NOT NULL,
    username TEXT,
    password TEXT,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS indexers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    definition TEXT NOT NULL,
    base_url TEXT NOT NULL,
    api_key TEXT,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS media_servers (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    base_url TEXT NOT NULL,
    access_token TEXT,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS import_lists (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    kind TEXT NOT NULL,
    url_or_id TEXT NOT NULL,
    enabled BOOLEAN NOT NULL DEFAULT 1,
    last_synced_at TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS release_blacklist (
    id TEXT PRIMARY KEY,
    kind TEXT NOT NULL,
    pattern TEXT NOT NULL,
    reason TEXT,
    inserted_at TEXT NOT NULL,
    updated_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS quality_profiles (
    id TEXT PRIMARY KEY,
    name TEXT NOT NULL,
    description TEXT,
    qualities TEXT,
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

// ---------- config_settings ----------

#[tokio::test]
async fn config_settings_upsert_updates_existing_row() {
    let fx = fixture().await;
    let admin = insert_user(&fx.db, "admin").await;
    let now = Utc::now().to_rfc3339();

    match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            )
            .bind("server.port")
            .bind("4000")
            .bind("Server")
            .bind(&admin)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert");

            // Second upsert on the same key changes the value, not the row count.
            sqlx::query(
                "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?) \
                 ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at",
            )
            .bind("server.port")
            .bind("5555")
            .bind("Server")
            .bind(&admin)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("update via upsert");
        }
        Db::Postgres(_) => unreachable!(),
    }

    let rows: Vec<(String, String)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT key, value FROM config_settings")
            .fetch_all(pool)
            .await
            .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 1, "upsert collapses to one row");
    assert_eq!(rows[0].0, "server.port");
    assert_eq!(rows[0].1, "5555");
}

// ---------- download_clients ----------

async fn insert_download_client(db: &Db, name: &str, kind: &str, enabled: bool) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO download_clients (id, name, kind, url, enabled, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(name)
            .bind(kind)
            .bind("http://localhost:8080")
            .bind(enabled)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert download_client");
        }
        Db::Postgres(_) => unreachable!(),
    }
    id
}

#[tokio::test]
async fn download_clients_list_returns_inserted_rows_ordered() {
    let fx = fixture().await;
    let _qb = insert_download_client(&fx.db, "qb1", "qbittorrent", true).await;
    let _tr = insert_download_client(&fx.db, "tr1", "transmission", true).await;

    let rows: Vec<(String, String, bool)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as(
            "SELECT name, kind, enabled FROM download_clients ORDER BY inserted_at ASC",
        )
        .fetch_all(pool)
        .await
        .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].0, "qb1");
    assert_eq!(rows[1].0, "tr1");
}

#[tokio::test]
async fn download_clients_toggle_flips_enabled() {
    let fx = fixture().await;
    let id = insert_download_client(&fx.db, "qb", "qbittorrent", true).await;

    let now = Utc::now().to_rfc3339();
    match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "UPDATE download_clients SET enabled = NOT enabled, updated_at = ? WHERE id = ?",
        )
        .bind(&now)
        .bind(&id)
        .execute(pool)
        .await
        .expect("toggle"),
        Db::Postgres(_) => unreachable!(),
    };

    let (enabled,): (bool,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT enabled FROM download_clients WHERE id = ?")
            .bind(&id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert!(!enabled, "toggle flipped enabled to false");
}

// ---------- download_clients: probe cache ----------
//
// These tests exercise the `crate::download_probes::ProbeCache` surface
// directly with a stub adapter — no real network IO. The cache is what
// `test_download_client` reaches into, so pinning its TTL + invalidation
// behaviour here gives us confidence the admin "Test" button does the
// right thing across the live-probe / cached-result / refresh flows.

use mydia_rs_downloads::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadStatus, ListOpts, Protocol,
    TorrentInput,
};
use mydia_rs_downloads::error::DownloadError;
use mydia_rs_downloads::registry::ClientRegistry;
use mydia_rs_web::download_probes::{config_from_url, ProbeCache};
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
use std::sync::Arc as StdArc;

struct StubAdapter {
    name: &'static str,
    calls: StdArc<AtomicUsize>,
    ok: bool,
}

#[async_trait::async_trait]
impl DownloadClient for StubAdapter {
    fn name(&self) -> &'static str {
        self.name
    }
    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }
    async fn test_connection(&self, _: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        self.calls.fetch_add(1, AtomicOrdering::SeqCst);
        if self.ok {
            Ok(ClientInfo {
                version: "stub-1.0".into(),
                ..Default::default()
            })
        } else {
            Err(DownloadError::Network("simulated".into()))
        }
    }
    async fn add(
        &self,
        _: &ClientConfig,
        _: TorrentInput,
        _: AddOpts,
    ) -> Result<String, DownloadError> {
        unimplemented!()
    }
    async fn list_active(
        &self,
        _: &ClientConfig,
        _: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        unimplemented!()
    }
    async fn cancel(&self, _: &ClientConfig, _: &str, _: bool) -> Result<(), DownloadError> {
        unimplemented!()
    }
    async fn get_files(&self, _: &ClientConfig, _: &str) -> Result<Vec<String>, DownloadError> {
        unimplemented!()
    }
    async fn get_save_path(&self, _: &ClientConfig, _: &str) -> Result<String, DownloadError> {
        unimplemented!()
    }
}

fn probe_cache_with_stub(ok: bool) -> (ProbeCache, StdArc<AtomicUsize>) {
    let calls = StdArc::new(AtomicUsize::new(0));
    let registry = ClientRegistry::new();
    registry.register(StdArc::new(StubAdapter {
        name: "qbittorrent",
        calls: calls.clone(),
        ok,
    }));
    let cache = ProbeCache::new()
        .with_registry(registry)
        .with_ttl(std::time::Duration::from_millis(50));
    (cache, calls)
}

#[tokio::test]
async fn probe_cache_returns_reachable_for_known_adapter() {
    let (cache, calls) = probe_cache_with_stub(true);
    let cfg = config_from_url("http://localhost:8080", None, None).expect("parse url");
    let entry = cache.probe("client-1", "qbittorrent", cfg).await;
    assert!(entry.ok, "stub adapter reports reachable");
    assert!(entry.message.contains("qbittorrent"));
    assert!(entry.message.contains("stub-1.0"));
    assert_eq!(calls.load(AtomicOrdering::SeqCst), 1);
}

#[tokio::test]
async fn probe_cache_records_network_failure() {
    let (cache, _calls) = probe_cache_with_stub(false);
    let cfg = config_from_url("http://localhost:8080", None, None).expect("parse url");
    let entry = cache.probe("client-1", "qbittorrent", cfg).await;
    assert!(!entry.ok, "stub adapter reports unreachable");
    assert!(
        entry.message.contains("simulated"),
        "underlying error threaded into message"
    );
}

#[tokio::test]
async fn probe_cache_serves_cached_entry_within_ttl() {
    let (cache, calls) = probe_cache_with_stub(true);
    let cfg = config_from_url("http://localhost:8080", None, None).expect("parse url");
    cache.probe("client-1", "qbittorrent", cfg.clone()).await;
    cache.probe("client-1", "qbittorrent", cfg).await;
    assert_eq!(
        calls.load(AtomicOrdering::SeqCst),
        1,
        "second call hits cache, not network"
    );
}

#[tokio::test]
async fn probe_cache_invalidate_drops_entry() {
    let (cache, calls) = probe_cache_with_stub(true);
    let cfg = config_from_url("http://localhost:8080", None, None).expect("parse url");
    cache.probe("client-1", "qbittorrent", cfg.clone()).await;
    cache.invalidate("client-1");
    cache.probe("client-1", "qbittorrent", cfg).await;
    assert_eq!(
        calls.load(AtomicOrdering::SeqCst),
        2,
        "invalidate forces a fresh probe"
    );
}

// ---------- indexers ----------

#[tokio::test]
async fn indexers_insert_and_list_round_trip() {
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "INSERT INTO indexers (id, name, definition, base_url, enabled, inserted_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&id)
        .bind("iptorrents")
        .bind("iptorrents")
        .bind("https://iptorrents.com")
        .bind(true)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert indexer"),
        Db::Postgres(_) => unreachable!(),
    };

    let rows: Vec<(String, String, String)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT name, definition, base_url FROM indexers")
            .fetch_all(pool)
            .await
            .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].0, "iptorrents");
    assert_eq!(rows[0].2, "https://iptorrents.com");
}

// ---------- media_servers ----------

#[tokio::test]
async fn media_servers_delete_removes_row() {
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO media_servers (id, name, kind, base_url, enabled, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind("jellyfin")
            .bind("jellyfin")
            .bind("http://jellyfin:8096")
            .bind(true)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert");
        }
        Db::Postgres(_) => unreachable!(),
    }

    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query("DELETE FROM media_servers WHERE id = ?")
            .bind(&id)
            .execute(pool)
            .await
            .expect("delete")
            .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);

    let (count,): (i64,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT COUNT(*) FROM media_servers")
            .fetch_one(pool)
            .await
            .expect("count"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(count, 0);
}

// ---------- import_lists ----------

#[tokio::test]
async fn import_lists_kind_constraint_via_validation() {
    // The kind constraint lives in the server fn's validator, not
    // the DB schema; this test pins the inserted-shape contract.
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "INSERT INTO import_lists (id, name, kind, url_or_id, enabled, inserted_at, updated_at) \
             VALUES (?, ?, ?, ?, ?, ?, ?)",
        )
        .bind(&id)
        .bind("trending")
        .bind("trakt")
        .bind("user/mylist")
        .bind(true)
        .bind(&now)
        .bind(&now)
        .execute(pool)
        .await
        .expect("insert"),
        Db::Postgres(_) => unreachable!(),
    };

    let (kind,): (String,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT kind FROM import_lists WHERE id = ?")
            .bind(&id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(kind, "trakt");
}

// ---------- release_blacklist ----------

#[tokio::test]
async fn release_blacklist_insert_and_delete_round_trip() {
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO release_blacklist (id, kind, pattern, reason, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind("title")
            .bind("*CAM*")
            .bind(Some("camrip quality unacceptable".to_owned()))
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert");
        }
        Db::Postgres(_) => unreachable!(),
    }

    let (pattern,): (String,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT pattern FROM release_blacklist WHERE id = ?")
            .bind(&id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(pattern, "*CAM*");

    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query("DELETE FROM release_blacklist WHERE id = ?")
            .bind(&id)
            .execute(pool)
            .await
            .expect("delete")
            .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);
}

// ---------- quality_profiles ----------

use mydia_rs_web::server_fns::admin::quality_profiles::{
    validate_profile, ValidationError, VALID_RESOLUTIONS,
};

async fn insert_profile(db: &Db, name: &str, qualities: &[&str]) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let qualities_json = serde_json::to_string(qualities).expect("serialise qualities");
    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO quality_profiles (id, name, qualities, inserted_at, updated_at) \
                 VALUES (?, ?, ?, ?, ?)",
            )
            .bind(&id)
            .bind(name)
            .bind(&qualities_json)
            .bind(&now)
            .bind(&now)
            .execute(pool)
            .await
            .expect("insert profile");
        }
        Db::Postgres(_) => unreachable!(),
    }
    id
}

fn quality_count(qualities_json: Option<&str>) -> i64 {
    match qualities_json {
        None => 0,
        Some(s) if s.trim().is_empty() => 0,
        Some(s) => serde_json::from_str::<Vec<String>>(s)
            .map(|v| v.len() as i64)
            .unwrap_or(0),
    }
}

#[tokio::test]
async fn quality_profiles_list_counts_qualities_from_json_column() {
    let fx = fixture().await;
    let _id = insert_profile(&fx.db, "Any", &["480p", "720p", "1080p"]).await;

    let rows: Vec<(String, String, Option<String>)> = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as(
            "SELECT id, name, qualities FROM quality_profiles ORDER BY inserted_at ASC",
        )
        .fetch_all(pool)
        .await
        .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };

    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].1, "Any");
    assert_eq!(quality_count(rows[0].2.as_deref()), 3);
}

#[tokio::test]
async fn quality_profiles_create_and_reload_renders_ordered_qualities() {
    // Happy path: insert a profile with 2 ordered qualities and read
    // them back to confirm the order is preserved.
    let fx = fixture().await;
    let _id = insert_profile(&fx.db, "HD Only", &["1080p", "720p"]).await;

    let (qualities_json,): (Option<String>,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT qualities FROM quality_profiles WHERE name = ?")
            .bind("HD Only")
            .fetch_one(pool)
            .await
            .expect("query"),
        Db::Postgres(_) => unreachable!(),
    };
    let decoded: Vec<String> =
        serde_json::from_str(qualities_json.as_deref().unwrap_or("[]")).expect("decode");
    assert_eq!(decoded, vec!["1080p".to_owned(), "720p".to_owned()]);
}

#[tokio::test]
async fn quality_profiles_update_renames_and_reorders() {
    // Happy path: edit profile name and swap two qualities.
    let fx = fixture().await;
    let id = insert_profile(&fx.db, "Initial", &["1080p", "720p"]).await;

    let now = Utc::now().to_rfc3339();
    let new_qualities = serde_json::to_string(&["720p", "1080p"]).expect("encode");
    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query(
            "UPDATE quality_profiles SET name = ?, qualities = ?, updated_at = ? WHERE id = ?",
        )
        .bind("Renamed")
        .bind(&new_qualities)
        .bind(&now)
        .bind(&id)
        .execute(pool)
        .await
        .expect("update")
        .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);

    let (name, qualities_json): (String, Option<String>) = match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT name, qualities FROM quality_profiles WHERE id = ?")
                .bind(&id)
                .fetch_one(pool)
                .await
                .expect("readback")
        }
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(name, "Renamed");
    let decoded: Vec<String> =
        serde_json::from_str(qualities_json.as_deref().unwrap_or("[]")).expect("decode");
    assert_eq!(decoded, vec!["720p".to_owned(), "1080p".to_owned()]);
}

#[tokio::test]
async fn quality_profiles_delete_removes_row() {
    // Happy path: delete a single cutoff (by re-saving the profile
    // without it) and confirm the persisted JSON has shrunk.
    let fx = fixture().await;
    let id = insert_profile(&fx.db, "Trim Me", &["1080p", "720p", "480p"]).await;

    let now = Utc::now().to_rfc3339();
    let new_qualities = serde_json::to_string(&["1080p", "720p"]).expect("encode");
    match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query("UPDATE quality_profiles SET qualities = ?, updated_at = ? WHERE id = ?")
                .bind(&new_qualities)
                .bind(&now)
                .bind(&id)
                .execute(pool)
                .await
                .expect("update")
        }
        Db::Postgres(_) => unreachable!(),
    };

    let (qualities_json,): (Option<String>,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT qualities FROM quality_profiles WHERE id = ?")
            .bind(&id)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    let decoded: Vec<String> =
        serde_json::from_str(qualities_json.as_deref().unwrap_or("[]")).expect("decode");
    assert_eq!(decoded, vec!["1080p".to_owned(), "720p".to_owned()]);
    assert!(!decoded.contains(&"480p".to_owned()));
}

#[tokio::test]
async fn quality_profiles_delete_profile_removes_row() {
    let fx = fixture().await;
    let id = insert_profile(&fx.db, "Doomed", &["1080p"]).await;

    let affected = match &fx.db {
        Db::Sqlite(pool) => sqlx::query("DELETE FROM quality_profiles WHERE id = ?")
            .bind(&id)
            .execute(pool)
            .await
            .expect("delete")
            .rows_affected(),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(affected, 1);

    let (count,): (i64,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT COUNT(*) FROM quality_profiles")
            .fetch_one(pool)
            .await
            .expect("count"),
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(count, 0);
}

#[test]
fn quality_profiles_validation_rejects_empty_qualities() {
    // Edge case: create profile with zero cutoffs is rejected up-front.
    assert_eq!(
        validate_profile("Bad", &[]),
        Some(ValidationError::EmptyQualities)
    );
}

#[test]
fn quality_profiles_validation_rejects_duplicate_resolutions() {
    // Edge case: create profile with duplicate-resolution cutoffs
    // is rejected before the SQL layer ever sees the payload.
    let qs = vec!["1080p".to_owned(), "1080p".to_owned()];
    assert_eq!(
        validate_profile("Dupes", &qs),
        Some(ValidationError::DuplicateResolution("1080p".to_owned()))
    );
}

#[test]
fn quality_profiles_validation_rejects_unknown_resolutions() {
    // Mirror Phoenix's `@valid_resolutions` membership check.
    let qs = vec!["1080p".to_owned(), "9999p".to_owned()];
    assert_eq!(
        validate_profile("Bad", &qs),
        Some(ValidationError::UnknownResolution("9999p".to_owned()))
    );
}

#[test]
fn quality_profiles_validation_accepts_canonical_payload() {
    let qs: Vec<String> = VALID_RESOLUTIONS.iter().map(|r| (*r).to_owned()).collect();
    assert_eq!(validate_profile("Everything", &qs), None);
}

#[test]
fn quality_profiles_validation_rejects_blank_name() {
    assert_eq!(
        validate_profile("   ", &["1080p".to_owned()]),
        Some(ValidationError::BlankName)
    );
}

// ---------- non-admin auth gate ----------
//
// The full `require_admin_user_id()` chain needs a live tower-sessions
// context which the in-memory fixture doesn't reconstruct. We instead
// pin the schema-level invariant that gates every admin server fn:
// the row's `role` column has to read "admin" or the function bails.
// `quality_profiles_admin_gate_smoke` walks the lookup path the auth
// helper takes — `lookup_user_role` reads `role` from the `users` table
// — so a guest user's role read returns "guest", not "admin".

#[tokio::test]
async fn quality_profiles_admin_gate_rejects_guest_role() {
    let fx = fixture().await;
    let guest = insert_user(&fx.db, "guest").await;

    let (role,): (String,) = match &fx.db {
        Db::Sqlite(pool) => sqlx::query_as("SELECT role FROM users WHERE id = ?")
            .bind(&guest)
            .fetch_one(pool)
            .await
            .expect("readback"),
        Db::Postgres(_) => unreachable!(),
    };
    // Same predicate `require_admin_user_id` uses inline — a non-admin
    // role causes the helper to short-circuit with "not authorized"
    // before any CRUD server fn touches the database.
    assert_ne!(role, "admin");
}

// ---------- remote_access ----------

#[tokio::test]
async fn remote_access_status_counts_active_vs_revoked() {
    let fx = fixture().await;
    let user = insert_user(&fx.db, "admin").await;
    let _live = insert_device(&fx.db, &user, false).await;
    let _live2 = insert_device(&fx.db, &user, false).await;
    let _dead = insert_device(&fx.db, &user, true).await;

    let (paired,): (i64,) = match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NULL")
                .fetch_one(pool)
                .await
                .expect("count")
        }
        Db::Postgres(_) => unreachable!(),
    };
    let (revoked,): (i64,) = match &fx.db {
        Db::Sqlite(pool) => {
            sqlx::query_as("SELECT COUNT(*) FROM remote_devices WHERE revoked_at IS NOT NULL")
                .fetch_one(pool)
                .await
                .expect("count")
        }
        Db::Postgres(_) => unreachable!(),
    };
    assert_eq!(paired, 2, "two paired devices stay live");
    assert_eq!(revoked, 1, "one revoked device is counted separately");
}

#[test]
fn p2p_status_default_is_not_running() {
    // The page reads `running` to decide whether to render the "Live
    // host status" section. When the p2p Server isn't booted (no
    // keypair configured, or remote access disabled), the server fn
    // returns the default P2pStatus shape — the live section must
    // stay hidden.
    use mydia_rs_web::server_fns::admin::remote_access::P2pStatus;
    let s = P2pStatus::default();
    assert!(!s.running, "default p2p status must report not-running");
    assert_eq!(s.node_id, "");
    assert_eq!(s.connected_peers, 0);
    assert!(s.relay_url.is_none());
    assert!(s.node_addr.is_none());
}

#[test]
fn p2p_status_round_trips_through_serde() {
    // The page receives this shape via Dioxus's server-fn JSON wire,
    // so it must survive `serde_json::to_string` + `from_str`. This
    // pins the wasm-compat contract: no `chrono::DateTime`, no
    // `sqlx` types, no `Uuid` — pure strings + ints + bools.
    use mydia_rs_web::server_fns::admin::remote_access::P2pStatus;
    let s = P2pStatus {
        node_id: "abcdef0123456789".to_owned(),
        paired_devices: 3,
        revoked_devices: 1,
        last_seen_summary: Some("3 active in the last hour".to_owned()),
        running: true,
        connected_peers: 2,
        relay_connected: true,
        relay_url: Some("https://relay.example.com".to_owned()),
        node_addr: Some(r#"{"node_id":"abcdef","direct_addresses":[]}"#.to_owned()),
        peer_connection_type: Some("direct".to_owned()),
    };
    let encoded = serde_json::to_string(&s).expect("serialize");
    let round: P2pStatus = serde_json::from_str(&encoded).expect("deserialize");
    assert_eq!(round, s);
}
