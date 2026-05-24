//! SeaORM-backed persistence for the `events` table.
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
//!
//! Post-U8 cutover: SeaORM-native. Dynamic filter assembly is built
//! through `Condition::all()` rather than `sqlx::QueryBuilder`. Inserts
//! flow through `mydia_rs_db::insert_active_model` so the wrapper-typed
//! `id` / `resource_id` / `inserted_at` columns get the right Postgres
//! casts.

use chrono::{DateTime, Utc};
use sea_orm::entity::prelude::*;
use sea_orm::query::{QueryOrder, QuerySelect};
use sea_orm::sea_query::{Condition, Expr, ExprTrait};
use sea_orm::{DatabaseConnection, Set};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tracing::warn;
use uuid::Uuid;

use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use mydia_rs_entities::events;

use crate::taxonomy::{ActorType, EventInput, Severity, TaxonomyError};

/// One row from the `events` table.
///
/// The on-disk `metadata` column is TEXT-holding-JSON on both engines
/// (Phoenix's events context never reaches for `jsonb`, since callers
/// query the column for presence rather than nested extraction). The
/// public surface decodes that string into a `serde_json::Value` via
/// the `JsonMap` wrapper so consumers can treat it as structured data
/// without re-parsing at every call site.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Event {
    pub id: UuidText,
    pub category: String,
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

