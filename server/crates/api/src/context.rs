//! Shared state carried through resolvers.

use async_graphql::{Context, Error, ErrorExtensions};
use mydia_auth::tokens::{Issuer, TokenKind};
use mydia_db::users::User;
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
pub fn not_implemented(field: &str) -> Error {
    Error::new(format!("{field} is not available on this server yet"))
        .extend_with(|_, e| e.set("code", "NOT_IMPLEMENTED"))
}

/// Resolves the caller from the request's bearer token, verified as an
/// access token. Every field that requires a logged-in caller goes through
/// this, so a missing token and an invalid one produce the same error.
pub async fn authenticated_user(ctx: &Context<'_>) -> async_graphql::Result<User> {
    let api = ctx.data::<ApiContext>()?;

    let token = ctx.data_opt::<BearerToken>().ok_or_else(unauthenticated)?;

    let claims = api
        .issuer
        .verify(&token.0, TokenKind::Access)
        .map_err(|_| unauthenticated())?;

    mydia_db::users::find_by_id(&api.db, &claims.sub)
        .await
        .map_err(|e| Error::new(e.to_string()))?
        .ok_or_else(unauthenticated)
}

fn unauthenticated() -> Error {
    Error::new("Authentication is required").extend_with(|_, e| e.set("code", "UNAUTHENTICATED"))
}
