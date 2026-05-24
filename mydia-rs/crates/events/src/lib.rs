//! Events context.
//!
//! Port of `lib/mydia/events.ex` (the 1.5k-LOC context module) plus
//! the supporting structs under `lib/mydia/events/`. Phoenix's
//! `Mydia.Events` is the single write-and-query surface for audit
//! events the activity-page `LiveView` reads from; the Rust port keeps
//! the same shape with a thin `record/2` / `query/1` surface and the
//! taxonomy enums on the side.
//!
//! Modules:
//!
//! - [`taxonomy`] — `Category`, `EventType`, `ActorType`, `Severity`
//!   enums and the canonical string values they round-trip to.
//! - [`persistence`] — SeaORM-backed CRUD against the `events` table.
//! - [`retention`] — `delete_old_events(retention_days)` used by U17's
//!   `EventCleanup` worker.
//!
//! The crate stays adapter-only: it does not depend on the actual
//! `MediaItem` / `Download` structs from `mydia_rs_models`, since the
//! Phoenix code constructs the payload at the call site (a map of
//! string keys) anyway. The Rust port mirrors that — every public
//! recording API takes a [`taxonomy::EventInput`] which carries the
//! pre-constructed JSON payload.

pub mod persistence;
pub mod retention;
pub mod taxonomy;

use std::sync::Arc;

use sea_orm::DatabaseConnection;
use tracing::{debug, error};

use mydia_rs_pubsub::{topics, Event as PubsubEvent, Pubsub};

pub use persistence::{Event, EventFilter, EventsError};
pub use retention::delete_old_events;
pub use taxonomy::{ActorType, Category, EventInput, Severity};

/// Shared handle the resolvers and workers thread through. Holds the
/// DB pool and the in-process pubsub bus.
#[derive(Clone)]
pub struct EventsContext {
    db: DatabaseConnection,
    pubsub: Arc<Pubsub>,
}

impl EventsContext {
    pub fn new(db: DatabaseConnection, pubsub: Arc<Pubsub>) -> Self {
        Self { db, pubsub }
    }

    /// Record an event synchronously: persist to the DB then broadcast
    /// on the `events:all` pubsub topic.
    ///
    /// Mirrors `Mydia.Events.create_event/1`. Errors propagate up to
    /// the caller — call sites that want fire-and-forget should use
    /// [`Self::record_async`].
    pub async fn record(&self, input: EventInput) -> Result<Event, EventsError> {
        let event = persistence::insert_event(&self.db, input).await?;
        self.broadcast(&event);
        Ok(event)
    }

    /// Record an event asynchronously: spawn a `tokio::task` that
    /// handles persist + broadcast, returning immediately.
    ///
    /// Mirrors `Mydia.Events.create_event_async/1`. Logs errors via
    /// `tracing::error!` instead of returning them.
    pub fn record_async(&self, input: EventInput) {
        let this = self.clone();
        tokio::spawn(async move {
            match this.record(input).await {
                Ok(event) => debug!(?event.event_type, "event recorded asynchronously"),
                Err(err) => error!(?err, "failed to record event asynchronously"),
            }
        });
    }

    /// List events matching `filter`. Mirrors `Mydia.Events.list_events/1`.
    pub async fn query(&self, filter: EventFilter) -> Result<Vec<Event>, EventsError> {
        persistence::list_events(&self.db, &filter).await
    }

    /// Count events matching `filter`. Mirrors `Mydia.Events.count_events/1`.
    pub async fn count(&self, filter: EventFilter) -> Result<i64, EventsError> {
        persistence::count_events(&self.db, &filter).await
    }

    /// Borrow the underlying DB handle. Workers use this for
    /// transactions that span events + other tables.
    pub fn db(&self) -> &DatabaseConnection {
        &self.db
    }

    fn broadcast(&self, event: &Event) {
        let payload = match serde_json::to_value(event) {
            Ok(v) => v,
            Err(err) => {
                error!(?err, "failed to serialize event for pubsub");
                return;
            }
        };
        self.pubsub
            .publish(topics::EVENTS_ALL, PubsubEvent::from_json(payload));
    }
}
