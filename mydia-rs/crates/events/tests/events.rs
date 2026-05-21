//! Integration tests for the events crate.
//!
//! Each test boots an in-memory `SQLite` pool, applies a minimal
//! `events` table matching the Phoenix schema, and exercises the
//! crate's public surface end-to-end.

use std::sync::Arc;

use chrono::{Duration, Utc};
use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_db::Db;
use mydia_rs_events::{
    delete_old_events, ActorType, EventFilter, EventInput, EventsContext, Severity,
};
use mydia_rs_pubsub::Pubsub;
use sqlx::sqlite::SqlitePoolOptions;

const CREATE_EVENTS_SQL: &str = r"
CREATE TABLE events (
    id TEXT PRIMARY KEY NOT NULL,
    category TEXT NOT NULL,
    type TEXT NOT NULL,
    actor_type TEXT,
    actor_id TEXT,
    resource_type TEXT,
    resource_id TEXT,
    severity TEXT NOT NULL DEFAULT 'info',
    metadata TEXT,
    inserted_at TEXT NOT NULL
);
CREATE INDEX events_type ON events(type);
CREATE INDEX events_category ON events(category);
CREATE INDEX events_actor ON events(actor_type, actor_id);
CREATE INDEX events_resource ON events(resource_type, resource_id);
CREATE INDEX events_inserted_at ON events(inserted_at);
";

async fn fresh_db() -> Db {
    let pool = SqlitePoolOptions::new()
        .max_connections(2)
        .connect("sqlite::memory:")
        .await
        .unwrap();
    for stmt in CREATE_EVENTS_SQL
        .split(';')
        .filter(|s| !s.trim().is_empty())
    {
        sqlx::query(stmt).execute(&pool).await.unwrap();
    }
    Db::Sqlite(pool)
}

fn pubsub() -> Arc<Pubsub> {
    Arc::new(Pubsub::new())
}

