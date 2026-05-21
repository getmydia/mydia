//! Media-token JWT issue, verify, and cache.
//!
//! Media tokens authenticate direct media requests from paired remote
//! devices (HLS streams, downloads, thumbnails) without the
//! session-cookie surface. They are HS512-signed JWTs the Guardian
//! library issues on the Phoenix side using a shared signing key, so
//! tokens issued by either backend verify against either backend
//! during the parallel window.
//!
//! Payload shape mirrors `Mydia.RemoteAccess.MediaToken`:
//! ```ignore
//! {
//!   "sub": "<device_id>",
//!   "user_id": "<user_id>",
//!   "permissions": ["stream", "download", "thumbnails"],
//!   "typ": "media_access",
//!   "iat": <unix>,
//!   "exp": <unix>
//! }
//! ```
//!
//! [`MediaTokenCache`] keeps verified claims in a dashmap keyed on the
//! SHA-256 of the bearer token. Keying on the hash keeps the secret
//! material out of the cache key (so debug dumps and panic backtraces
//! don't leak bearer credentials). Cache TTL defaults to 5 minutes.
//!
//! Admin device-revoke uses [`MediaTokenCache::evict_device`] for
//! synchronous eviction: the next request from the revoked device
//! fails immediately, not after the cache TTL expires.

use std::sync::Arc;
use std::time::{Duration, Instant};

use chrono::{TimeZone, Utc};
use dashmap::DashMap;
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Maximum permitted scope on a media token. Matches
/// `Mydia.RemoteAccess.MediaToken.@all_permissions`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum MediaTokenPermission {
    Stream,
    Download,
    Thumbnails,
}

impl MediaTokenPermission {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stream => "stream",
            Self::Download => "download",
            Self::Thumbnails => "thumbnails",
        }
    }

    pub fn parse(s: &str) -> Option<Self> {
        match s {
            "stream" => Some(Self::Stream),
            "download" => Some(Self::Download),
            "thumbnails" => Some(Self::Thumbnails),
            _ => None,
        }
    }
}

/// Decoded media token claims.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct MediaTokenClaims {
    /// Device id (Guardian `sub` claim).
    pub sub: String,
    pub user_id: String,
    pub permissions: Vec<String>,
    #[serde(default = "default_typ")]
    pub typ: String,
    pub iat: i64,
    pub exp: i64,
}

fn default_typ() -> String {
    "media_access".into()
}

impl MediaTokenClaims {
    /// `true` when the token grants the requested permission.
    pub fn allows(&self, permission: MediaTokenPermission) -> bool {
        self.permissions.iter().any(|p| p == permission.as_str())
    }

    /// Convenience: parse the `iat` Unix-seconds value back into a
    /// `DateTime<Utc>`.
    pub fn issued_at(&self) -> Option<chrono::DateTime<Utc>> {
        Utc.timestamp_opt(self.iat, 0).single()
    }

    /// Convenience: parse the `exp` Unix-seconds value back into a
    /// `DateTime<Utc>`.
    pub fn expires_at(&self) -> Option<chrono::DateTime<Utc>> {
        Utc.timestamp_opt(self.exp, 0).single()
    }
}

#[derive(Debug, thiserror::Error)]
pub enum MediaTokenError {
    #[error("token expired")]
    Expired,
    #[error("invalid token: {0}")]
    Invalid(String),
    #[error("token type mismatch: expected media_access")]
    WrongType,
    #[error("internal jwt error: {0}")]
    Internal(String),
}

/// Sign + verify side of the media-token pipeline. Stateless;
/// constructing one is cheap (a couple of allocations).
#[derive(Clone)]
pub struct MediaTokenSigner {
    encoding_key: EncodingKey,
    decoding_key: DecodingKey,
    /// Guardian's allowed clock drift defaults to 0; the Phoenix
    /// config sets `jwt_allowed_drift_ms`. We carry it in milliseconds
    /// for parity but jsonwebtoken takes a `u64` seconds leeway.
    leeway_secs: u64,
}

impl MediaTokenSigner {
    pub fn new(secret: &str, leeway_secs: u64) -> Self {
        Self {
            encoding_key: EncodingKey::from_secret(secret.as_bytes()),
            decoding_key: DecodingKey::from_secret(secret.as_bytes()),
            leeway_secs,
        }
    }

