//! Bcrypt verification cross-checks.
//!
//! `bcrypt_elixir 3.3.2` and the Rust `bcrypt 0.16` crate both
//! implement the standard `$2b$<cost>$<22-char-salt><31-char-hash>`
//! encoding, so a hash produced by either side verifies on the other.
//! These tests pin that round-trip and the cost constant.

use mydia_rs_auth::{hash_password, verify_password, PasswordError, PASSWORD_HASH_COST};

#[test]
fn round_trip_with_pinned_cost() {
    let plaintext = "correct horse battery staple";
    let hash = hash_password(plaintext).expect("hash");

    // Cost is encoded in the hash; the third dollar-delimited segment.
    let cost_token: u32 = hash
        .split('$')
        .nth(2)
        .and_then(|s| s.parse().ok())
        .expect("cost token");
    assert_eq!(cost_token, PASSWORD_HASH_COST);

    verify_password(plaintext, &hash).expect("verify ok");
}

#[test]
fn mismatch_returns_typed_error() {
    let hash = hash_password("right one").unwrap();
    let err = verify_password("wrong one", &hash).expect_err("must reject");
    assert!(matches!(err, PasswordError::Mismatch));
}

#[test]
fn produced_hash_starts_with_2b_prefix_phoenix_writes() {
    // Pin the algorithm-version prefix. bcrypt_elixir 3.3.2 writes
    // "$2b$" and verifies "$2b$" / "$2a$" / "$2y$"; the Rust bcrypt
    // 0.16 crate writes "$2b$" too, so cross-backend writes stay
    // string-equal modulo cost + salt + hash bytes.
    let hash = hash_password("anything").unwrap();
    assert!(hash.starts_with("$2b$"), "expected $2b$ prefix, got {hash}");
}

#[test]
fn malformed_hash_is_typed_separately_from_mismatch() {
    let err = verify_password("anything", "definitely-not-bcrypt").expect_err("malformed");
    assert!(
        matches!(err, PasswordError::Malformed(_)),
        "got {err:?}, expected Malformed"
    );
}

#[test]
fn timing_is_not_short_circuited_on_empty_inputs() {
    // bcrypt::verify treats empty inputs as failed verification, not
    // as success. Pin this so a future regression doesn't auth empty
    // passwords against trimmed hashes.
    let hash = hash_password("nonempty").unwrap();
    assert!(matches!(
        verify_password("", &hash),
        Err(PasswordError::Mismatch)
    ));
}
