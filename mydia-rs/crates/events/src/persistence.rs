//! sqlx-backed persistence for the `events` table.
//!
//! The schema lives in `priv/repo/migrations/20251106191246_create_events.exs`
//! and `priv/repo/migrations/20251125032719_change_event_actor_id_to_string.exs`.
//! Columns:
//!
//! | column          | type               | notes                                 |
//! |-----------------|--------------------|---------------------------------------|
//! | `id`            | `UUID` (`binary_id`) | TEXT on `SQLite`, native `uuid` on PG |
//! | `category`      | string             | required                              |
//! | `type`          | string             | required, validated `^[a-z_]+\.[...]` |
//! | `actor_type`    | string             | nullable                              |
//! | `actor_id`      | string             | nullable (`UUID`-as-text or descriptor) |
//! | `resource_type` | string             | nullable                              |
//! | `resource_id`   | `UUID` (`binary_id`) | nullable                              |
//! | `severity`      | string             | `info` / `warning` / `error`          |
//! | `metadata`      | text (JSON)        | always JSON; `'{}'` when empty        |
//! | `inserted_at`   | `utc_datetime`     | seconds precision                     |
//!
//! mydia-rs writes the same shape so Phoenix and mydia-rs round-trip
//! events transparently during the parallel window.

use chrono::{DateTime, Utc};
use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use mydia_rs_db::Db;
use serde::{Deserialize, Serialize};
use sqlx::{Postgres, QueryBuilder, Sqlite};
use thiserror::Error;
use tracing::warn;
use uuid::Uuid;

use crate::taxonomy::{ActorType, EventInput, Severity, TaxonomyError};

const COLUMNS: &str =
    "id, category, type, actor_type, actor_id, resource_type, resource_id, severity, metadata, \
     inserted_at";

/// One row from the `events` table.
#[derive(Debug, Clone, Serialize, Deserialize, sqlx::FromRow)]
pub struct Event {
    pub id: UuidText,
    pub category: String,
    #[sqlx(rename = "type")]
    #[serde(rename = "type")]
    pub event_type: String,
    pub actor_type: Option<String>,
    pub actor_id: Option<String>,
    pub resource_type: Option<String>,
    pub resource_id: Option<UuidText>,
    pub severity: String,
    pub metadata: JsonMap<serde_json::Value>,
    pub inserted_at: DateTimeSecs,
}

impl Event {
    /// Convenience accessor for the typed [`Severity`].
    #[must_use]
    pub fn severity_enum(&self) -> Severity {
        Severity::parse(&self.severity).unwrap_or_default()
    }

    /// Convenience accessor for the typed [`ActorType`].
    #[must_use]
    pub fn actor_type_enum(&self) -> Option<ActorType> {
        self.actor_type.as_deref().and_then(ActorType::parse)
    }
}

/// Filters the resolver / activity feed pass to `query`. Mirrors the
/// keyword opts `Mydia.Events.list_events/1` accepts.
#[derive(Debug, Clone, Default)]
pub struct EventFilter {
    pub category: Option<String>,
    pub event_type: Option<String>,
    pub actor_type: Option<ActorType>,
    pub actor_id: Option<String>,
    pub resource_type: Option<String>,
    pub resource_id: Option<String>,
    pub severity: Option<Severity>,
    pub since: Option<DateTime<Utc>>,
    pub until: Option<DateTime<Utc>>,
    pub limit: Option<i64>,
    pub offset: Option<i64>,
}

