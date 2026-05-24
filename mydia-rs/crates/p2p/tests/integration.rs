// Tests: schema setup, raw INSERT seed fixtures, and direct UPDATEs
// used to simulate revoke / pair-state mutations are tier-(b) by
// category — runtime form is the only sensible shape for the
// in-memory `users` / `remote_devices` rows the suite asserts against.
#![allow(clippy::disallowed_methods)]

//! Integration tests for the p2p crate.
//!
//! These tests exercise the pieces a real boot wires together:
//! pairing happy-path, atomic rate limiter under concurrency, media
//! token cache hit/miss + synchronous device-revoke, and the
//! cross-backend JWT compatibility surface, against a temp `SQLite`
//! pool. They do NOT boot a real `mydia_p2p_core::Host` (that would
//! require iroh + the network); the routing seam between the Server
//! event loop and the trait surface is covered by `crates/p2p/src/router.rs`
//! unit tests.
//!
//! The `Host` integration itself is covered by smoke tests in U35's
//! e2e harness once the player + backend are mounted in the same
//! compose stack.

use std::sync::Arc;
use std::time::Duration;

use chrono::{TimeZone, Utc};
use mydia_rs_auth::{AccessTokenSigner, MediaTokenCache, MediaTokenSigner};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{connect_from_config, Db};
use mydia_rs_p2p::{
    claim::insert_claim, complete_pairing, ClaimRateLimiter, DeviceAttrs, MediaTokenValidator,
    PairingError, RateLimitOutcome, ValidationError,
};
use tempfile::TempDir;
use uuid::Uuid;

const SECRET: &str = "shared-test-guardian-secret-for-jwt-parity";

/// Build a fresh on-disk `SQLite` database with the columns the p2p
/// crate touches. Matches the Phoenix migrations
/// `20251225060000_create_remote_access_tables.exs` and
/// `20251225132113_create_pairing_claims.exs`.
async fn fresh_sqlite() -> (Db, TempDir) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("p2p.db");
    let config = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(path.to_string_lossy().into_owned()),
            pool_size: 2,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    let db = connect_from_config(&config).await.expect("connect");
    create_schema(&db).await;
    (db, tmp)
}

