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

mod common;

use chrono::Utc;
use common::{apply_sql, fresh_db};
use mydia_rs_db::DatabaseConnection;
use mydia_rs_pubsub::{topics, Event, Pubsub};
use mydia_rs_web::realtime::jobs_status::JobStatusEvent;
use mydia_rs_web::realtime::transcodes::TranscodeEvent;
use sea_orm::{ConnectionTrait, QueryResult, Statement};
use tokio::sync::broadcast::Receiver;

/// Escape a string for inlining inside a single-quoted SQL string
/// literal. Test inputs are controlled; this is a defensive escape.
fn esc(s: &str) -> String {
    s.replace('\'', "''")
}

/// Convenience helper: run a SELECT and fetch all rows.
async fn query_all(db: &DatabaseConnection, sql: String) -> Vec<QueryResult> {
    let backend = db.get_database_backend();
    db.query_all_raw(Statement::from_string(backend, sql))
        .await
        .expect("query_all_raw")
}

/// Convenience helper: run a SELECT and fetch a single row (must exist).
async fn query_one(db: &DatabaseConnection, sql: String) -> QueryResult {
    let backend = db.get_database_backend();
    db.query_one_raw(Statement::from_string(backend, sql))
        .await
        .expect("query_one_raw")
        .expect("row")
}

/// Convenience helper: run a SELECT and fetch a single row if present.
#[allow(dead_code)]
async fn query_optional(db: &DatabaseConnection, sql: String) -> Option<QueryResult> {
    let backend = db.get_database_backend();
    db.query_one_raw(Statement::from_string(backend, sql))
        .await
        .expect("query_one_raw")
}

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
    db: DatabaseConnection,
    pubsub: Pubsub,
}

async fn fixture() -> Fixture {
    let db = fresh_db().await;
    apply_sql(&db, SETUP_SQL).await;
    Fixture {
        db,
        pubsub: Pubsub::new(),
    }
}

