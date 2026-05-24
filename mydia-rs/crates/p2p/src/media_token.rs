//! Media-token validator that fuses `mydia_rs_auth`'s JWT cache with a
//! DB-backed device-revocation check.
//!
//! ## Design
//!
//! The U6 auth crate ships [`mydia_rs_auth::MediaTokenSigner`] (HS512
//! JWT issue/verify, Guardian-compatible) and
//! [`mydia_rs_auth::MediaTokenCache`] (dashmap, SHA-256 cache key, TTL,
//! evict-by-device, evict-by-user). What it does NOT do is the second
//! half of `Mydia.RemoteAccess.MediaToken.resource_from_claims/1`:
//! confirm that the device row still exists and is not revoked. Phoenix
//! does that on every JWT verify; we want the same shape without
//! paying the DB round-trip on every request.
//!
//! [`MediaTokenValidator`] threads the cache hit through to the
//! caller untouched, but on a cache miss it (a) verifies the JWT
//! signature and `typ` via the signer, (b) loads the device row and
//! checks `revoked_at`, and (c) only then caches the verified claims.
//! Synchronous device-revoke wipes the cache entry by sub claim.
//!
//! ## Phoenix parity
//!
//! - Cache key: SHA-256 of the bearer token (auth crate handles this).
//! - Cache TTL: 5 minutes by default
//!   (`lib/mydia/media/token_cache.ex:32` `@ttl_ms :timer.minutes(5)`).
//! - On miss: verify via `MediaToken.verify_token/1` + load device by
//!   `(id, user_id)` with `revoked_at IS NULL`
//!   (`lib/mydia/remote_access/media_token.ex:135-152`).
//! - On device revoke: synchronously evict; next request must fail
//!   immediately, not after the TTL
//!   (`lib/mydia/media/token_cache.ex:88-104`).

use mydia_rs_auth::{MediaTokenCache, MediaTokenClaims, MediaTokenError, MediaTokenSigner};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use mydia_rs_models::RemoteDevice;
use thiserror::Error;
use uuid::Uuid;

/// Errors surfaced when validating a media token.
#[derive(Debug, Error)]
pub enum ValidationError {
    #[error("token expired")]
    Expired,
    #[error("invalid token: {0}")]
    Invalid(String),
    #[error("token type mismatch: expected media_access")]
    WrongType,
    #[error("device not found")]
    DeviceNotFound,
    #[error("device revoked")]
    DeviceRevoked,
    #[error("invalid device id in token")]
    InvalidDeviceId,
    #[error("database error: {0}")]
    Database(String),
}

impl From<MediaTokenError> for ValidationError {
    fn from(err: MediaTokenError) -> Self {
        match err {
            MediaTokenError::Expired => Self::Expired,
            MediaTokenError::WrongType => Self::WrongType,
            MediaTokenError::Invalid(reason) | MediaTokenError::Internal(reason) => {
                Self::Invalid(reason)
            }
        }
    }
}

/// Successful validation surface: the verified claims plus the
/// matching device row.
#[derive(Debug, Clone)]
pub struct ValidatedToken {
    pub claims: MediaTokenClaims,
    pub device: RemoteDevice,
}

/// Combined JWT-verify + DB-device-active validator.
///
/// Cheap to clone. Internally shares the same `MediaTokenCache`
/// dashmap, so calling [`MediaTokenValidator::evict_device`] from
/// admin revoke flows is visible to every clone.
#[derive(Clone)]
pub struct MediaTokenValidator {
    signer: MediaTokenSigner,
    cache: MediaTokenCache,
    db: Db,
}

impl MediaTokenValidator {
    pub fn new(signer: MediaTokenSigner, cache: MediaTokenCache, db: Db) -> Self {
        Self { signer, cache, db }
    }

    /// Reuse the underlying cache (e.g. for tests that need to assert
    /// hit counts) or share it across a process where multiple
    /// validators wrap the same backing storage.
    pub fn cache(&self) -> &MediaTokenCache {
        &self.cache
    }

    /// Validate a bearer token.
    ///
    /// On cache hit returns the cached claims plus a freshly loaded
    /// `RemoteDevice` row. On cache miss verifies the JWT, loads the
    /// device, and caches the claims if (and only if) the device is
    /// active.
    ///
    /// We always re-load the device row even on a cache hit because
    /// the cache only holds verified claims, not the latest
    /// `last_seen_at` / `revoked_at` snapshot. The DB cost on a cache
    /// hit is one indexed PK lookup; matches Phoenix shape.
    pub async fn validate(&self, token: &str) -> Result<ValidatedToken, ValidationError> {
        let claims = self
            .cache
            .lookup_or_verify(&self.signer, token)
            .map_err(ValidationError::from)?;

        let device = self.load_active_device(&claims).await?;
        Ok(ValidatedToken { claims, device })
    }

    /// Synchronously evict every cached entry for the given device id.
    /// Mirrors `TokenCache.invalidate_for_device/1`.
    pub fn evict_device(&self, device_id: &str) {
        self.cache.evict_device(device_id);
    }

    /// Synchronously evict every cached entry for the given user id.
    pub fn evict_user(&self, user_id: &str) {
        self.cache.evict_user(user_id);
    }

    async fn load_active_device(
        &self,
        claims: &MediaTokenClaims,
    ) -> Result<RemoteDevice, ValidationError> {
        let device_id =
            Uuid::parse_str(&claims.sub).map_err(|_| ValidationError::InvalidDeviceId)?;
        let user_id =
            Uuid::parse_str(&claims.user_id).map_err(|_| ValidationError::InvalidDeviceId)?;

        let device_id_text = UuidText(device_id);
        let user_id_text = UuidText(user_id);

        let device: Option<RemoteDevice> = match &self.db {
            Db::Sqlite(pool) => {
                // SQLite arm of a tier-(a) pair; byte-equal to the macro arm below.
                #[allow(clippy::disallowed_methods)]
                sqlx::query_as::<_, RemoteDevice>(
                    "SELECT id, device_name, platform, device_static_public_key, \
                     token_hash, last_seen_at, revoked_at, user_id, inserted_at, updated_at \
                     FROM remote_devices WHERE id = $1 AND user_id = $2",
                )
                .bind(device_id_text)
                .bind(user_id_text)
                .fetch_optional(pool)
                .await
            }
            Db::Postgres(pool) => sqlx::query_as!(
                RemoteDevice,
                r#"SELECT
                    id as "id!: UuidText",
                    device_name,
                    platform,
                    device_static_public_key,
                    token_hash,
                    last_seen_at as "last_seen_at?: DateTimeSecs",
                    revoked_at as "revoked_at?: DateTimeSecs",
                    user_id as "user_id!: UuidText",
                    inserted_at as "inserted_at!: DateTimeSecs",
                    updated_at as "updated_at!: DateTimeSecs"
                  FROM remote_devices WHERE id = $1 AND user_id = $2"#,
                device_id_text as UuidText,
                user_id_text as UuidText
            )
            .fetch_optional(pool)
            .await,
        }
        .map_err(|err| ValidationError::Database(err.to_string()))?;

        let device = device.ok_or(ValidationError::DeviceNotFound)?;
        if device.is_revoked() {
            // Belt-and-braces: also evict from cache so subsequent
            // requests don't read the stale cached entry. Matches the
            // semantics of `device_active?/1` in Phoenix.
            self.cache.evict_device(&claims.sub);
            return Err(ValidationError::DeviceRevoked);
        }

        Ok(device)
    }
}