async fn create_schema(db: &Db) {
    let pool = db.as_sqlite().expect("sqlite-only fixture");

    // The `users` table only carries the FK target we need. Production
    // schema has many more columns; we don't model them here because
    // none of the p2p flows reach them.
    sqlx::query(
        "CREATE TABLE users (
            id TEXT PRIMARY KEY,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    sqlx::query(
        "CREATE TABLE remote_devices (
            id TEXT PRIMARY KEY,
            device_name TEXT NOT NULL,
            platform TEXT NOT NULL,
            device_static_public_key BLOB NOT NULL,
            token_hash TEXT NOT NULL,
            last_seen_at TEXT,
            revoked_at TEXT,
            user_id TEXT NOT NULL,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();

    sqlx::query(
        "CREATE TABLE pairing_claims (
            id TEXT PRIMARY KEY,
            code TEXT NOT NULL UNIQUE,
            user_id TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            used_at TEXT,
            device_id TEXT,
            inserted_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        )",
    )
    .execute(pool)
    .await
    .unwrap();
}

async fn insert_user(db: &Db) -> Uuid {
    let id = Uuid::new_v4();
    let now = "2026-05-22T00:00:00Z";
    let pool = db.as_sqlite().unwrap();
    sqlx::query("INSERT INTO users (id, inserted_at, updated_at) VALUES ($1, $2, $2)")
        .bind(id.to_string())
        .bind(now)
        .execute(pool)
        .await
        .unwrap();
    id
}

/// Happy path: pairing flow issues a claim, claim validates, device
/// row + tokens come out the other end, and the media token verifies
/// against the same signing key.
#[tokio::test]
async fn pairing_happy_path() {
    let (db, _tmp) = fresh_sqlite().await;
    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let access_signer = AccessTokenSigner::new(SECRET, 2);

    let user_id = insert_user(&db).await;
    let code = "ABCD-1234";
    insert_claim(&db, user_id, code, Duration::from_secs(300))
        .await
        .expect("insert claim");

    let attrs = DeviceAttrs {
        device_name: "Pixel 7".into(),
        platform: "android".into(),
    };

    let outcome = complete_pairing(&db, &media_signer, &access_signer, code, attrs)
        .await
        .expect("pairing completes");

    assert_eq!(outcome.device.user_id.0, user_id);
    assert_eq!(outcome.device.device_name, "Pixel 7");
    assert!(outcome.device.last_seen_at.is_some());
    assert!(outcome.device.revoked_at.is_none());

    // The media token verifies against the same signer. This is the
    // load-bearing JWT compatibility check from the plan.
    let claims = media_signer
        .verify(&outcome.media_token)
        .expect("media token verifies");
    assert_eq!(claims.sub, outcome.device.id.0.to_string());
    assert_eq!(claims.user_id, user_id.to_string());

    // Access token verifies against the access signer.
    let access_claims = access_signer
        .verify(&outcome.access_token)
        .expect("access token verifies");
    assert_eq!(access_claims.sub, user_id.to_string());
}

/// A second pairing using the same claim code fails with
/// `claim_used`, demonstrating the atomic consume.
#[tokio::test]
async fn second_pairing_with_same_claim_fails_as_used() {
    let (db, _tmp) = fresh_sqlite().await;
    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let access_signer = AccessTokenSigner::new(SECRET, 2);

    let user_id = insert_user(&db).await;
    let code = "ABCD-1234";
    insert_claim(&db, user_id, code, Duration::from_secs(300))
        .await
        .unwrap();

    let attrs = DeviceAttrs {
        device_name: "first".into(),
        platform: "android".into(),
    };
    complete_pairing(&db, &media_signer, &access_signer, code, attrs.clone())
        .await
        .unwrap();

    let err = complete_pairing(&db, &media_signer, &access_signer, code, attrs)
        .await
        .expect_err("second pairing must fail");
    assert!(matches!(
        err,
        PairingError::Claim(mydia_rs_p2p::ClaimCodeError::AlreadyUsed)
    ));
}

/// Expired claim is rejected even on the first attempt.
#[tokio::test]
async fn expired_claim_is_rejected() {
    let (db, _tmp) = fresh_sqlite().await;
    let pool = db.as_sqlite().unwrap();
    let user_id = insert_user(&db).await;

    // Insert a claim that already expired five minutes ago.
    let past = Utc.with_ymd_and_hms(2020, 1, 1, 0, 0, 0).unwrap();
    let past_text = past.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    sqlx::query(
        "INSERT INTO pairing_claims \
         (id, code, user_id, expires_at, used_at, device_id, inserted_at, updated_at) \
         VALUES ($1, $2, $3, $4, NULL, NULL, $4, $4)",
    )
    .bind(Uuid::new_v4().to_string())
    .bind("EXPI-RED1")
    .bind(user_id.to_string())
    .bind(&past_text)
    .execute(pool)
    .await
    .unwrap();

    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let access_signer = AccessTokenSigner::new(SECRET, 2);
    let attrs = DeviceAttrs {
        device_name: "x".into(),
        platform: "android".into(),
    };
    let err = complete_pairing(&db, &media_signer, &access_signer, "EXPI-RED1", attrs)
        .await
        .expect_err("must reject expired claim");
    assert!(matches!(
        err,
        PairingError::Claim(mydia_rs_p2p::ClaimCodeError::Expired)
    ));
}

/// Media token validator: cache miss verifies JWT + loads device from
/// DB. Second request hits cache; revoking the device evicts the
/// cache synchronously.
#[tokio::test]
async fn media_token_cache_miss_then_hit_then_evict() {
    let (db, _tmp) = fresh_sqlite().await;
    let media_signer = MediaTokenSigner::new(SECRET, 2);
    let access_signer = AccessTokenSigner::new(SECRET, 2);

    let user_id = insert_user(&db).await;
    let code = "ABCD-CACH";
    insert_claim(&db, user_id, code, Duration::from_secs(300))
        .await
        .unwrap();
    let outcome = complete_pairing(
        &db,
        &media_signer,
        &access_signer,
        code,
        DeviceAttrs {
            device_name: "test".into(),
            platform: "android".into(),
        },
    )
    .await
    .unwrap();

    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let validator = MediaTokenValidator::new(media_signer.clone(), cache.clone(), db.clone());

    // First validate. cache miss; populates the entry.
    assert_eq!(cache.len(), 0);
    let validated = validator.validate(&outcome.media_token).await.unwrap();
    assert_eq!(validated.device.id.0, outcome.device.id.0);
    assert_eq!(cache.len(), 1);

    // Second validate. same token, same key. Cache hit.
    let _ = validator.validate(&outcome.media_token).await.unwrap();
    assert_eq!(cache.len(), 1);

    // Revoke the device synchronously. The next validate must fail
    // with DeviceRevoked, not return the cached entry.
    let pool = db.as_sqlite().unwrap();
    sqlx::query("UPDATE remote_devices SET revoked_at = $1 WHERE id = $2")
        .bind("2026-05-23T00:00:00Z")
        .bind(outcome.device.id.0.to_string())
        .execute(pool)
        .await
        .unwrap();
    validator.evict_device(&outcome.device.id.0.to_string());

    let err = validator
        .validate(&outcome.media_token)
        .await
        .expect_err("revoked device must fail");
    assert!(matches!(err, ValidationError::DeviceRevoked));
}

/// JWT issued by mydia-rs verifies against the same secret key (the
/// "Phoenix and mydia-rs share the Guardian secret" parity check).
#[tokio::test]
async fn media_token_verifies_against_separate_signer_instance() {
    let signer_a = MediaTokenSigner::new(SECRET, 2);
    let signer_b = MediaTokenSigner::new(SECRET, 2);

    let token = signer_a
        .issue(
            "device-1",
            "user-1",
            &[mydia_rs_auth::MediaTokenPermission::Stream],
            Duration::from_secs(300),
        )
        .unwrap();
    let claims = signer_b.verify(&token).expect("must verify under same key");
    assert_eq!(claims.sub, "device-1");
}

/// THE load-bearing concurrency test from the plan: 100 concurrent
/// failures from one IP with `max_attempts = 5` must produce exactly
/// 5 admitted attempts, never N+k. The Phoenix implementation can
/// lose this race.
#[tokio::test(flavor = "multi_thread", worker_threads = 8)]
async fn rate_limiter_admits_exactly_max_attempts_under_concurrency() {
    let limiter = Arc::new(ClaimRateLimiter::new(5, Duration::from_secs(60)));
    let mut handles = Vec::new();
    for _ in 0..100 {
        let limiter = limiter.clone();
        handles.push(tokio::task::spawn(async move {
            limiter.check_and_record_failure("attacker.example")
        }));
    }
    let mut admitted = 0;
    for h in handles {
        if h.await.unwrap() == RateLimitOutcome::Allowed {
            admitted += 1;
        }
    }
    assert_eq!(
        admitted, 5,
        "expected exactly 5 admitted attempts (max_attempts), got {admitted}"
    );
}

/// A request handler that calls a blocking-style Host method via
/// `spawn_blocking` completes within a reasonable time under
/// concurrent load and doesn't deadlock the runtime.
///
/// We can't easily exercise a real `mydia_p2p_core::Host` here
/// (network setup), so this models the equivalent shape: many
/// concurrent `spawn_blocking` calls into a synchronous, slow
/// operation, all called from async handlers. If the blocking
/// discipline were wrong (e.g. calling `.blocking_recv()` from an
/// async fn on a small worker pool), this would deadlock.
#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn many_spawn_blocking_calls_complete_under_load() {
    use std::sync::atomic::{AtomicU32, Ordering};
    use std::time::Duration as StdDuration;

    let counter = Arc::new(AtomicU32::new(0));
    let mut handles = Vec::new();
    for _ in 0..50 {
        let counter = counter.clone();
        handles.push(tokio::spawn(async move {
            // Each handler simulates the server's per-request task:
            // do something blocking inside spawn_blocking, then
            // continue on the async side.
            tokio::task::spawn_blocking(move || {
                std::thread::sleep(StdDuration::from_millis(10));
                counter.fetch_add(1, Ordering::SeqCst);
            })
            .await
            .unwrap();
        }));
    }

    // Bound the wait: even on 2 worker threads + the default
    // blocking pool (512 threads), 50 x 10ms calls finish under a
    // second; if we don't, something is wrong with the spawn_blocking
    // discipline.
    let result = tokio::time::timeout(StdDuration::from_secs(5), futures_join_all(handles)).await;
    assert!(result.is_ok(), "spawn_blocking calls hung");
    assert_eq!(counter.load(Ordering::SeqCst), 50);
}

/// Minimal helper since we don't want to pull `futures` as a dep just
/// for this. Awaits all join handles in order; on failure returns the
/// first error.
async fn futures_join_all<T>(handles: Vec<tokio::task::JoinHandle<T>>) -> Vec<T> {
    let mut results = Vec::with_capacity(handles.len());
    for h in handles {
        results.push(h.await.unwrap());
    }
    results
}