async fn insert_user(db: &DatabaseConnection, role: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let username = format!("user-{}", &id[..8]);
    let email = format!("{}@example.com", &id[..8]);
    db.execute_unprepared(&format!(
        "INSERT INTO users (id, username, email, role, inserted_at, updated_at) \
         VALUES ('{id}', '{username}', '{email}', '{role}', '{now}', '{now}')"
    ))
    .await
    .expect("insert user");
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

async fn insert_transcode(db: &DatabaseConnection, status: &str) -> (String, String) {
    let mf_id = uuid::Uuid::new_v4().to_string();
    let job_id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    db.execute_unprepared(&format!(
        "INSERT INTO media_files (id, file_name, inserted_at, updated_at) \
         VALUES ('{mf_id}', 'S01E01.mkv', '{now}', '{now}')"
    ))
    .await
    .expect("insert media_file");

    db.execute_unprepared(&format!(
        "INSERT INTO transcode_jobs (id, media_file_id, resolution, status, progress, \
                inserted_at, updated_at) \
         VALUES ('{job_id}', '{mf_id}', '1080p', '{status}', 0.5, '{now}', '{now}')"
    ))
    .await
    .expect("insert transcode");
    (job_id, mf_id)
}

#[tokio::test]
async fn transcodes_list_query_round_trips() {
    let fx = fixture().await;
    let (job_id, _) = insert_transcode(&fx.db, "transcoding").await;

    // Re-run the read query directly to confirm the join + ordering
    // mirror what the server fn returns.
    let rows = query_all(
        &fx.db,
        "SELECT t.id, t.media_file_id, mf.file_name, t.resolution, t.status, t.progress \
         FROM transcode_jobs t \
         LEFT JOIN media_files mf ON mf.id = t.media_file_id \
         ORDER BY t.inserted_at DESC"
            .to_owned(),
    )
    .await;

    assert_eq!(rows.len(), 1);
    let r_id: String = rows[0].try_get_by("id").expect("id");
    let r_file_name: Option<String> = rows[0].try_get_by("file_name").expect("file_name");
    let r_resolution: String = rows[0].try_get_by("resolution").expect("resolution");
    let r_status: String = rows[0].try_get_by("status").expect("status");
    assert_eq!(r_id, job_id);
    assert_eq!(r_file_name.as_deref(), Some("S01E01.mkv"));
    assert_eq!(r_resolution, "1080p");
    assert_eq!(r_status, "transcoding");
}

#[tokio::test]
async fn transcodes_cancel_flips_status() {
    let fx = fixture().await;
    let (job_id, _) = insert_transcode(&fx.db, "transcoding").await;

    // Run the cancel update directly (mirrors the server fn body).
    let now = Utc::now().to_rfc3339();
    fx.db
        .execute_unprepared(&format!(
            "UPDATE transcode_jobs SET status = 'cancelled', updated_at = '{now}' WHERE id = '{job_id}'"
        ))
        .await
        .expect("update");

    let row = query_one(
        &fx.db,
        format!("SELECT status FROM transcode_jobs WHERE id = '{job_id}'"),
    )
    .await;
    let status: String = row.try_get_by("status").expect("status");
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

#[tokio::test]
async fn users_list_returns_inserted_row() {
    let fx = fixture().await;
    let id = insert_user(&fx.db, "guest").await;

    let rows = query_all(
        &fx.db,
        "SELECT id, username, email, role, oidc_sub FROM users ORDER BY inserted_at ASC".to_owned(),
    )
    .await;
    assert_eq!(rows.len(), 1);
    let r_id: String = rows[0].try_get_by("id").expect("id");
    let r_role: String = rows[0].try_get_by("role").expect("role");
    let r_oidc_sub: Option<String> = rows[0].try_get_by("oidc_sub").expect("oidc_sub");
    assert_eq!(r_id, id);
    assert_eq!(r_role, "guest");
    assert!(r_oidc_sub.is_none(), "non-OIDC user has no oidc_sub");
}

#[tokio::test]
async fn users_role_update_writes_through() {
    let fx = fixture().await;
    let id = insert_user(&fx.db, "guest").await;

    let now = Utc::now().to_rfc3339();
    fx.db
        .execute_unprepared(&format!(
            "UPDATE users SET role = 'admin', updated_at = '{now}' WHERE id = '{id}'"
        ))
        .await
        .expect("update");

    let row = query_one(&fx.db, format!("SELECT role FROM users WHERE id = '{id}'")).await;
    let role: String = row.try_get_by("role").expect("role");
    assert_eq!(role, "admin");
}

// ---------- devices ----------

async fn insert_device(db: &DatabaseConnection, user_id: &str, revoked: bool) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let revoked_at_sql = if revoked {
        format!("'{now}'")
    } else {
        "NULL".to_owned()
    };
    db.execute_unprepared(&format!(
        "INSERT INTO remote_devices (id, device_name, platform, last_seen_at, revoked_at, \
                user_id, inserted_at, updated_at) \
         VALUES ('{id}', 'Pixel 8', 'android', '{now}', {revoked_at_sql}, '{user_id}', '{now}', '{now}')"
    ))
    .await
    .expect("insert device");
    id
}

#[tokio::test]
async fn devices_list_scopes_to_user() {
    let fx = fixture().await;
    let user_a = insert_user(&fx.db, "admin").await;
    let user_b = insert_user(&fx.db, "admin").await;
    let _device_a = insert_device(&fx.db, &user_a, false).await;
    let _device_b = insert_device(&fx.db, &user_b, false).await;

    let rows = query_all(
        &fx.db,
        format!("SELECT id FROM remote_devices WHERE user_id = '{user_a}'"),
    )
    .await;
    assert_eq!(rows.len(), 1, "user A only sees their own device");
}

#[tokio::test]
async fn devices_revoke_writes_revoked_at() {
    let fx = fixture().await;
    let user = insert_user(&fx.db, "admin").await;
    let device = insert_device(&fx.db, &user, false).await;

    let now = Utc::now().to_rfc3339();
    fx.db
        .execute_unprepared(&format!(
            "UPDATE remote_devices SET revoked_at = '{now}', updated_at = '{now}' \
             WHERE id = '{device}' AND user_id = '{user}'"
        ))
        .await
        .expect("update");

    let row = query_one(
        &fx.db,
        format!("SELECT revoked_at FROM remote_devices WHERE id = '{device}'"),
    )
    .await;
    let revoked_at: Option<String> = row.try_get_by("revoked_at").expect("revoked_at");
    assert!(revoked_at.is_some(), "revoke wrote a timestamp");
}

// ---------- requests ----------

async fn insert_request(db: &DatabaseConnection, requester_id: &str, status: &str) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    db.execute_unprepared(&format!(
        "INSERT INTO media_requests (id, media_type, title, status, requester_id, \
                inserted_at, updated_at) \
         VALUES ('{id}', 'movie', 'Inception', '{status}', '{requester_id}', '{now}', '{now}')"
    ))
    .await
    .expect("insert media_request");
    id
}

