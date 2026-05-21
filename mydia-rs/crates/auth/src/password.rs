//! Bcrypt password verification compatible with `bcrypt_elixir 3.3.2`.
//!
//! Phoenix stores `users.password_hash` as the standard bcrypt
//! `$2b$<cost>$<22-char-salt><31-char-hash>` string. The cost is
//! embedded in the string, so verifying a Phoenix-written hash works
//! regardless of which cost mydia-rs hashes at. For hashes *we*
//! create (password reset, first-time setup), [`PASSWORD_HASH_COST`]
//! is pinned to 12 to stay byte-equivalent with what Phoenix would
//! have produced.

/// Cost factor matching `bcrypt_elixir 3.3.2`'s default. Pinned so a
/// future Rust `bcrypt` crate default change doesn't silently produce
/// hashes the Phoenix side would still accept but which look different.
pub const PASSWORD_HASH_COST: u32 = 12;

#[derive(Debug, thiserror::Error)]
pub enum PasswordError {
    #[error("password verification failed")]
    Mismatch,

    #[error("stored password hash is malformed: {0}")]
    Malformed(String),

    #[error("password hashing failed: {0}")]
    Hash(String),
}

/// Verify a password against a Phoenix-shaped bcrypt hash.
///
/// Returns `Ok(())` on a match, [`PasswordError::Mismatch`] on a
/// mismatch, and [`PasswordError::Malformed`] when the stored hash
/// isn't parseable as bcrypt. Constant-time inside the bcrypt crate;
/// callers should not branch on the timing of this call.
pub fn verify_password(plaintext: &str, stored_hash: &str) -> Result<(), PasswordError> {
    match bcrypt::verify(plaintext, stored_hash) {
        Ok(true) => Ok(()),
        Ok(false) => Err(PasswordError::Mismatch),
        Err(bcrypt::BcryptError::InvalidHash(msg)) => Err(PasswordError::Malformed(msg)),
        Err(bcrypt::BcryptError::InvalidPrefix(msg)) => Err(PasswordError::Malformed(msg)),
        Err(bcrypt::BcryptError::InvalidCost(msg)) => Err(PasswordError::Malformed(msg)),
        Err(err) => Err(PasswordError::Hash(err.to_string())),
    }
}

/// Hash a plaintext at [`PASSWORD_HASH_COST`]. Use for password
/// resets and the first-time-setup flow.
pub fn hash_password(plaintext: &str) -> Result<String, PasswordError> {
    bcrypt::hash(plaintext, PASSWORD_HASH_COST).map_err(|err| PasswordError::Hash(err.to_string()))
}
