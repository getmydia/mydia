//! End-to-end device-pairing flow.
//!
//! Port of `Mydia.RemoteAccess.Pairing.complete_pairing/2`. Steps:
//!
//! 1. Validate the claim code via [`crate::claim`]. Fails fast on
//!    not-found / used / expired.
//! 2. Mint a fresh device token (32 random bytes, base64-no-padding).
//! 3. Argon2-hash the device token; only the hash is persisted, the
//!    plaintext is returned to the device once and never again.
//! 4. INSERT the `remote_devices` row.
//! 5. UPDATE the `pairing_claims` row to mark used + link the device.
//! 6. Issue the media token (HS512 JWT, sub = device id) and the
//!    user access token (HS512 JWT, sub = user id) via the U6 auth
//!    signers.
//!
//! The function returns all three tokens: the media token (long-lived
//! HLS access), the user access token (so the device immediately
//! issues GraphQL calls), and the device token (used to refresh after
//! the access token expires; this is the only thing tied to the row
//! via the `token_hash` column).

use std::time::Duration;

use argon2::password_hash::rand_core::OsRng;
use argon2::password_hash::SaltString;
use argon2::{Argon2, PasswordHasher};
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use chrono::Utc;
use mydia_rs_auth::{
    AccessTokenError, AccessTokenSigner, MediaTokenError, MediaTokenPermission, MediaTokenSigner,
};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::remote_devices;
use mydia_rs_models::RemoteDevice;
use rand::RngCore;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{DatabaseConnection, DbErr, EntityTrait, QueryFilter, Set};
use thiserror::Error;
use uuid::Uuid;

use crate::claim::{consume_claim_code, ClaimCodeError};

/// Caller-supplied device attributes. Matches the shape the Phoenix
/// `request_received` handler builds from the
/// `mydia_p2p_core::PairingRequest` fields.
#[derive(Debug, Clone)]
pub struct DeviceAttrs {
    pub device_name: String,
    /// Either `device_type` or `device_os` from the wire request,
    /// folded to a single column by the Phoenix handler. We match.
    pub platform: String,
}

/// The full token trio returned to the device when pairing succeeds.
#[derive(Debug, Clone)]
pub struct PairingOutcome {
    pub device: RemoteDevice,
    /// Long-lived HS512 JWT scoped to media-access permissions.
    pub media_token: String,
    /// User-scoped HS512 JWT the device uses for GraphQL until expiry.
    pub access_token: String,
    /// Plaintext device token. The DB only stores the Argon2 hash; the
    /// device persists this plaintext locally and resubmits it on
    /// reconnect.
    pub device_token: String,
}

/// Default TTLs matching Phoenix Guardian config.
const ACCESS_TOKEN_TTL: Duration = Duration::from_secs(60 * 60 * 24 * 30); // 30 days
const MEDIA_TOKEN_TTL: Duration = Duration::from_secs(60 * 60 * 24); // 24 hours