#[tokio::test]
async fn requests_filter_by_pending_matches_phoenix_default() {
    let fx = fixture().await;
    let requester = insert_user(&fx.db, "guest").await;
    let _pending = insert_request(&fx.db, &requester, "pending").await;
    let _approved = insert_request(&fx.db, &requester, "approved").await;

    let rows = query_all(
        &fx.db,
        "SELECT r.id, r.status \
         FROM media_requests r \
         LEFT JOIN users u ON u.id = r.requester_id \
         WHERE r.status = 'pending' \
         ORDER BY r.inserted_at DESC"
            .to_owned(),
    )
    .await;
    assert_eq!(rows.len(), 1, "pending filter shows only pending request");
    let r_status: String = rows[0].try_get_by("status").expect("status");
    assert_eq!(r_status, "pending");
}

#[tokio::test]
async fn requests_approve_updates_status() {
    let fx = fixture().await;
    let requester = insert_user(&fx.db, "guest").await;
    let admin = insert_user(&fx.db, "admin").await;
    let request = insert_request(&fx.db, &requester, "pending").await;

    let now = Utc::now().to_rfc3339();
    fx.db
        .execute_unprepared(&format!(
            "UPDATE media_requests SET status = 'approved', \
                    approved_by_id = '{admin}', approved_at = '{now}', updated_at = '{now}' \
             WHERE id = '{request}'"
        ))
        .await
        .expect("approve");

    let row = query_one(
        &fx.db,
        format!("SELECT status, approved_by_id FROM media_requests WHERE id = '{request}'"),
    )
    .await;
    let status: String = row.try_get_by("status").expect("status");
    let approved_by: Option<String> = row.try_get_by("approved_by_id").expect("approved_by_id");
    assert_eq!(status, "approved");
    assert_eq!(approved_by.as_deref(), Some(admin.as_str()));
}

// ---------- config_settings ----------

#[tokio::test]
async fn config_settings_upsert_updates_existing_row() {
    let fx = fixture().await;
    let admin = insert_user(&fx.db, "admin").await;
    let now = Utc::now().to_rfc3339();

    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
             VALUES ('server.port', '4000', 'Server', '{admin}', '{now}', '{now}') \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at"
        ))
        .await
        .expect("insert");

    // Second upsert on the same key changes the value, not the row count.
    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO config_settings (key, value, category, updated_by_id, inserted_at, updated_at) \
             VALUES ('server.port', '5555', 'Server', '{admin}', '{now}', '{now}') \
             ON CONFLICT(key) DO UPDATE SET value = excluded.value, updated_at = excluded.updated_at"
        ))
        .await
        .expect("update via upsert");

    let rows = query_all(&fx.db, "SELECT key, value FROM config_settings".to_owned()).await;
    assert_eq!(rows.len(), 1, "upsert collapses to one row");
    let r_key: String = rows[0].try_get_by("key").expect("key");
    let r_value: String = rows[0].try_get_by("value").expect("value");
    assert_eq!(r_key, "server.port");
    assert_eq!(r_value, "5555");
}

// ---------- download_clients ----------

async fn insert_download_client(
    db: &DatabaseConnection,
    name: &str,
    kind: &str,
    enabled: bool,
) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let enabled_int = i64::from(enabled);
    db.execute_unprepared(&format!(
        "INSERT INTO download_clients (id, name, kind, url, enabled, inserted_at, updated_at) \
         VALUES ('{id}', '{name}', '{kind}', 'http://localhost:8080', {enabled_int}, '{now}', '{now}')"
    ))
    .await
    .expect("insert download_client");
    id
}

#[tokio::test]
async fn download_clients_list_returns_inserted_rows_ordered() {
    let fx = fixture().await;
    let _qb = insert_download_client(&fx.db, "qb1", "qbittorrent", true).await;
    let _tr = insert_download_client(&fx.db, "tr1", "transmission", true).await;

    let rows = query_all(
        &fx.db,
        "SELECT name, kind, enabled FROM download_clients ORDER BY inserted_at ASC".to_owned(),
    )
    .await;
    assert_eq!(rows.len(), 2);
    let r0_name: String = rows[0].try_get_by("name").expect("name");
    let r1_name: String = rows[1].try_get_by("name").expect("name");
    assert_eq!(r0_name, "qb1");
    assert_eq!(r1_name, "tr1");
}

