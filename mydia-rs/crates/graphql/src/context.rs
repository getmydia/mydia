//! Per-request GraphQL context.
//!
//! Resolvers read shared state through async-graphql's
//! [`async_graphql::Context::data`] machinery rather than free-standing
//! globals. This module defines the seed values the schema is built
//! with ([`GraphqlAppState`] — long-lived, cloned once at boot) and the
//! per-request additions the axum handler attaches before executing
//! each operation ([`GraphqlRequestContext`]).
//!
//! Today the long-lived state is just the database handle. `PubSub`
//! (U15), the metadata-relay client (U18), and the JWT signer (U6
//! follow-up) are added through the same seam as those units land.

use std::sync::Arc;

use async_graphql::dataloader::DataLoader;
use mydia_rs_auth::role::Role;
use mydia_rs_db::DatabaseConnection;
use mydia_rs_pubsub::Pubsub;

/// Long-lived shared state seeded into every GraphQL request.
///
/// Cheap to clone: every field is either an `Arc`-backed pool or
/// trivially `Clone`. The schema builder embeds this once at startup
/// and the axum handler reuses it across requests.
#[derive(Clone)]
pub struct GraphqlAppState {
    pub db: DatabaseConnection,
    pub pubsub: Pubsub,
}

impl GraphqlAppState {
    /// Construct with a freshly-built `Pubsub`. Suitable for tests and
    /// the default boot path. Callers that need to inject a shared bus
    /// (e.g. workers publishing on the same instance) use
    /// [`GraphqlAppState::with_pubsub`].
    pub fn new(db: DatabaseConnection) -> Self {
        Self {
            db,
            pubsub: Pubsub::new(),
        }
    }

    /// Construct with an existing `Pubsub`. The workers crate (U15)
    /// passes its bus in here so workers and graphql subscribers
    /// reach the same broadcast channels.
    pub fn with_pubsub(db: DatabaseConnection, pubsub: Pubsub) -> Self {
        Self { db, pubsub }
    }
}

/// Identity attached to a GraphQL request.
///
/// `None` for unauthenticated calls (the login mutation, the public
/// schema introspection — anything explicitly allowed without auth).
/// Resolvers that require auth call `ctx.data::<Option<CurrentUser>>()`
/// and bail with [`async_graphql::Error`] when it's `None`.
#[derive(Debug, Clone)]
pub struct CurrentUser {
    pub id: uuid::Uuid,
    pub username: String,
    pub role: Role,
}

impl CurrentUser {
    pub fn is_admin(&self) -> bool {
        matches!(self.role, Role::Admin)
    }
}

/// Per-request additions the axum handler attaches before invoking
/// `Schema::execute`. The handler builds this from extractors (session
/// cookie, API-key header, media-token header) and merges it into the
/// `async_graphql::Request` via `Request::data`.
#[derive(Default)]
pub struct GraphqlRequestContext {
    pub current_user: Option<CurrentUser>,
}

impl GraphqlRequestContext {
    pub fn anonymous() -> Self {
        Self::default()
    }

    pub fn with_user(user: CurrentUser) -> Self {
        Self {
            current_user: Some(user),
        }
    }
}

/// Trait-object handle for the future `DataLoader<Foo>` family.
///
/// async-graphql's `DataLoader` is generic over its loader type, so
/// loaders are added one-per-type in later units. This re-export is
/// the documented entry point for those units.
pub type LoaderHandle<L> = Arc<DataLoader<L>>;
