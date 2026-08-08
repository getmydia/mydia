use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::{PasswordHash, PasswordHasher, PasswordVerifier, SaltString};
use argon2::Argon2;

use crate::AuthError;

/// Hashes a password with argon2id and a fresh random salt, returning a PHC
/// string that carries the parameters needed to verify it later.
pub fn hash(plain: &str) -> Result<String, AuthError> {
    let salt = SaltString::generate(&mut OsRng);

    Argon2::default()
        .hash_password(plain.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|_| AuthError::Hash)
}

/// Checks a password against a stored PHC string. A malformed stored hash
/// returns false rather than an error: from the caller's point of view an
/// unusable credential and a wrong credential are the same outcome.
pub fn verify(plain: &str, stored: &str) -> bool {
    let Ok(parsed) = PasswordHash::new(stored) else {
        return false;
    };

    Argon2::default()
        .verify_password(plain.as_bytes(), &parsed)
        .is_ok()
}

#[cfg(test)]
mod tests {
    use super::{hash, verify};

    #[test]
    fn correct_password_verifies() {
        let stored = hash("correct horse battery staple").unwrap();
        assert!(verify("correct horse battery staple", &stored));
    }

    #[test]
    fn wrong_password_does_not_verify() {
        let stored = hash("correct horse battery staple").unwrap();
        assert!(!verify("Tr0ub4dor&3", &stored));
    }

    #[test]
    fn hash_does_not_contain_the_password() {
        let stored = hash("hunter2").unwrap();
        assert!(!stored.contains("hunter2"));
    }

    #[test]
    fn two_hashes_of_one_password_differ() {
        let a = hash("hunter2").unwrap();
        let b = hash("hunter2").unwrap();
        assert_ne!(a, b, "each hash must use a fresh salt");
    }

    #[test]
    fn a_malformed_hash_does_not_verify() {
        assert!(!verify("hunter2", "not-a-phc-string"));
    }
}
