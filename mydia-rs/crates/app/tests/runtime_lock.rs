//! Integration tests for the boot-time mutual exclusion lock.
//!
//! `SQLite` path covered end-to-end via tempfile DBs. Postgres path is
//! gated on `DATABASE_URL` the same way the db crate's `postgres_smoke`
//! tests are; the CI matrix exercises it.

use std::path::{Path, PathBuf};
use std::time::Duration;

use mydia_rs_app::runtime_lock::{self, RuntimeLockError};
use mydia_rs_config::{Config, DatabaseConfig, DatabaseType};
use mydia_rs_db::{connect_from_config, Db};
use tempfile::TempDir;

fn sqlite_config(path: &Path) -> Config {
    Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Sqlite,
            url: None,
            path: Some(path.to_string_lossy().into_owned()),
            pool_size: 4,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    }
}

async fn fresh_sqlite_pool() -> (Db, TempDir, PathBuf) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let path = tmp.path().join("lock.db");
    let cfg = sqlite_config(&path);
    let db = connect_from_config(&cfg).await.expect("connect");
    (db, tmp, path)
}

async fn pool_for(path: &Path) -> Db {
    let cfg = sqlite_config(path);
    connect_from_config(&cfg).await.expect("connect")
}

#[tokio::test]
async fn acquire_succeeds_on_fresh_database() {
    let (db, _tmp, _path) = fresh_sqlite_pool().await;
    let lock = runtime_lock::acquire(&db).await.expect("acquire");
    lock.release().await.expect("release");
}

#[tokio::test]
async fn second_acquire_against_same_db_refuses() {
    let (db1, _tmp, path) = fresh_sqlite_pool().await;
    let lock = runtime_lock::acquire(&db1).await.expect("first acquire");

    let db2 = pool_for(&path).await;
    let err = runtime_lock::acquire(&db2)
        .await
        .expect_err("second must fail");
    assert!(matches!(err, RuntimeLockError::Held));

    lock.release().await.expect("release");
}

#[tokio::test]
async fn release_lets_competitor_acquire_immediately() {
    let (db1, _tmp, path) = fresh_sqlite_pool().await;
    let lock = runtime_lock::acquire(&db1).await.expect("first acquire");
    lock.release().await.expect("release");

    let db2 = pool_for(&path).await;
    let next = runtime_lock::acquire(&db2).await.expect("second acquire");
    next.release().await.expect("release");
}

#[tokio::test]
async fn stale_heartbeat_is_swept_and_lock_can_be_reclaimed() {
    let (db1, _tmp, path) = fresh_sqlite_pool().await;
    let _lock = runtime_lock::acquire(&db1).await.expect("first acquire");

    // Simulate a stale heartbeat from a crashed peer by reaching into
    // the lock row and backdating it past the STALE_AFTER window.
    let pool = db1.as_sqlite().expect("sqlite");
    sqlx::query(
        "UPDATE mydia_runtime_lock
            SET heartbeat_at = '2000-01-01T00:00:00Z'
            WHERE lock_key = 'mydia-rs-singleton'",
    )
    .execute(pool)
    .await
    .expect("backdate");

    let db2 = pool_for(&path).await;
    let reclaimed = runtime_lock::acquire(&db2).await.expect("reclaim");
    reclaimed.release().await.expect("release");
}

#[tokio::test]
async fn drop_without_release_leaves_row_until_stale() {
    let (db1, _tmp, path) = fresh_sqlite_pool().await;
    {
        let _lock = runtime_lock::acquire(&db1).await.expect("acquire");
        // Drop without release.
    }
    // Give the abort-on-drop a chance to settle.
    tokio::time::sleep(Duration::from_millis(50)).await;

    let db2 = pool_for(&path).await;
    let err = runtime_lock::acquire(&db2)
        .await
        .expect_err("row still fresh");
    assert!(matches!(err, RuntimeLockError::Held));
}

#[tokio::test]
async fn release_is_safe_to_call_after_normal_lifetime() {
    let (db, _tmp, _path) = fresh_sqlite_pool().await;
    let lock = runtime_lock::acquire(&db).await.expect("acquire");
    lock.release().await.expect("release ok");
}

// ---- Postgres path (gated on DATABASE_URL) ----

fn postgres_url() -> Option<String> {
    std::env::var("DATABASE_URL")
        .ok()
        .filter(|u| u.starts_with("postgres://") || u.starts_with("postgresql://"))
}

async fn postgres_pool() -> Option<Db> {
    let url = postgres_url()?;
    let cfg = Config {
        database: DatabaseConfig {
            db_type: DatabaseType::Postgres,
            url: Some(url),
            path: None,
            pool_size: 4,
            ..DatabaseConfig::default()
        },
        ..Config::default()
    };
    connect_from_config(&cfg).await.ok()
}

#[tokio::test]
async fn postgres_advisory_lock_held_then_released() {
    let Some(db1) = postgres_pool().await else {
        return;
    };
    let lock = runtime_lock::acquire(&db1).await.expect("first acquire");

    let Some(db2) = postgres_pool().await else {
        return;
    };
    let err = runtime_lock::acquire(&db2)
        .await
        .expect_err("second must fail");
    assert!(matches!(err, RuntimeLockError::Held));

    lock.release().await.expect("release");

    let Some(db3) = postgres_pool().await else {
        return;
    };
    let third = runtime_lock::acquire(&db3).await.expect("after release");
    third.release().await.expect("release");
}
