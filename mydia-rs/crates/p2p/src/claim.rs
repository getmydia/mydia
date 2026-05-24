//! Pairing claim-code generation, validation, and consumption.
//!
//! Direct port of `Mydia.RemoteAccess.PairingClaim` and the surface in
//! `Mydia.RemoteAccess.{validate_claim_code, consume_claim_code}`.
//!
//! ## Code shape
//!
//! - 8 characters, sampled from `ABCDEFGHJKLMNPQRSTUVWXYZ23456789`.
//!   The set excludes the ambiguous trio (0/O, 1/I, L) and avoids the
//!   letters that mis-render in many handwritten contexts.
//! - Rendered as `XXXX-XXXX` (dash inserted at the midpoint) for
//!   human readability.
//! - Default expiry: 5 minutes.
//!
//! See `lib/mydia/remote_access/pairing_claim.ex:13-15`.
//!
//! ## Storage
//!
//! Rows live in the `pairing_claims` table. The Phoenix-side flow
//! creates the row with a relay-minted code (the relay service does
//! the generation; the local row is the validator). We support both:
//!
//! - [`generate_claim_code`]. local generation. Useful for tests and
//!   for the "self-hosted with no relay" mode the plan calls out.
//! - [`validate_claim_code`]. case-insensitive, normalise-the-input
//!   lookup. Returns the claim row when present, valid, and unused.
//! - [`consume_claim_code`]. atomic "validate + mark used" inside a
//!   single transaction so concurrent claims of the same code race
//!   safely (one wins, the others see `AlreadyUsed`).
//!
//! Post-U11 cutover: SeaORM-native against the `pairing_claims`
//! entity. WHERE clauses against wrapper-typed columns route through
//! `wrapper.into_simple_expr(backend)` so Postgres gets the
//! `$N::uuid` / `$N::timestamptz` casts. Writes flow through
//! `mydia_rs_db::insert_active_model` / a targeted
//! `update_many().col_expr` chain.

use chrono::{Duration as ChronoDuration, Utc};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::pairing_claims;
use mydia_rs_models::PairingClaim;
use rand::Rng;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ColumnTrait, DatabaseConnection, DbErr, EntityTrait, QueryFilter, Set};
use std::time::Duration;
use thiserror::Error;
use uuid::Uuid;

const CODE_CHARS: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789";
const CODE_LENGTH: usize = 8;

/// Default time-to-live for a freshly minted claim. Matches
/// `@expiry_minutes 5` on the Phoenix side.
pub const CLAIM_CODE_DEFAULT_TTL: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Error)]
pub enum ClaimCodeError {
    #[error("claim code not found")]
    NotFound,
    #[error("claim code already used")]
    AlreadyUsed,
    #[error("claim code expired")]
    Expired,
    #[error("database error: {0}")]
    Database(String),
}

impl From<DbErr> for ClaimCodeError {
    fn from(err: DbErr) -> Self {
        Self::Database(err.to_string())
    }
}

/// Successful claim-code lookup.
#[derive(Debug, Clone)]
pub struct ClaimCodeOutcome {
    pub claim: PairingClaim,
}

/// Generate a fresh claim code matching Phoenix's character set and
/// `XXXX-XXXX` formatting.
///
/// The randomness source is `rand::thread_rng()`; for the same-suite
/// test deck we don't seed it, matching `:crypto.strong_rand_bytes/1`
/// on the BEAM side.
pub fn generate_claim_code() -> String {
    let mut rng = rand::thread_rng();
    let raw: String = (0..CODE_LENGTH)
        .map(|_| {
            let idx = rng.gen_range(0..CODE_CHARS.len());
            CODE_CHARS[idx] as char
        })
        .collect();
    let mid = CODE_LENGTH / 2;
    format!("{}-{}", &raw[..mid], &raw[mid..])
}

/// Normalise user input: uppercase and strip dashes / whitespace.
///
/// Mirrors `Mydia.RemoteAccess.normalize_code/1` (see
/// `lib/mydia/remote_access.ex`). Validation lookups always run
/// against the normalised, dash-inserted form so a user typing
/// "abcd1234" or "ABCD 1234" still matches "ABCD-1234".
pub fn normalize_claim_code(code: &str) -> String {
    let cleaned: String = code
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .flat_map(char::to_uppercase)
        .collect();
    if cleaned.len() == CODE_LENGTH {
        let mid = CODE_LENGTH / 2;
        format!("{}-{}", &cleaned[..mid], &cleaned[mid..])
    } else {
        cleaned
    }
}

/// Look up a claim by code, returning [`ClaimCodeOutcome`] when the
/// row exists, is unused, and has not expired.
///
/// Note: this does NOT consume the claim. Use [`consume_claim_code`]
/// in the actual pairing flow so the validate+mark transition is
/// atomic.
pub async fn validate_claim_code(
    db: &DatabaseConnection,
    code: &str,
) -> Result<ClaimCodeOutcome, ClaimCodeError> {
    let normalised = normalize_claim_code(code);
    let claim = load_by_code(db, &normalised).await?;

    if claim.is_used() {
        return Err(ClaimCodeError::AlreadyUsed);
    }
    if claim.is_expired(Utc::now()) {
        return Err(ClaimCodeError::Expired);
    }
    Ok(ClaimCodeOutcome { claim })
}

