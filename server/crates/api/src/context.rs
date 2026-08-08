//! Shared state carried through resolvers.

use async_graphql::ErrorExtensions;
use mydia_auth::tokens::Issuer;
use mydia_db::Db;

#[derive(Clone)]
pub struct ApiContext {
    pub db: Db,
    pub issuer: Issuer,
}

/// A bearer token exactly as the client presented it, not yet verified.
/// Declared here rather than in the server crate so resolvers can name the
/// type without the api crate depending on the binary.
#[derive(Clone)]
pub struct BearerToken(pub String);

/// The error a stub resolver returns. Later slices replace each stub with a
/// real implementation; until then the player gets a clear, typed answer
/// rather than a panic or a silent null.
pub fn not_implemented(field: &str) -> async_graphql::Error {
    async_graphql::Error::new(format!("{field} is not available on this server yet"))
        .extend_with(|_, e| e.set("code", "NOT_IMPLEMENTED"))
}
