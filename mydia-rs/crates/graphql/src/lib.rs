//! async-graphql surface for mydia-rs.
//!
//! Module layout:
//!
//! - [`schema`] — root Query / Mutation / Subscription types and the
//!   schema builder. Resolver families are merged via `MergedObject`.
//! - [`node_id`] — global ID encoding and decoding, byte-equivalent
//!   to `lib/mydia_web/schema/resolvers/node_id.ex`.
//! - [`relay`] — cursor helpers shaped like Phoenix's
//!   `BrowseResolver.encode_cursor/1` (base64 of `cursor:<offset>`).
//! - [`context`] — long-lived shared state ([`GraphqlAppState`]) and
//!   per-request additions ([`GraphqlRequestContext`]).
//! - [`axum_handler`] — mount points (`/api/graphql`,
//!   `/api/graphql/socket`, `/api/graphql/graphiql`).
//! - [`types`] — GraphQL type definitions (Movie, `TvShow`, Episode,
//!   Season, `LibraryPath`, `MediaFile`, Artwork, Progress, `PageInfo`
//!   and the *Connection / *Edge wrappers).
//! - [`queries`] — per-family resolver structs (`BrowseQueries`,
//!   `DiscoveryQueries`, ...). Each lands in a U10/U11/U14 unit.
//! - [`repos`] — DB query helpers ported from Phoenix's
//!   `Mydia.Media`, `Mydia.Settings`, `Mydia.Library`,
//!   `Mydia.Playback` context modules.

pub mod auth_guards;
pub mod axum_handler;
pub mod context;
pub mod metadata;
pub mod mutations;
pub mod node_id;
pub mod queries;
pub mod relay;
pub mod repos;
pub mod schema;
pub mod subscriptions;
pub mod types;

pub use axum_handler::router;
pub use context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
pub use node_id::{InvalidNodeId, NodeId, NodeRef};
pub use schema::{
    build_schema, build_schema_with_signer, schema_builder, MutationRoot, MydiaSchema, QueryRoot,
};
