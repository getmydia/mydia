//! Blinded pairing claim storage.
//!
//! The metadata relay is a rendezvous point, not a trusted party. It receives a
//! lookup key derived from the claim code and a sealed blob, and can read
//! neither the code nor the server's node address.
//!
//! Both the Elixir server and the Dart player reach this module through their
//! own bindings. It is the single implementation on purpose: three separate
//! Argon2 configurations would disagree silently and break every pairing.

use argon2::{Algorithm, Argon2, Params, Version};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine as _;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{ChaCha20Poly1305, Key, Nonce};
use hkdf::Hkdf;
use serde::{Deserialize, Serialize};
use sha2::Sha256;

/// Protocol constants. Changing any of these breaks every existing client.
///
/// # Offline security bound
///
/// The salt is a protocol constant rather than per-entry random, because the
/// player must derive the lookup key from the typed code alone, with nothing
/// else to go on. So a stolen relay dump can be attacked offline: one Argon2id
/// search over the code space opens every entry in that snapshot at once.
///
/// Six characters from a 31-symbol alphabet is 31^6 = 887,503,681 candidates,
/// about 29.7 bits. At 64 MiB and t=3 that search costs roughly 3.3-3.9
/// CPU-years, and the 300-second TTL means a snapshot holds very few live
/// claims. What it yields is one node ID and an already-expired code.
///
/// That figure is measured, not estimated: a release-profile run of this
/// module's tests forced single-threaded does ~117-137ms per `derive()` call,
/// so 887,503,681 candidates is ~1.04e8 to ~1.22e8 CPU-seconds. This comment
/// previously said "on the order of ten CPU-years", which overstated the cost
/// by about 2.5-3x. The direction of that error matters: it read as safer than
/// the code actually is, and a security bound that flatters itself is the kind
/// of comment nobody rechecks.
///
/// Note also that CPU-years is a single-core framing, and the search is
/// embarrassingly parallel. What bounds a funded attacker is not the total
/// core-years but the 300-second TTL: exhausting the space inside one claim's
/// live window needs ~405,000 concurrent cores, and a more plausible ~1,400
/// cores covers only ~0.35% of the keyspace per window, with no progress
/// carrying across claims because each one draws a fresh code.
///
/// The p2p guess limiter does not help here; it bounds online guessing only.
/// This bound is accepted deliberately for an honest-but-curious relay. Raising
/// it needs a longer code or a PAKE, both considered and set aside in
/// docs/superpowers/specs/2026-08-19-e2e-pairing-design.md.
const ARGON2_SALT: &[u8] = b"mydia-pairing-v1";
const ARGON2_MEMORY_KIB: u32 = 65536;
const ARGON2_ITERATIONS: u32 = 3;
const ARGON2_PARALLELISM: u32 = 1;
const SEED_LEN: usize = 32;
const INFO_LOOKUP: &[u8] = b"mydia/pairing/lookup/v1";
const INFO_SEAL: &[u8] = b"mydia/pairing/seal/v1";

const NONCE_LEN: usize = 12;
/// Matches the relay's own cap. A legitimate payload is a few hundred bytes.
const MAX_SEALED_BYTES: usize = 4096;

/// What the relay stores, encrypted. The player needs both fields before it can
/// dial, so both travel inside the seal.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ClaimPayload {
    pub node_addr: String,
    pub instance_id: String,
}

