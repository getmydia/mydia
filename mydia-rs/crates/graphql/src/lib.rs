//! async-graphql surface for mydia-rs.
//!
//! U8 establishes the scaffolding:
//!
//! - [`schema`] — root Query / Mutation / Subscription types and the
//!   schema builder. Today the roots are minimal stubs that prove the
//!   pipeline works; resolver families ship in U10, U11, U12, U14.
//! - [`node_id`] — global ID encoding and decoding, byte-equivalent to
//!   `lib/mydia_web/schema/resolvers/node_id.ex`.
//! - [`relay`] — cursor helpers shaped like Absinthe Relay's output, so
//!   the Flutter player's saved cursors round-trip across the parallel
//!   window.
//! - [`context`] — long-lived shared state ([`GraphqlAppState`]) and
//!   per-request additions ([`GraphqlRequestContext`]) the axum
//!   handler attaches before executing each operation.
//! - [`axum_handler`] — mount points (`/api/graphql`,
//!   `/api/graphql/socket`, `/api/graphql/graphiql`).
//!
//! Resolver units extend [`schema::QueryRoot`] and
//! [`schema::MutationRoot`] with additional `#[Object]` impls;
//! async-graphql merges them at schema-build time.

pub mod axum_handler;
pub mod context;
pub mod node_id;
pub mod relay;
pub mod schema;

pub use axum_handler::router;
pub use context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
pub use node_id::{InvalidNodeId, NodeId, NodeRef};
pub use schema::{build_schema, schema_builder, MutationRoot, MydiaSchema, QueryRoot};