#[derive(Debug, Error)]
pub enum PairingError {
    #[error("claim: {0}")]
    Claim(#[from] ClaimCodeError),
    #[error("database error: {0}")]
    Database(String),
    #[error("token issue error: {0}")]
    Token(String),
    #[error("device token hash error: {0}")]
    Hash(String),
}

impl From<DbErr> for PairingError {
    fn from(err: DbErr) -> Self {
        Self::Database(err.to_string())
    }
}

impl From<MediaTokenError> for PairingError {
    fn from(err: MediaTokenError) -> Self {
        Self::Token(err.to_string())
    }
}

impl From<AccessTokenError> for PairingError {
    fn from(err: AccessTokenError) -> Self {
        Self::Token(err.to_string())
    }
}

/// Run the full pairing flow against the supplied DB + signers.
///
/// This is intentionally a free function (not a method on some
/// `Pairing` struct) so the integration tests can call it directly
/// with whatever DB + signer combination they want, mirroring how
/// `Mydia.RemoteAccess.Pairing.complete_pairing/2` is just a function
/// on a module.
pub async fn complete_pairing(
    db: &DatabaseConnection,
    media_signer: &MediaTokenSigner,
    access_signer: &AccessTokenSigner,
    claim_code: &str,
    attrs: DeviceAttrs,
) -> Result<PairingOutcome, PairingError> {
    // Step 1: validate + load the claim. We don't consume yet. we
    // want to create the device row first so we can stamp its id into
    // the claim's consume transition.
    let claim_outcome = crate::claim::validate_claim_code(db, claim_code).await?;
    let user_id: Uuid = claim_outcome.claim.user_id.0;

    // Step 2 + 3: mint + hash the device token.
    let device_token = generate_device_token();
    let token_hash = hash_device_token(&device_token)?;

    // Step 4: insert the remote_device row.
    let device_id = Uuid::new_v4();
    let now_dt = Utc::now();
    let now = DateTimeSecs::from(now_dt);
    let device_static_public_key = random_static_public_key();

    let am = remote_devices::ActiveModel {
        id: Set(UuidText(device_id)),
        device_name: Set(attrs.device_name.clone()),
        platform: Set(attrs.platform.clone()),
        device_static_public_key: Set(device_static_public_key.clone()),
        token_hash: Set(token_hash.clone()),
        last_seen_at: Set(Some(now)),
        revoked_at: Set(None),
        user_id: Set(UuidText(user_id)),
        inserted_at: Set(now),
        updated_at: Set(now),
    };
    mydia_rs_db::insert_active_model(am, db).await?;

    // Step 5: consume the claim. The atomic UPDATE inside
    // `consume_claim_code` keeps this safe under concurrent claim use.
    if let Err(err) = consume_claim_code(db, claim_code, device_id).await {
        // Roll back the device row so the user can retry. We do not
        // attempt to recover the orphaned row in tests because the
        // schema's index doesn't prevent a re-pair using a different
        // claim code; the production cleanup path runs in U17's
        // worker.
        let _ = delete_device(db, device_id).await;
        return Err(PairingError::Claim(err));
    }

    // Step 6: issue the tokens. We sign these even if the inserts
    // succeeded but pairing-state cleanup might fail (we already
    // committed the device row), so the device retries pairing rather
    // than being stranded.
    let media_token = media_signer.issue(
        &device_id.to_string(),
        &user_id.to_string(),
        &[
            MediaTokenPermission::Stream,
            MediaTokenPermission::Download,
            MediaTokenPermission::Thumbnails,
        ],
        MEDIA_TOKEN_TTL,
    )?;
    let access_token = access_signer.issue(&user_id.to_string(), ACCESS_TOKEN_TTL)?;

    // Assemble the device struct we hand back. We re-construct rather
    // than re-querying because we just wrote it; this matches what
    // Phoenix does (`Repo.insert/2` returns the inserted struct, no
    // SELECT roundtrip).
    let device = RemoteDevice {
        id: UuidText(device_id),
        device_name: attrs.device_name,
        platform: attrs.platform,
        device_static_public_key,
        token_hash,
        last_seen_at: Some(now),
        revoked_at: None,
        user_id: UuidText(user_id),
        inserted_at: now,
        updated_at: now,
    };

    Ok(PairingOutcome {
        device,
        media_token,
        access_token: access_token.token,
        device_token,
    })
}

/// 32 random bytes, base64-no-padding. Matches the Phoenix-side
/// `:crypto.strong_rand_bytes(32) |> Base.encode64(padding: false)`.
fn generate_device_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

/// Argon2id hash of the device token using a fresh salt. Mirrors the
/// `Argon2.hash_pwd_salt/1` call on the Phoenix side.
fn hash_device_token(plaintext: &str) -> Result<String, PairingError> {
    let salt = SaltString::generate(&mut OsRng);
    let argon2 = Argon2::default();
    argon2
        .hash_password(plaintext.as_bytes(), &salt)
        .map(|h| h.to_string())
        .map_err(|err| PairingError::Hash(err.to_string()))
}

/// 32 random bytes used as the `device_static_public_key` column.
/// Phoenix issues a real Curve25519 public key here when the device
/// supplies one; the pairing-over-relay flow doesn't have a key
/// exchange step so we use random bytes to satisfy the NOT NULL
/// constraint, matching `Mydia.RemoteAccess.Pairing.generate_dummy_key/0`.
fn random_static_public_key() -> Vec<u8> {
    let mut bytes = vec![0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    bytes
}

async fn delete_device(db: &DatabaseConnection, device_id: Uuid) -> Result<(), DbErr> {
    let device_id_text = UuidText(device_id);
    let backend = db.get_database_backend();
    remote_devices::Entity::delete_many()
        .filter(Expr::col(remote_devices::Column::Id).eq(device_id_text.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(())
}