    /// Issue a media token for a device, valid for `ttl`.
    pub fn issue(
        &self,
        device_id: &str,
        user_id: &str,
        permissions: &[MediaTokenPermission],
        ttl: Duration,
    ) -> Result<String, MediaTokenError> {
        let now = Utc::now().timestamp();
        let claims = MediaTokenClaims {
            sub: device_id.into(),
            user_id: user_id.into(),
            permissions: permissions.iter().map(|p| p.as_str().to_string()).collect(),
            typ: "media_access".into(),
            iat: now,
            exp: now + ttl.as_secs() as i64,
        };
        encode(&Header::new(Algorithm::HS512), &claims, &self.encoding_key)
            .map_err(|err| MediaTokenError::Internal(err.to_string()))
    }

    /// Verify a token. Surfaces [`MediaTokenError::Expired`] for
    /// expired tokens and [`MediaTokenError::WrongType`] for tokens
    /// signed for a different Guardian `typ`.
    pub fn verify(&self, token: &str) -> Result<MediaTokenClaims, MediaTokenError> {
        let mut validation = Validation::new(Algorithm::HS512);
        validation.leeway = self.leeway_secs;
        // Don't have jsonwebtoken validate `typ`; we check below so we
        // can return the typed `WrongType` rather than its generic
        // "missing required claim" error.
        validation.required_spec_claims.clear();
        validation.required_spec_claims.insert("exp".into());

        match decode::<MediaTokenClaims>(token, &self.decoding_key, &validation) {
            Ok(data) => {
                if data.claims.typ != "media_access" {
                    return Err(MediaTokenError::WrongType);
                }
                Ok(data.claims)
            }
            Err(err) => match err.kind() {
                jsonwebtoken::errors::ErrorKind::ExpiredSignature => Err(MediaTokenError::Expired),
                _ => Err(MediaTokenError::Invalid(err.to_string())),
            },
        }
    }
}

/// In-process cache for verified media tokens.
///
/// Keyed on SHA-256 of the bearer token so the bearer secret never
/// appears in the cache key. The cache stores both the verified
/// claims and the wall-clock instant the entry was inserted.
/// `lookup_or_verify` returns the cached entry if it's still within
/// `ttl`, otherwise verifies via the supplied [`MediaTokenSigner`]
/// and caches the result.
#[derive(Clone)]
pub struct MediaTokenCache {
    entries: Arc<DashMap<[u8; 32], CachedEntry>>,
    ttl: Duration,
}

#[derive(Clone)]
struct CachedEntry {
    claims: MediaTokenClaims,
    inserted_at: Instant,
}

impl MediaTokenCache {
    pub fn new(ttl: Duration) -> Self {
        Self {
            entries: Arc::new(DashMap::new()),
            ttl,
        }
    }

    /// Verify a bearer token, caching the verified claims. Cache hits
    /// return the previously verified claims as long as the entry is
    /// younger than the configured TTL.
    pub fn lookup_or_verify(
        &self,
        signer: &MediaTokenSigner,
        token: &str,
    ) -> Result<MediaTokenClaims, MediaTokenError> {
        let key = hash_token(token);
        if let Some(entry) = self.entries.get(&key) {
            if entry.inserted_at.elapsed() < self.ttl {
                return Ok(entry.claims.clone());
            }
        }

        let claims = signer.verify(token)?;
        self.entries.insert(
            key,
            CachedEntry {
                claims: claims.clone(),
                inserted_at: Instant::now(),
            },
        );
        Ok(claims)
    }

    /// Synchronously evict every cached entry for the given device id.
    /// Use during admin device-revoke so the next request from a
    /// revoked device fails immediately instead of after the cache TTL.
    pub fn evict_device(&self, device_id: &str) {
        self.entries.retain(|_, entry| entry.claims.sub != device_id);
    }

    /// Synchronously evict every cached entry for the given user id.
    /// Useful when a user is disabled / role-changed.
    pub fn evict_user(&self, user_id: &str) {
        self.entries.retain(|_, entry| entry.claims.user_id != user_id);
    }

    /// Number of entries currently cached. Visible mostly for tests.
    pub fn len(&self) -> usize {
        self.entries.len()
    }

    pub fn is_empty(&self) -> bool {
        self.entries.is_empty()
    }

    /// Drop every cached entry. Exposed for tests and for the rare
    /// "force everyone to re-verify" operator scenario.
    pub fn clear(&self) {
        self.entries.clear();
    }
}

fn hash_token(token: &str) -> [u8; 32] {
    let mut hasher = Sha256::new();
    hasher.update(token.as_bytes());
    hasher.finalize().into()
}
