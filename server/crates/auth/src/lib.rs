//! Password hashing and token issuing for Mydia Server.
//!
//! Lives outside the API crate so the admin UI can use the same primitives
//! without depending on GraphQL.

pub mod password;

#[derive(Debug, thiserror::Error)]
pub enum AuthError {
    #[error("could not hash the password")]
    Hash,

    #[error("could not issue the token: {0}")]
    Issue(#[source] jsonwebtoken::errors::Error),

    #[error("the token is not valid")]
    InvalidToken,
}