/// Crate-level error type.
#[derive(Debug, Error)]
pub enum EventsError {
    #[error(transparent)]
    Db(#[from] sqlx::Error),
    #[error(transparent)]
    Taxonomy(#[from] TaxonomyError),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
}

/// Insert one row and return the persisted [`Event`].
///
/// Mirrors `Mydia.Events.create_event/1`. Caller is responsible for
/// dispatching the pubsub broadcast — done by [`crate::EventsContext::record`].
pub async fn insert_event(db: &Db, input: EventInput) -> Result<Event, EventsError> {
    input.validate()?;
    let id = Uuid::new_v4();
    let inserted_at = DateTimeSecs::from(Utc::now());
    let metadata = JsonMap::new(serde_json::Value::Object(input.metadata.clone()));

    match db {
        Db::Sqlite(pool) => {
            let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("INSERT INTO events (");
            qb.push(COLUMNS);
            qb.push(") VALUES (");
            qb.push_bind(UuidText(id));
            qb.push(", ").push_bind(input.category.clone());
            qb.push(", ").push_bind(input.event_type.clone());
            qb.push(", ")
                .push_bind(input.actor_type.map(|a| a.as_str().to_owned()));
            qb.push(", ").push_bind(input.actor_id.clone());
            qb.push(", ").push_bind(input.resource_type.clone());
            qb.push(", ").push_bind(
                input
                    .resource_id
                    .as_deref()
                    .and_then(|s| Uuid::parse_str(s).ok())
                    .map(UuidText),
            );
            qb.push(", ").push_bind(input.severity.as_str().to_owned());
            qb.push(", ").push_bind(metadata);
            qb.push(", ").push_bind(inserted_at);
            qb.push(")");
            qb.build().execute(pool).await?;
        }
        Db::Postgres(pool) => {
            let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("INSERT INTO events (");
            qb.push(COLUMNS);
            qb.push(") VALUES (");
            qb.push_bind(UuidText(id));
            qb.push(", ").push_bind(input.category.clone());
            qb.push(", ").push_bind(input.event_type.clone());
            qb.push(", ")
                .push_bind(input.actor_type.map(|a| a.as_str().to_owned()));
            qb.push(", ").push_bind(input.actor_id.clone());
            qb.push(", ").push_bind(input.resource_type.clone());
            qb.push(", ").push_bind(
                input
                    .resource_id
                    .as_deref()
                    .and_then(|s| Uuid::parse_str(s).ok())
                    .map(UuidText),
            );
            qb.push(", ").push_bind(input.severity.as_str().to_owned());
            qb.push(", ").push_bind(metadata);
            qb.push(", ").push_bind(inserted_at);
            qb.push(")");
            qb.build().execute(pool).await?;
        }
    }

    // Read it back so the caller gets the persisted row (Phoenix's
    // `Repo.insert` returns the inserted struct).
    let filter = EventFilter {
        limit: Some(1),
        ..Default::default()
    };
    let rows = list_events_by_id(db, id, &filter).await?;
    rows.into_iter()
        .next()
        .ok_or_else(|| EventsError::Db(sqlx::Error::RowNotFound))
}

async fn list_events_by_id(
    db: &Db,
    id: Uuid,
    _filter: &EventFilter,
) -> Result<Vec<Event>, EventsError> {
    match db {
        Db::Sqlite(pool) => {
            let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("SELECT ");
            qb.push(COLUMNS);
            qb.push(" FROM events WHERE id = ");
            qb.push_bind(UuidText(id));
            let rows = qb.build_query_as::<Event>().fetch_all(pool).await?;
            Ok(rows)
        }
        Db::Postgres(pool) => {
            let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("SELECT ");
            qb.push(COLUMNS);
            qb.push(" FROM events WHERE id = ");
            qb.push_bind(UuidText(id));
            let rows = qb.build_query_as::<Event>().fetch_all(pool).await?;
            Ok(rows)
        }
    }
}

/// List events matching `filter`, ordered by `inserted_at` DESC then
/// `id` DESC. Default limit is 50.
pub async fn list_events(db: &Db, filter: &EventFilter) -> Result<Vec<Event>, EventsError> {
    let limit = filter.limit.unwrap_or(50);
    let offset = filter.offset.unwrap_or(0);
    match db {
        Db::Sqlite(pool) => {
            let mut qb: QueryBuilder<Sqlite> = QueryBuilder::new("SELECT ");
            qb.push(COLUMNS);
            qb.push(" FROM events WHERE 1=1");
            apply_filters_sqlite(&mut qb, filter);
            qb.push(" ORDER BY inserted_at DESC, id DESC");
            qb.push(" LIMIT ").push_bind(limit);
            qb.push(" OFFSET ").push_bind(offset);
            let rows = qb.build_query_as::<Event>().fetch_all(pool).await?;
            Ok(rows)
        }
        Db::Postgres(pool) => {
            let mut qb: QueryBuilder<Postgres> = QueryBuilder::new("SELECT ");
            qb.push(COLUMNS);
            qb.push(" FROM events WHERE 1=1");
            apply_filters_postgres(&mut qb, filter);
            qb.push(" ORDER BY inserted_at DESC, id DESC");
            qb.push(" LIMIT ").push_bind(limit);
            qb.push(" OFFSET ").push_bind(offset);
            let rows = qb.build_query_as::<Event>().fetch_all(pool).await?;
            Ok(rows)
        }
    }
}

/// Count events matching `filter`.
pub async fn count_events(db: &Db, filter: &EventFilter) -> Result<i64, EventsError> {
    match db {
        Db::Sqlite(pool) => {
            let mut qb: QueryBuilder<Sqlite> =
                QueryBuilder::new("SELECT COUNT(*) FROM events WHERE 1=1");
            apply_filters_sqlite(&mut qb, filter);
            let count: (i64,) = qb.build_query_as().fetch_one(pool).await?;
            Ok(count.0)
        }
        Db::Postgres(pool) => {
            let mut qb: QueryBuilder<Postgres> =
                QueryBuilder::new("SELECT COUNT(*) FROM events WHERE 1=1");
            apply_filters_postgres(&mut qb, filter);
            let count: (i64,) = qb.build_query_as().fetch_one(pool).await?;
            Ok(count.0)
        }
    }
}

fn apply_filters_sqlite(qb: &mut QueryBuilder<'_, Sqlite>, filter: &EventFilter) {
    if let Some(v) = filter.category.as_deref() {
        qb.push(" AND category = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.event_type.as_deref() {
        qb.push(" AND type = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.actor_type {
        qb.push(" AND actor_type = ")
            .push_bind(v.as_str().to_owned());
    }
    if let Some(v) = filter.actor_id.as_deref() {
        qb.push(" AND actor_id = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.resource_type.as_deref() {
        qb.push(" AND resource_type = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.resource_id.as_deref() {
        if let Ok(uuid) = Uuid::parse_str(v) {
            qb.push(" AND resource_id = ").push_bind(UuidText(uuid));
        } else {
            warn!(value = %v, "ignoring resource_id filter; not a valid UUID");
        }
    }
    if let Some(v) = filter.severity {
        qb.push(" AND severity = ").push_bind(v.as_str().to_owned());
    }
    if let Some(since) = filter.since {
        qb.push(" AND inserted_at >= ")
            .push_bind(DateTimeSecs::from(since));
    }
    if let Some(until) = filter.until {
        qb.push(" AND inserted_at <= ")
            .push_bind(DateTimeSecs::from(until));
    }
}

fn apply_filters_postgres(qb: &mut QueryBuilder<'_, Postgres>, filter: &EventFilter) {
    if let Some(v) = filter.category.as_deref() {
        qb.push(" AND category = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.event_type.as_deref() {
        qb.push(" AND type = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.actor_type {
        qb.push(" AND actor_type = ")
            .push_bind(v.as_str().to_owned());
    }
    if let Some(v) = filter.actor_id.as_deref() {
        qb.push(" AND actor_id = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.resource_type.as_deref() {
        qb.push(" AND resource_type = ").push_bind(v.to_owned());
    }
    if let Some(v) = filter.resource_id.as_deref() {
        if let Ok(uuid) = Uuid::parse_str(v) {
            qb.push(" AND resource_id = ").push_bind(UuidText(uuid));
        } else {
            warn!(value = %v, "ignoring resource_id filter; not a valid UUID");
        }
    }
    if let Some(v) = filter.severity {
        qb.push(" AND severity = ").push_bind(v.as_str().to_owned());
    }
    if let Some(since) = filter.since {
        qb.push(" AND inserted_at >= ")
            .push_bind(DateTimeSecs::from(since));
    }
    if let Some(until) = filter.until {
        qb.push(" AND inserted_at <= ")
            .push_bind(DateTimeSecs::from(until));
    }
}