#[tokio::test]
async fn record_and_query_round_trips() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db, pubsub());

    let input = EventInput::new("media", "media_item.added")
        .with_actor(ActorType::User, "11111111-1111-1111-1111-111111111111")
        .with_severity(Severity::Info)
        .with_metadata({
            let mut m = serde_json::Map::new();
            m.insert(
                "title".into(),
                serde_json::Value::String("Inception".into()),
            );
            m
        });

    let event = ctx.record(input).await.unwrap();
    assert_eq!(event.category, "media");
    assert_eq!(event.event_type, "media_item.added");
    assert_eq!(event.actor_type.as_deref(), Some("user"));

    let listed = ctx
        .query(EventFilter {
            category: Some("media".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(listed.len(), 1);
    assert_eq!(listed[0].event_type, "media_item.added");
}

#[tokio::test]
async fn filter_by_type_and_actor() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db, pubsub());

    ctx.record(EventInput::new("media", "media_item.added").with_actor(ActorType::User, "user-1"))
        .await
        .unwrap();
    ctx.record(
        EventInput::new("media", "media_item.removed")
            .with_actor(ActorType::Job, "metadata_refresh"),
    )
    .await
    .unwrap();

    let added = ctx
        .query(EventFilter {
            event_type: Some("media_item.added".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(added.len(), 1);
    assert_eq!(added[0].event_type, "media_item.added");

    let jobs = ctx
        .query(EventFilter {
            actor_type: Some(ActorType::Job),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(jobs.len(), 1);
    assert_eq!(jobs[0].actor_id.as_deref(), Some("metadata_refresh"));
}

#[tokio::test]
async fn filter_by_date_range_includes_only_in_window() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db.clone(), pubsub());

    // Insert a row directly with an old timestamp.
    let old_id = uuid::Uuid::new_v4();
    let old_ts = Utc::now() - Duration::days(10);
    sqlx::query(
        "INSERT INTO events (id, category, type, severity, metadata, inserted_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(mydia_rs_db::types::UuidText(old_id))
    .bind("media")
    .bind("media_item.added")
    .bind("info")
    .bind("{}")
    .bind(DateTimeSecs::from(old_ts))
    .execute(db.as_sqlite().unwrap())
    .await
    .unwrap();

    // Now record a fresh one.
    ctx.record(EventInput::new("media", "media_item.added"))
        .await
        .unwrap();

    let recent = ctx
        .query(EventFilter {
            since: Some(Utc::now() - Duration::days(1)),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(
        recent.len(),
        1,
        "only the just-recorded event should appear"
    );
}

#[tokio::test]
async fn count_matches_filtered_query() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db, pubsub());

    for _ in 0..3 {
        ctx.record(EventInput::new("media", "media_item.added"))
            .await
            .unwrap();
    }
    for _ in 0..2 {
        ctx.record(EventInput::new("downloads", "download.initiated"))
            .await
            .unwrap();
    }

    let media_count = ctx
        .count(EventFilter {
            category: Some("media".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(media_count, 3);
}

#[tokio::test]
async fn delete_old_events_removes_only_old_rows() {
    let db = fresh_db().await;

    // Old row.
    let old_ts = Utc::now() - Duration::days(60);
    sqlx::query(
        "INSERT INTO events (id, category, type, severity, metadata, inserted_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(mydia_rs_db::types::UuidText(uuid::Uuid::new_v4()))
    .bind("media")
    .bind("media_item.added")
    .bind("info")
    .bind("{}")
    .bind(DateTimeSecs::from(old_ts))
    .execute(db.as_sqlite().unwrap())
    .await
    .unwrap();

    // Recent row.
    sqlx::query(
        "INSERT INTO events (id, category, type, severity, metadata, inserted_at) \
         VALUES (?, ?, ?, ?, ?, ?)",
    )
    .bind(mydia_rs_db::types::UuidText(uuid::Uuid::new_v4()))
    .bind("media")
    .bind("media_item.added")
    .bind("info")
    .bind("{}")
    .bind(DateTimeSecs::from(Utc::now()))
    .execute(db.as_sqlite().unwrap())
    .await
    .unwrap();

    let deleted = delete_old_events(&db, 30).await.unwrap();
    assert_eq!(deleted, 1, "old row should be deleted, recent kept");

    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM events")
        .fetch_one(db.as_sqlite().unwrap())
        .await
        .unwrap();
    assert_eq!(count, 1);
}

#[tokio::test]
async fn delete_old_events_rejects_zero_retention() {
    let db = fresh_db().await;
    let err = delete_old_events(&db, 0).await.unwrap_err();
    assert!(format!("{err}").contains("retention"));
}

/// SQLite-specific: concurrent inserts from two tasks both succeed
/// (the in-process pool serializes through one connection at a time
/// when the DB is busy).
#[tokio::test]
async fn concurrent_inserts_succeed_on_sqlite() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db.clone(), pubsub());

    let h1 = {
        let ctx = ctx.clone();
        tokio::spawn(async move {
            for i in 0..5 {
                ctx.record(EventInput::new("media", "media_item.added").with_metadata({
                    let mut m = serde_json::Map::new();
                    m.insert("seq".into(), serde_json::Value::from(i));
                    m
                }))
                .await
                .unwrap();
            }
        })
    };
    let h2 = {
        let ctx = ctx.clone();
        tokio::spawn(async move {
            for i in 0..5 {
                ctx.record(
                    EventInput::new("downloads", "download.initiated").with_metadata({
                        let mut m = serde_json::Map::new();
                        m.insert("seq".into(), serde_json::Value::from(i));
                        m
                    }),
                )
                .await
                .unwrap();
            }
        })
    };

    h1.await.unwrap();
    h2.await.unwrap();

    let total = ctx.count(EventFilter::default()).await.unwrap();
    assert_eq!(total, 10);
}

#[tokio::test]
async fn record_broadcasts_on_events_all_topic() {
    let db = fresh_db().await;
    let bus = pubsub();
    let ctx = EventsContext::new(db, bus.clone());
    let mut rx = bus.subscribe(mydia_rs_pubsub::topics::EVENTS_ALL);

    ctx.record(EventInput::new("media", "media_item.added"))
        .await
        .unwrap();
    let event = tokio::time::timeout(std::time::Duration::from_millis(200), rx.recv())
        .await
        .expect("timeout waiting for broadcast")
        .expect("recv");
    assert_eq!(event.payload["type"], "media_item.added");
}

#[tokio::test]
async fn invalid_event_type_is_rejected_before_insert() {
    let db = fresh_db().await;
    let ctx = EventsContext::new(db, pubsub());
    let err = ctx
        .record(EventInput::new("media", "no-dot"))
        .await
        .unwrap_err();
    assert!(format!("{err}").contains("event type"));
}
