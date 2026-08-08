//! Shared state carried through resolvers.

use async_graphql::ErrorExtensions;
use mydia_auth::tokens::Issuer;
use mydia_db::Db;

#[derive(Clone)]
pub struct ApiContext {
    pub db: Db,
    pub issuer: Issuer,
}

/// The error a stub resolver returns. Later slices replace each stub with a
/// real implementation; until then the player gets a clear, typed answer
/// rather than a panic or a silent null.
pub fn not_implemented(field: &str) -> async_graphql::Error {
    async_graphql::Error::new(format!("{field} is not available on this server yet"))
        .extend_with(|_, e| e.set("code", "NOT_IMPLEMENTED"))
}