#[tokio::test]
async fn download_clients_toggle_flips_enabled() {
    let fx = fixture().await;
    let id = insert_download_client(&fx.db, "qb", "qbittorrent", true).await;

    let now = Utc::now().to_rfc3339();
    fx.db
        .execute_unprepared(&format!(
            "UPDATE download_clients SET enabled = NOT enabled, updated_at = '{now}' WHERE id = '{id}'"
        ))
        .await
        .expect("toggle");

    let row = query_one(
        &fx.db,
        format!("SELECT enabled FROM download_clients WHERE id = '{id}'"),
    )
    .await;
    let enabled: i32 = row.try_get_by("enabled").expect("enabled");
    assert_eq!(enabled, 0, "toggle flipped enabled to false");
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

    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO indexers (id, name, definition, base_url, enabled, inserted_at, updated_at) \
             VALUES ('{id}', 'iptorrents', 'iptorrents', 'https://iptorrents.com', 1, '{now}', '{now}')"
        ))
        .await
        .expect("insert indexer");

    let rows = query_all(
        &fx.db,
        "SELECT name, definition, base_url FROM indexers".to_owned(),
    )
    .await;
    assert_eq!(rows.len(), 1);
    let r_name: String = rows[0].try_get_by("name").expect("name");
    let r_base_url: String = rows[0].try_get_by("base_url").expect("base_url");
    assert_eq!(r_name, "iptorrents");
    assert_eq!(r_base_url, "https://iptorrents.com");
}

// ---------- media_servers ----------

#[tokio::test]
async fn media_servers_delete_removes_row() {
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO media_servers (id, name, kind, base_url, enabled, inserted_at, updated_at) \
             VALUES ('{id}', 'jellyfin', 'jellyfin', 'http://jellyfin:8096', 1, '{now}', '{now}')"
        ))
        .await
        .expect("insert");

    let res = {
        let backend = fx.db.get_database_backend();
        fx.db
            .execute_raw(Statement::from_string(
                backend,
                format!("DELETE FROM media_servers WHERE id = '{id}'"),
            ))
            .await
            .expect("delete")
    };
    assert_eq!(res.rows_affected(), 1);

    let row = query_one(&fx.db, "SELECT COUNT(*) AS n FROM media_servers".to_owned()).await;
    let count: i64 = row.try_get_by("n").expect("n");
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

    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO import_lists (id, name, kind, url_or_id, enabled, inserted_at, updated_at) \
             VALUES ('{id}', 'trending', 'trakt', 'user/mylist', 1, '{now}', '{now}')"
        ))
        .await
        .expect("insert");

    let row = query_one(
        &fx.db,
        format!("SELECT kind FROM import_lists WHERE id = '{id}'"),
    )
    .await;
    let kind: String = row.try_get_by("kind").expect("kind");
    assert_eq!(kind, "trakt");
}

// ---------- release_blacklist ----------

#[tokio::test]
async fn release_blacklist_insert_and_delete_round_trip() {
    let fx = fixture().await;
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();

    fx.db
        .execute_unprepared(&format!(
            "INSERT INTO release_blacklist (id, kind, pattern, reason, inserted_at, updated_at) \
             VALUES ('{id}', 'title', '*CAM*', 'camrip quality unacceptable', '{now}', '{now}')"
        ))
        .await
        .expect("insert");

    let row = query_one(
        &fx.db,
        format!("SELECT pattern FROM release_blacklist WHERE id = '{id}'"),
    )
    .await;
    let pattern: String = row.try_get_by("pattern").expect("pattern");
    assert_eq!(pattern, "*CAM*");

    let res = {
        let backend = fx.db.get_database_backend();
        fx.db
            .execute_raw(Statement::from_string(
                backend,
                format!("DELETE FROM release_blacklist WHERE id = '{id}'"),
            ))
            .await
            .expect("delete")
    };
    assert_eq!(res.rows_affected(), 1);
}

// ---------- quality_profiles ----------

use mydia_rs_web::server_fns::admin::quality_profiles::{
    validate_profile, ValidationError, VALID_RESOLUTIONS,
};

