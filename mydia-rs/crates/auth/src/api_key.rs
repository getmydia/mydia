//! Argon2id API-key verification compatible with `argon2_elixir 4.1.3`.
//!
//! Phoenix stores `api_keys.key_hash` as a PHC-encoded Argon2id string
//! (`$argon2id$v=19$m=...,t=...,p=...$<salt>$<hash>`). Argon2's PHC
//! format embeds variant, version, memory/time/parallel parameters,
//! and the salt, so verifying a Phoenix-written hash works regardless
//! of what defaults this binary would otherwise pick.
//!
//! Argon2 verify in this crate is constant-time on the comparator
//! side. Callers must not branch on the timing of the result.

use argon2::password_hash::{rand_core::OsRng, SaltString};
use argon2::{Argon2, PasswordHash, PasswordHasher, PasswordVerifier};

#[derive(Debug, thiserror::Error)]
pub enum ApiKeyAuthError {
    #[error("api key verification failed")]
    Mismatch,

    #[error("stored api key hash is malformed: {0}")]
    Malformed(String),

    #[error("hashing failed: {0}")]
    HashFailed(String),
}

/// Hash a plaintext API key using Argon2id with the default
/// parameters, producing a PHC-encoded string a Phoenix verifier
/// (`argon2_elixir 4.1.3`) round-trips against.
pub fn hash_api_key(plaintext: &str) -> Result<String, ApiKeyAuthError> {
    let salt = SaltString::generate(&mut OsRng);
    let argon = Argon2::default();
    let hash = argon
        .hash_password(plaintext.as_bytes(), &salt)
        .map_err(|err| ApiKeyAuthError::HashFailed(err.to_string()))?;
    Ok(hash.to_string())
}

/// Verify a plaintext API key against a Phoenix-shaped Argon2id PHC hash.
///
/// Returns `Ok(())` on a match, [`ApiKeyAuthError::Mismatch`] when the
/// key doesn't verify, and [`ApiKeyAuthError::Malformed`] when the
/// stored hash isn't a parseable Argon2id PHC string.
pub fn verify_api_key_hash(plaintext: &str, stored_hash: &str) -> Result<(), ApiKeyAuthError> {
    let parsed = PasswordHash::new(stored_hash)
        .map_err(|err| ApiKeyAuthError::Malformed(err.to_string()))?;
    Argon2::default()
        .verify_password(plaintext.as_bytes(), &parsed)
        .map_err(|_| ApiKeyAuthError::Mismatch)
}
