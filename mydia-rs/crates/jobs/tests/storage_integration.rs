//! End-to-end checks for the apalis storage layer.
//!
//! These cover the U15 plan's "happy path" and "edge case" scenarios
//! that the unit tests inside `storage.rs` don't reach because they
//! exercise a real (in-memory) `SQLite` pool through the migration set.

use apalis::prelude::Storage;
use apalis_sql::sqlite::SqliteStorage;
use mydia_rs_db::Db;
use mydia_rs_jobs::{setup, JobStorage, Queue};
use serde::{Deserialize, Serialize};
use sqlx::sqlite::SqlitePoolOptions;

#[derive(Debug, Clone, Serialize, Deserialize)]
struct SmokeJob {
    payload: String,
    n: u32,
}

async fn sqlite_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(1)
        .connect("sqlite::memory:")
        .await
        .expect("open in-memory sqlite");
    Db::Sqlite(pool)
}

#[tokio::test]
async fn setup_is_idempotent() {
    let db = sqlite_db().await;
    setup(&db).await.expect("first setup");
    // Second invocation should not error; apalis-sql migrations are
    // idempotent and the boot path may call setup() once per process
    // restart against a long-lived DB.
    setup(&db).await.expect("second setup");
}

#[tokio::test]
async fn enqueued_jobs_are_visible_to_native_storage() {
    let db = sqlite_db().await;
    setup(&db).await.expect("setup");

    let mut storage: JobStorage<SmokeJob> = JobStorage::from_db(&db);
    let job = SmokeJob {
        payload: "scan library 5".to_owned(),
        n: 5,
    };
    let task_id = storage.push(job).await.expect("push");

    // Cross-check the apalis-sql native handle sees the same row.
    let pool = db.as_sqlite().expect("sqlite pool").clone();
    let mut native: SqliteStorage<SmokeJob> = SqliteStorage::new(pool);
    let len = native.len().await.expect("native len");
    assert_eq!(len, 1, "native storage observes pushed job");
    assert!(!task_id.is_empty(), "push returns a task id");
}

#[tokio::test]
async fn multiple_pushes_accumulate() {
    let db = sqlite_db().await;
    setup(&db).await.expect("setup");

    let mut storage: JobStorage<SmokeJob> = JobStorage::from_db(&db);
    for n in 0..5 {
        storage
            .push(SmokeJob {
                payload: format!("item {n}"),
                n,
            })
            .await
            .expect("push");
    }

    assert_eq!(storage.len().await.expect("len"), 5);
}

#[test]
fn queue_set_is_exhaustive() {
    // Sanity: every queue identity is accounted for. Catches a future
    // queue addition that forgets to register in `Queue::all()`.
    let queues: Vec<_> = Queue::all().collect();
    assert_eq!(queues.len(), 9);
    let total_concurrency: usize = queues.iter().map(|q| q.concurrency()).sum();
    // 10+5+3+2+2+1+1+2+2 = 28
    assert_eq!(total_concurrency, 28);
}
