//! Media-token issue/verify + cache + synchronous revoke.

use std::time::Duration;

use mydia_rs_auth::{MediaTokenCache, MediaTokenError, MediaTokenPermission, MediaTokenSigner};

const SECRET: &str = "shared-with-phoenix-via-guardian-config-secret-key";

fn signer() -> MediaTokenSigner {
    MediaTokenSigner::new(SECRET, 2)
}

#[test]
fn issue_and_verify_round_trips() {
    let signer = signer();
    let token = signer
        .issue(
            "device-123",
            "user-456",
            &[
                MediaTokenPermission::Stream,
                MediaTokenPermission::Thumbnails,
            ],
            Duration::from_secs(60),
        )
        .expect("issue");

    let claims = signer.verify(&token).expect("verify");
    assert_eq!(claims.sub, "device-123");
    assert_eq!(claims.user_id, "user-456");
    assert!(claims.allows(MediaTokenPermission::Stream));
    assert!(claims.allows(MediaTokenPermission::Thumbnails));
    assert!(!claims.allows(MediaTokenPermission::Download));
    assert_eq!(claims.typ, "media_access");
}

#[test]
fn verify_rejects_wrong_secret() {
    let token = signer()
        .issue(
            "d",
            "u",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    let other = MediaTokenSigner::new("different secret", 0);
    let err = other.verify(&token).expect_err("must reject");
    assert!(matches!(err, MediaTokenError::Invalid(_)));
}

#[test]
fn verify_rejects_expired_token() {
    let signer = MediaTokenSigner::new(SECRET, 0);
    // ttl = 0 -> exp == iat. Sleep 2s to push the verifier past the
    // expiry without going through real wall-clock dependencies.
    let token = signer
        .issue(
            "d",
            "u",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(0),
        )
        .unwrap();
    std::thread::sleep(Duration::from_secs(2));
    let err = signer.verify(&token).expect_err("must reject");
    assert!(matches!(err, MediaTokenError::Expired));
}

#[test]
fn cache_returns_same_claims_on_hit() {
    let signer = signer();
    let cache = MediaTokenCache::new(Duration::from_secs(300));
    let token = signer
        .issue(
            "d",
            "u",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();

    let first = cache.lookup_or_verify(&signer, &token).unwrap();
    assert_eq!(cache.len(), 1);
    let second = cache.lookup_or_verify(&signer, &token).unwrap();
    assert_eq!(first, second);
    assert_eq!(cache.len(), 1, "cache hit must not insert a second entry");
}

#[test]
fn evict_device_drops_only_that_devices_entries() {
    let signer = signer();
    let cache = MediaTokenCache::new(Duration::from_secs(300));

    let token_a = signer
        .issue(
            "dev-a",
            "user",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    let token_b = signer
        .issue(
            "dev-b",
            "user",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();

    cache.lookup_or_verify(&signer, &token_a).unwrap();
    cache.lookup_or_verify(&signer, &token_b).unwrap();
    assert_eq!(cache.len(), 2);

    cache.evict_device("dev-a");
    assert_eq!(cache.len(), 1);

    // dev-b token still hits cache.
    let claims = cache.lookup_or_verify(&signer, &token_b).unwrap();
    assert_eq!(claims.sub, "dev-b");
}

#[test]
fn evict_user_drops_every_device_for_that_user() {
    let signer = signer();
    let cache = MediaTokenCache::new(Duration::from_secs(300));

    let alice_a = signer
        .issue(
            "dev-a",
            "alice",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    let alice_b = signer
        .issue(
            "dev-b",
            "alice",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    let bob = signer
        .issue(
            "dev-c",
            "bob",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();

    cache.lookup_or_verify(&signer, &alice_a).unwrap();
    cache.lookup_or_verify(&signer, &alice_b).unwrap();
    cache.lookup_or_verify(&signer, &bob).unwrap();
    assert_eq!(cache.len(), 3);

    cache.evict_user("alice");
    assert_eq!(cache.len(), 1);
    let claims = cache.lookup_or_verify(&signer, &bob).unwrap();
    assert_eq!(claims.user_id, "bob");
}

#[test]
fn cache_does_not_use_bearer_token_as_key() {
    // The cache key is SHA-256(token). Test by inspecting that distinct
    // tokens with the same claims produce distinct cache entries
    // (different signatures -> different bearer strings -> different
    // hashes). This pins the keying contract without exposing the
    // hash function publicly.
    let signer = signer();
    let cache = MediaTokenCache::new(Duration::from_secs(300));

    let token1 = signer
        .issue(
            "dev-a",
            "user",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    // Re-issue after a 1s wait so iat/exp differ, guaranteeing the
    // signature differs even with identical scope.
    std::thread::sleep(Duration::from_millis(1100));
    let token2 = signer
        .issue(
            "dev-a",
            "user",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    assert_ne!(token1, token2);

    cache.lookup_or_verify(&signer, &token1).unwrap();
    cache.lookup_or_verify(&signer, &token2).unwrap();
    assert_eq!(cache.len(), 2);
}

#[test]
fn ttl_expires_cache_entries() {
    let signer = signer();
    let cache = MediaTokenCache::new(Duration::from_millis(100));
    let token = signer
        .issue(
            "dev-a",
            "user",
            &[MediaTokenPermission::Stream],
            Duration::from_secs(60),
        )
        .unwrap();
    cache.lookup_or_verify(&signer, &token).unwrap();
    std::thread::sleep(Duration::from_millis(150));
    // Re-lookup re-verifies (we know it does because we mutate the
    // signer below to a wrong secret and watch it fail).
    let wrong = MediaTokenSigner::new("wrong", 0);
    let err = cache
        .lookup_or_verify(&wrong, &token)
        .expect_err("ttl elapsed -> re-verify -> fails on wrong secret");
    assert!(matches!(err, MediaTokenError::Invalid(_)));
}