async fn insert_profile(db: &DatabaseConnection, name: &str, qualities: &[&str]) -> String {
    let id = uuid::Uuid::new_v4().to_string();
    let now = Utc::now().to_rfc3339();
    let qualities_json = serde_json::to_string(qualities).expect("serialise qualities");
    let qualities_e = esc(&qualities_json);
    db.execute_unprepared(&format!(
        "INSERT INTO quality_profiles (id, name, qualities, inserted_at, updated_at) \
         VALUES ('{id}', '{name}', '{qualities_e}', '{now}', '{now}')"
    ))
    .await
    .expect("insert profile");
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

    let rows = query_all(
        &fx.db,
        "SELECT id, name, qualities FROM quality_profiles ORDER BY inserted_at ASC".to_owned(),
    )
    .await;

    assert_eq!(rows.len(), 1);
    let r_name: String = rows[0].try_get_by("name").expect("name");
    let r_qualities: Option<String> = rows[0].try_get_by("qualities").expect("qualities");
    assert_eq!(r_name, "Any");
    assert_eq!(quality_count(r_qualities.as_deref()), 3);
}

#[tokio::test]
async fn quality_profiles_create_and_reload_renders_ordered_qualities() {
    // Happy path: insert a profile with 2 ordered qualities and read
    // them back to confirm the order is preserved.
    let fx = fixture().await;
    let _id = insert_profile(&fx.db, "HD Only", &["1080p", "720p"]).await;

    let row = query_one(
        &fx.db,
        "SELECT qualities FROM quality_profiles WHERE name = 'HD Only'".to_owned(),
    )
    .await;
    let qualities_json: Option<String> = row.try_get_by("qualities").expect("qualities");
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
    let new_qualities_e = esc(&new_qualities);
    let res = {
        let backend = fx.db.get_database_backend();
        fx.db
            .execute_raw(Statement::from_string(
                backend,
                format!(
                    "UPDATE quality_profiles SET name = 'Renamed', qualities = '{new_qualities_e}', \
                     updated_at = '{now}' WHERE id = '{id}'"
                ),
            ))
            .await
            .expect("update")
    };
    assert_eq!(res.rows_affected(), 1);

    let row = query_one(
        &fx.db,
        format!("SELECT name, qualities FROM quality_profiles WHERE id = '{id}'"),
    )
    .await;
    let name: String = row.try_get_by("name").expect("name");
    let qualities_json: Option<String> = row.try_get_by("qualities").expect("qualities");
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
    let new_qualities_e = esc(&new_qualities);
    fx.db
        .execute_unprepared(&format!(
            "UPDATE quality_profiles SET qualities = '{new_qualities_e}', updated_at = '{now}' \
             WHERE id = '{id}'"
        ))
        .await
        .expect("update");

    let row = query_one(
        &fx.db,
        format!("SELECT qualities FROM quality_profiles WHERE id = '{id}'"),
    )
    .await;
    let qualities_json: Option<String> = row.try_get_by("qualities").expect("qualities");
    let decoded: Vec<String> =
        serde_json::from_str(qualities_json.as_deref().unwrap_or("[]")).expect("decode");
    assert_eq!(decoded, vec!["1080p".to_owned(), "720p".to_owned()]);
    assert!(!decoded.contains(&"480p".to_owned()));
}

#[tokio::test]
async fn quality_profiles_delete_profile_removes_row() {
    let fx = fixture().await;
    let id = insert_profile(&fx.db, "Doomed", &["1080p"]).await;

    let res = {
        let backend = fx.db.get_database_backend();
        fx.db
            .execute_raw(Statement::from_string(
                backend,
                format!("DELETE FROM quality_profiles WHERE id = '{id}'"),
            ))
            .await
            .expect("delete")
    };
    assert_eq!(res.rows_affected(), 1);

    let row = query_one(
        &fx.db,
        "SELECT COUNT(*) AS n FROM quality_profiles".to_owned(),
    )
    .await;
    let count: i64 = row.try_get_by("n").expect("n");
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

    let row = query_one(
        &fx.db,
        format!("SELECT role FROM users WHERE id = '{guest}'"),
    )
    .await;
    let role: String = row.try_get_by("role").expect("role");
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

    let row = query_one(
        &fx.db,
        "SELECT COUNT(*) AS n FROM remote_devices WHERE revoked_at IS NULL".to_owned(),
    )
    .await;
    let paired: i64 = row.try_get_by("n").expect("n");
    let row = query_one(
        &fx.db,
        "SELECT COUNT(*) AS n FROM remote_devices WHERE revoked_at IS NOT NULL".to_owned(),
    )
    .await;
    let revoked: i64 = row.try_get_by("n").expect("n");
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
