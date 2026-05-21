//! Authentication primitives for mydia-rs.
//!
//! This unit (U6) ships the load-bearing security pieces:
//!
//! - [`password`]: bcrypt verify + hash, pinned to cost 12 to match
//!   `bcrypt_elixir 3.3.2`. Phoenix-written `users.password_hash`
//!   strings verify here unchanged.
//! - [`api_key`]: Argon2id verify against PHC-encoded hashes that
//!   `argon2_elixir 4.1.3` produces on the Phoenix side.
//! - [`media_token`]: HS512 JWT issue / verify (Guardian-compatible
//!   shared signing key) plus an in-process cache keyed on
//!   SHA-256-of-token, with synchronous eviction for the admin
//!   device-revoke flow.
//! - [`role`]: [`role::Role`] enum + `require_role` helper.
//!
//! The tower-sessions sqlx-backed session store and the axum-login
//! `AuthnBackend` impl land in a U6 follow-up once the axum app
//! (U22) exists to mount them. The primitives in this crate are the
//! load-bearing parts; the middleware is glue around them.

pub mod access_token;
pub mod api_key;
pub mod media_token;
pub mod password;
pub mod role;

pub use access_token::{AccessTokenClaims, AccessTokenError, AccessTokenSigner, IssuedToken};
pub use api_key::{verify_api_key_hash, ApiKeyAuthError};
pub use media_token::{
    MediaTokenCache, MediaTokenClaims, MediaTokenError, MediaTokenPermission, MediaTokenSigner,
};
pub use password::{hash_password, verify_password, PasswordError, PASSWORD_HASH_COST};
pub use role::{require_role, Role, RoleError};
