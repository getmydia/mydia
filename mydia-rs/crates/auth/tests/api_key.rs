//! Argon2id verification against `argon2_elixir 4.1.3`-shaped hashes.
//!
//! The PHC format embeds variant, version, and m/t/p parameters, so
//! any conforming Argon2 verifier reads the hash transparently. These
//! tests cover the happy path, mismatched plaintexts, and malformed
//! storage.

use argon2::{
    password_hash::{rand_core::OsRng, PasswordHasher, SaltString},
    Algorithm, Argon2, Params, Version,
};
use mydia_rs_auth::{verify_api_key_hash, ApiKeyAuthError};

/// Approximation of `argon2_elixir 4.1.3`'s default params.
fn build_phoenix_shaped_hash(plaintext: &str) -> String {
    let salt = SaltString::generate(&mut OsRng);
    let params = Params::new(64 * 1024, 3, 4, None).expect("params");
    let argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);
    argon2
        .hash_password(plaintext.as_bytes(), &salt)
        .expect("hash")
        .to_string()
}

#[test]
fn round_trip_against_argon2id() {
    let stored = build_phoenix_shaped_hash("api-key-secret");
    assert!(stored.starts_with("$argon2id$"));
    verify_api_key_hash("api-key-secret", &stored).expect("verify");
}

#[test]
fn mismatch_returns_typed_error() {
    let stored = build_phoenix_shaped_hash("the right one");
    let err = verify_api_key_hash("the wrong one", &stored).expect_err("must reject");
    assert!(matches!(err, ApiKeyAuthError::Mismatch));
}

#[test]
fn malformed_hash_is_typed_separately() {
    let err = verify_api_key_hash("anything", "definitely-not-argon2").expect_err("malformed");
    assert!(
        matches!(err, ApiKeyAuthError::Malformed(_)),
        "got {err:?}, expected Malformed"
    );
}

#[test]
fn verifies_hash_with_different_params_via_phc() {
    // PHC includes the parameters; a hash created with different m/t/p
    // still verifies because the verifier reads them from the string.
    let salt = SaltString::generate(&mut OsRng);
    let alt_params = Params::new(32 * 1024, 2, 2, None).unwrap();
    let alt_argon2 = Argon2::new(Algorithm::Argon2id, Version::V0x13, alt_params);
    let stored = alt_argon2
        .hash_password(b"another-key", &salt)
        .unwrap()
        .to_string();
    verify_api_key_hash("another-key", &stored).expect("verify");
}