/// What the server posts to the relay.
#[derive(Debug, Clone, PartialEq)]
pub struct SealedClaim {
    /// Lowercase hex, 64 characters. Used as the relay URL path segment.
    pub lookup_key: String,
    /// base64url without padding: nonce || ciphertext || tag.
    pub sealed: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairingSealError {
    /// The code was empty once dashes and whitespace were stripped.
    EmptyCode,
    /// Argon2 or HKDF refused the parameters, or the OS gave no randomness.
    Derivation,
    /// The payload could not be encoded, or the decrypted bytes were not a
    /// valid `ClaimPayload`.
    Encode,
    /// The blob was not base64url, or was too short or too long to be a seal.
    Decode,
    /// The AEAD tag did not verify. Wrong code, or the blob was altered.
    Open,
}

impl core::fmt::Display for PairingSealError {
    fn fmt(&self, f: &mut core::fmt::Formatter<'_>) -> core::fmt::Result {
        let msg = match self {
            PairingSealError::EmptyCode => "claim code is empty",
            PairingSealError::Derivation => "key derivation failed",
            PairingSealError::Encode => "could not encode pairing payload",
            PairingSealError::Decode => "sealed claim is malformed",
            PairingSealError::Open => "sealed claim failed verification",
        };
        f.write_str(msg)
    }
}

impl std::error::Error for PairingSealError {}

/// Uppercase, then drop dashes and whitespace.
///
/// This is the one definition. Elixir and Dart both pass raw user input in, so
/// if they normalized separately they would eventually disagree.
pub fn normalize_code(code: &str) -> String {
    code.chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .flat_map(|c| c.to_uppercase())
        .collect()
}

struct DerivedKeys {
    lookup_key: [u8; 32],
    seal_key: [u8; 32],
}

/// One Argon2 pass, split by domain separation. Argon2 is the expensive step and
/// deriving twice would double the cost on a phone for no benefit.
fn derive(code: &str) -> Result<DerivedKeys, PairingSealError> {
    let normalized = normalize_code(code);
    if normalized.is_empty() {
        return Err(PairingSealError::EmptyCode);
    }

    let params = Params::new(
        ARGON2_MEMORY_KIB,
        ARGON2_ITERATIONS,
        ARGON2_PARALLELISM,
        Some(SEED_LEN),
    )
    .map_err(|_| PairingSealError::Derivation)?;

    let argon = Argon2::new(Algorithm::Argon2id, Version::V0x13, params);

    let mut seed = [0u8; SEED_LEN];
    argon
        .hash_password_into(normalized.as_bytes(), ARGON2_SALT, &mut seed)
        .map_err(|_| PairingSealError::Derivation)?;

    let hk = Hkdf::<Sha256>::from_prk(&seed).map_err(|_| PairingSealError::Derivation)?;

    let mut lookup_key = [0u8; 32];
    let mut seal_key = [0u8; 32];
    hk.expand(INFO_LOOKUP, &mut lookup_key)
        .map_err(|_| PairingSealError::Derivation)?;
    hk.expand(INFO_SEAL, &mut seal_key)
        .map_err(|_| PairingSealError::Derivation)?;

    Ok(DerivedKeys {
        lookup_key,
        seal_key,
    })
}

/// Derive only the lookup key. The player needs it to build the relay URL before
/// it has anything to open.
pub fn lookup_key_for(code: &str) -> Result<String, PairingSealError> {
    Ok(hex::encode(derive(code)?.lookup_key))
}

pub fn seal_claim(code: &str, payload: &ClaimPayload) -> Result<SealedClaim, PairingSealError> {
    let keys = derive(code)?;
    let lookup_key = hex::encode(keys.lookup_key);

    let plaintext = serde_cbor::to_vec(payload).map_err(|_| PairingSealError::Encode)?;

    let mut nonce_bytes = [0u8; NONCE_LEN];
    getrandom::fill(&mut nonce_bytes).map_err(|_| PairingSealError::Derivation)?;

    let cipher = ChaCha20Poly1305::new(Key::from_slice(&keys.seal_key));
    let ciphertext = cipher
        .encrypt(
            Nonce::from_slice(&nonce_bytes),
            Payload {
                msg: &plaintext,
                // Defence in depth. The seal key is already code-specific, so a
                // relocated blob fails on the key alone; binding the index in
                // costs nothing and documents the intent.
                aad: lookup_key.as_bytes(),
            },
        )
        .map_err(|_| PairingSealError::Encode)?;

    let mut blob = Vec::with_capacity(NONCE_LEN + ciphertext.len());
    blob.extend_from_slice(&nonce_bytes);
    blob.extend_from_slice(&ciphertext);

    if blob.len() > MAX_SEALED_BYTES {
        return Err(PairingSealError::Encode);
    }

    Ok(SealedClaim {
        lookup_key,
        sealed: URL_SAFE_NO_PAD.encode(&blob),
    })
}

pub fn open_claim(code: &str, sealed: &str) -> Result<ClaimPayload, PairingSealError> {
    let keys = derive(code)?;
    let lookup_key = hex::encode(keys.lookup_key);

    let blob = URL_SAFE_NO_PAD
        .decode(sealed)
        .map_err(|_| PairingSealError::Decode)?;

    if blob.len() <= NONCE_LEN || blob.len() > MAX_SEALED_BYTES {
        return Err(PairingSealError::Decode);
    }

    let (nonce_bytes, ciphertext) = blob.split_at(NONCE_LEN);

    let cipher = ChaCha20Poly1305::new(Key::from_slice(&keys.seal_key));
    let plaintext = cipher
        .decrypt(
            Nonce::from_slice(nonce_bytes),
            Payload {
                msg: ciphertext,
                aad: lookup_key.as_bytes(),
            },
        )
        .map_err(|_| PairingSealError::Open)?;

    serde_cbor::from_slice(&plaintext).map_err(|_| PairingSealError::Encode)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload() -> ClaimPayload {
        ClaimPayload {
            node_addr: r#"{"id":"09ecb63dd2","relay_url":"https://relay.mydia.dev"}"#.to_string(),
            instance_id: "inst-abc-123".to_string(),
        }
    }

    #[test]
    fn seals_and_opens_round_trip() {
        let sealed = seal_claim("K7RPM2", &payload()).unwrap();
        let opened = open_claim("K7RPM2", &sealed.sealed).unwrap();
        assert_eq!(opened, payload());
    }

    #[test]
    fn lookup_key_is_64_hex_chars() {
        let sealed = seal_claim("K7RPM2", &payload()).unwrap();
        assert_eq!(sealed.lookup_key.len(), 64);
        assert!(sealed.lookup_key.chars().all(|c| c.is_ascii_hexdigit()));
        assert_eq!(sealed.lookup_key, lookup_key_for("K7RPM2").unwrap());
    }

    #[test]
    fn normalization_converges() {
        // Lowercase, dashes, and surrounding whitespace must all land on the
        // same keys. Elixir and Dart both hand user input straight in.
        let a = lookup_key_for("K7RPM2").unwrap();
        assert_eq!(a, lookup_key_for("k7rpm2").unwrap());
        assert_eq!(a, lookup_key_for("K7R-PM2").unwrap());
        assert_eq!(a, lookup_key_for("  k7r pm2  ").unwrap());
    }

    #[test]
    fn empty_code_is_rejected() {
        assert_eq!(
            lookup_key_for("   -- ").unwrap_err(),
            PairingSealError::EmptyCode
        );
    }

    #[test]
    fn wrong_code_cannot_open() {
        let sealed = seal_claim("K7RPM2", &payload()).unwrap();
        assert_eq!(
            open_claim("K7RPM3", &sealed.sealed).unwrap_err(),
            PairingSealError::Open
        );
    }

    #[test]
    fn tampered_ciphertext_fails_the_tag() {
        let sealed = seal_claim("K7RPM2", &payload()).unwrap();
        let mut raw = base64::engine::general_purpose::URL_SAFE_NO_PAD
            .decode(&sealed.sealed)
            .unwrap();
        // Flip a bit well past the nonce so the AEAD tag is what rejects it.
        let last = raw.len() - 1;
        raw[last] ^= 0x01;
        let tampered = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(&raw);
        assert_eq!(
            open_claim("K7RPM2", &tampered).unwrap_err(),
            PairingSealError::Open
        );
    }

    #[test]
    fn truncated_blob_is_rejected_before_decrypting() {
        let short = base64::engine::general_purpose::URL_SAFE_NO_PAD.encode([0u8; 8]);
        assert_eq!(
            open_claim("K7RPM2", &short).unwrap_err(),
            PairingSealError::Decode
        );
    }

    #[test]
    fn non_base64_input_is_rejected() {
        assert_eq!(
            open_claim("K7RPM2", "not base64!!").unwrap_err(),
            PairingSealError::Decode
        );
    }

    #[test]
    fn nonce_is_fresh_per_seal() {
        let a = seal_claim("K7RPM2", &payload()).unwrap();
        let b = seal_claim("K7RPM2", &payload()).unwrap();
        assert_eq!(a.lookup_key, b.lookup_key);
        assert_ne!(
            a.sealed, b.sealed,
            "a repeated nonce would leak the plaintext"
        );
    }

    #[test]
    fn derivation_is_pinned() {
        // Regenerate deliberately and bump the HKDF info strings to v2 if this
        // ever has to change. A silent change breaks every deployed client.
        assert_eq!(
            lookup_key_for("K7RPM2").unwrap(),
            "a6ce9c4621a367c4a02150f3dfe7019c4cb799e396b9b6cfbc1a445744a38b8d"
        );
    }
}