/// Atomically validate + mark a claim as used, tagging it with the
/// supplied device id. The UPDATE only succeeds when the row is
/// currently unused and unexpired, so two concurrent claims of the
/// same code race safely.
pub async fn consume_claim_code(
    db: &DatabaseConnection,
    code: &str,
    device_id: Uuid,
) -> Result<ClaimCodeOutcome, ClaimCodeError> {
    let normalised = normalize_claim_code(code);
    let now_dt = Utc::now();
    let now = DateTimeSecs::from(now_dt);
    let device_id_text = UuidText(device_id);
    let backend = db.get_database_backend();

    // Conditional UPDATE that only matches an unused, unexpired row.
    // Use targeted-column UPDATE so the SET clause and WHERE clause
    // both route wrapper-typed binds through the engine-aware
    // `into_simple_expr(backend)` helper.
    let result = pairing_claims::Entity::update_many()
        .col_expr(
            pairing_claims::Column::UsedAt,
            now.into_simple_expr(backend),
        )
        .col_expr(
            pairing_claims::Column::DeviceId,
            device_id_text.into_simple_expr(backend),
        )
        .col_expr(
            pairing_claims::Column::UpdatedAt,
            now.into_simple_expr(backend),
        )
        .filter(pairing_claims::Column::Code.eq(normalised.clone()))
        .filter(pairing_claims::Column::UsedAt.is_null())
        .filter(Expr::col(pairing_claims::Column::ExpiresAt).gt(now.into_simple_expr(backend)))
        .exec(db)
        .await?;

    if result.rows_affected == 0 {
        // The row wasn't updated. figure out why (not found vs. used
        // vs. expired) so the caller can render a precise error.
        return match load_by_code(db, &normalised).await {
            Ok(claim) if claim.is_used() => Err(ClaimCodeError::AlreadyUsed),
            Ok(claim) if claim.is_expired(now_dt) => Err(ClaimCodeError::Expired),
            Ok(_) => Err(ClaimCodeError::AlreadyUsed),
            Err(err) => Err(err),
        };
    }

    let claim = load_by_code(db, &normalised).await?;
    Ok(ClaimCodeOutcome { claim })
}

/// Insert a freshly minted claim into the DB. Returns the persisted
/// row.
///
/// Used by the local-generation path (tests, no-relay deployments) and
/// by the `RemoteAccess.generate_claim_code/1` Rust port that lands in
/// the GraphQL mutation surface in a follow-up unit.
pub async fn insert_claim(
    db: &DatabaseConnection,
    user_id: Uuid,
    code: &str,
    ttl: Duration,
) -> Result<PairingClaim, ClaimCodeError> {
    let normalised = normalize_claim_code(code);
    let now_dt = Utc::now();
    let now = DateTimeSecs::from(now_dt);
    let expires_dt = now_dt
        + ChronoDuration::from_std(ttl).map_err(|err| ClaimCodeError::Database(err.to_string()))?;
    let expires = DateTimeSecs::from(expires_dt);
    let id = Uuid::new_v4();

    let am = pairing_claims::ActiveModel {
        id: Set(UuidText(id)),
        code: Set(normalised.clone()),
        user_id: Set(UuidText(user_id)),
        expires_at: Set(expires),
        used_at: Set(None),
        device_id: Set(None),
        inserted_at: Set(now),
        updated_at: Set(now),
    };

    let model = mydia_rs_db::insert_active_model(am, db).await?;
    Ok(model_to_claim(model))
}

async fn load_by_code(db: &DatabaseConnection, code: &str) -> Result<PairingClaim, ClaimCodeError> {
    let model = pairing_claims::Entity::find()
        .filter(pairing_claims::Column::Code.eq(code.to_owned()))
        .one(db)
        .await?;
    model.map(model_to_claim).ok_or(ClaimCodeError::NotFound)
}

/// Convert the `SeaORM` entity Model into the `PairingClaim` row struct
/// that the rest of the crate (and downstream models) consumes. The
/// shapes match field-for-field; we keep `PairingClaim` distinct from
/// `pairing_claims::Model` so the models crate stays free of any
/// `SeaORM` trait derivations.
fn model_to_claim(model: pairing_claims::Model) -> PairingClaim {
    PairingClaim {
        id: model.id,
        code: model.code,
        user_id: model.user_id,
        expires_at: model.expires_at,
        used_at: model.used_at,
        device_id: model.device_id,
        inserted_at: model.inserted_at,
        updated_at: model.updated_at,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generated_code_has_dash_at_midpoint() {
        for _ in 0..100 {
            let code = generate_claim_code();
            assert_eq!(code.len(), CODE_LENGTH + 1, "{code} must be 9 chars");
            assert_eq!(code.chars().nth(4), Some('-'));
            // Every other character is in the allowed set.
            for c in code.chars().filter(|c| *c != '-') {
                assert!(CODE_CHARS.contains(&(c as u8)), "{c} not in code alphabet");
            }
        }
    }

    #[test]
    fn normalize_inserts_dash_at_midpoint() {
        assert_eq!(normalize_claim_code("abcd1234"), "ABCD-1234");
        assert_eq!(normalize_claim_code("ABCD-1234"), "ABCD-1234");
        assert_eq!(normalize_claim_code("ABCD 1234"), "ABCD-1234");
        assert_eq!(normalize_claim_code(" abcd-1234 "), "ABCD-1234");
    }

    #[test]
    fn normalize_passes_short_codes_through_uppercase() {
        // Defensive: don't crash on garbage input. Validation upstream
        // will fail-fast on a non-8-char body, but normalise must not
        // panic on it.
        assert_eq!(normalize_claim_code("abc"), "ABC");
        assert_eq!(normalize_claim_code(""), "");
    }
}