impl From<events::Model> for Event {
    fn from(m: events::Model) -> Self {
        // `metadata` is text-holding-JSON on disk; Phoenix writes
        // `'{}'` when empty so we treat a missing/invalid payload as an
        // empty object rather than surfacing a parse error to callers.
        let metadata_value = m.metadata.as_deref().map_or_else(
            || serde_json::Value::Object(serde_json::Map::default()),
            |s| {
                serde_json::from_str(s)
                    .unwrap_or_else(|_| serde_json::Value::Object(serde_json::Map::default()))
            },
        );
        Self {
            id: m.id,
            category: m.category,
            event_type: m.r#type,
            actor_type: m.actor_type,
            actor_id: m.actor_id,
            resource_type: m.resource_type,
            resource_id: m.resource_id,
            severity: m.severity,
            metadata: JsonMap::new(metadata_value),
            inserted_at: m.inserted_at,
        }
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
    Db(#[from] DbErr),
    #[error(transparent)]
    Taxonomy(#[from] TaxonomyError),
    #[error("serde error: {0}")]
    Serde(#[from] serde_json::Error),
}

/// Insert one row and return the persisted [`Event`].
///
/// Mirrors `Mydia.Events.create_event/1`. Caller is responsible for
/// dispatching the pubsub broadcast — done by [`crate::EventsContext::record`].
pub async fn insert_event(
    db: &DatabaseConnection,
    input: EventInput,
) -> Result<Event, EventsError> {
    input.validate()?;

    let id = UuidText(Uuid::new_v4());
    let inserted_at = DateTimeSecs::from(Utc::now());
    let metadata_json = serde_json::Value::Object(input.metadata.clone());
    // Phoenix stores `'{}'` (TEXT) when the metadata map is empty. The
    // entity column is `Option<String>` (Text), so we marshal to string
    // up front rather than going through `JsonMap`'s `into_simple_expr`
    // (the column type is plain TEXT on both engines, not `jsonb`).
    let metadata_text = serde_json::to_string(&metadata_json)?;

    let resource_id_uuid = input
        .resource_id
        .as_deref()
        .and_then(|s| Uuid::parse_str(s).ok())
        .map(UuidText);

    let am = events::ActiveModel {
        id: Set(id),
        category: Set(input.category.clone()),
        r#type: Set(input.event_type.clone()),
        actor_type: Set(input.actor_type.map(|a| a.as_str().to_owned())),
        actor_id: Set(input.actor_id.clone()),
        resource_type: Set(input.resource_type.clone()),
        resource_id: Set(resource_id_uuid),
        severity: Set(input.severity.as_str().to_owned()),
        metadata: Set(Some(metadata_text)),
        inserted_at: Set(inserted_at),
    };

    let model = mydia_rs_db::insert_active_model(am, db).await?;
    Ok(Event::from(model))
}

/// List events matching `filter`, ordered by `inserted_at` DESC then
/// `id` DESC. Default limit is 50.
pub async fn list_events(
    db: &DatabaseConnection,
    filter: &EventFilter,
) -> Result<Vec<Event>, EventsError> {
    let limit = filter.limit.unwrap_or(50);
    let offset = filter.offset.unwrap_or(0);
    let condition = filter_condition(db, filter);

    let models = events::Entity::find()
        .filter(condition)
        .order_by_desc(events::Column::InsertedAt)
        .order_by_desc(events::Column::Id)
        .limit(limit as u64)
        .offset(offset as u64)
        .all(db)
        .await?;

    Ok(models.into_iter().map(Event::from).collect())
}

/// Count events matching `filter`.
pub async fn count_events(
    db: &DatabaseConnection,
    filter: &EventFilter,
) -> Result<i64, EventsError> {
    let condition = filter_condition(db, filter);

    // `Entity::find().filter(...).count()` returns u64; the public API
    // exposes i64 (Phoenix returns an integer) so cast after the await.
    let count = events::Entity::find().filter(condition).count(db).await?;
    Ok(count as i64)
}

/// Translate an [`EventFilter`] into a `SeaORM` `Condition` that ANDs
/// together every non-`None` predicate.
///
/// Wrapper-typed columns (`resource_id` is `UuidText`; `inserted_at` is
/// `DateTimeSecs`) route their bind through `into_simple_expr(backend)`
/// so Postgres gets the `::uuid` / `::timestamptz` cast on the parameter
/// and `SQLite` gets the plain TEXT bind. Plain TEXT columns
/// (`category`, `type`, `severity`, ...) flow through `ColumnTrait::eq`
/// directly.
fn filter_condition(db: &DatabaseConnection, filter: &EventFilter) -> Condition {
    let backend = db.get_database_backend();
    let mut cond = Condition::all();

    if let Some(v) = filter.category.as_deref() {
        cond = cond.add(events::Column::Category.eq(v.to_owned()));
    }
    if let Some(v) = filter.event_type.as_deref() {
        cond = cond.add(events::Column::Type.eq(v.to_owned()));
    }
    if let Some(v) = filter.actor_type {
        cond = cond.add(events::Column::ActorType.eq(v.as_str().to_owned()));
    }
    if let Some(v) = filter.actor_id.as_deref() {
        cond = cond.add(events::Column::ActorId.eq(v.to_owned()));
    }
    if let Some(v) = filter.resource_type.as_deref() {
        cond = cond.add(events::Column::ResourceType.eq(v.to_owned()));
    }
    if let Some(v) = filter.resource_id.as_deref() {
        if let Ok(uuid) = Uuid::parse_str(v) {
            let wrapper = UuidText(uuid);
            cond = cond
                .add(Expr::col(events::Column::ResourceId).eq(wrapper.into_simple_expr(backend)));
        } else {
            warn!(value = %v, "ignoring resource_id filter; not a valid UUID");
        }
    }
    if let Some(v) = filter.severity {
        cond = cond.add(events::Column::Severity.eq(v.as_str().to_owned()));
    }
    if let Some(since) = filter.since {
        let wrapper = DateTimeSecs::from(since);
        cond =
            cond.add(Expr::col(events::Column::InsertedAt).gte(wrapper.into_simple_expr(backend)));
    }
    if let Some(until) = filter.until {
        let wrapper = DateTimeSecs::from(until);
        cond =
            cond.add(Expr::col(events::Column::InsertedAt).lte(wrapper.into_simple_expr(backend)));
    }

    cond
}

// Note: the `events.metadata` column is plain TEXT on both engines (not
// `jsonb` on Postgres — see `priv/repo/migrations/20251106191246_create_events.exs`).
// Routing through `JsonMap`'s `TryGetable` would mis-parse on Postgres
// because the wrapper's Postgres branch reads a native `serde_json::Value`.
// The conversion lives in `From<events::Model> for Event` instead.
