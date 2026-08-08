//! GraphQL API surface for Mydia Server.
//!
//! The schema is declared in full from the first commit, with resolvers
//! stubbed and filled in by later slices. A partial schema would fail whole
//! player queries rather than individual fields.

pub mod context;
pub mod mutation;
pub mod query;
pub mod sdl;
pub mod subscription;
pub mod types;

use async_graphql::Schema;

use crate::context::ApiContext;
use crate::mutation::RootMutationType;
use crate::query::RootQueryType;
use crate::subscription::RootSubscriptionType;

pub type MydiaSchema = Schema<RootQueryType, RootMutationType, RootSubscriptionType>;

pub fn build_schema(ctx: ApiContext) -> MydiaSchema {
    Schema::build(RootQueryType, RootMutationType, RootSubscriptionType)
        .data(ctx)
        .finish()
}

/// Renders the schema as SDL without needing a database, for the parity gate.
pub fn schema_sdl() -> String {
    Schema::build(RootQueryType, RootMutationType, RootSubscriptionType)
        .finish()
        .sdl()
}
