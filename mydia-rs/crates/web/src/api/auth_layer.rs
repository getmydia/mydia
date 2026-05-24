//! Per-route auth middleware for the REST API surface (U33 follow-up).
//!
//! Mirrors the three Phoenix Plug pipelines that gate `/api/v1/*` and
//! `/api/player/v1/*`:
//!
//! - [`api_key_auth`] — `:api_auth` in Phoenix. Verifies an
//!   `X-API-Key` header (or `api_key` query param) against the
//!   `api_keys` table using Argon2id. Returns 401 on failure.
//! - [`media_token_auth`] — `:media_api_auth` in Phoenix. Verifies an
//!   `Authorization: Bearer <token>` header (or `token` query param)
//!   against the boot-time `MediaTokenSigner`. Used by the streaming +
//!   HLS endpoints which need to accept tokens from paired remote
//!   devices.
//! - [`require_admin`] — `:require_admin` in Phoenix. Looks up the
//!   authenticated user's role and rejects non-admin callers. Runs
//!   *after* [`api_key_auth`] so the request already carries an
//!   authenticated user.
//!
//! Wire shape mirrors the Phoenix pipeline:
//! * 401 with `{"error":"Unauthorized","message":"..."}` for missing
//!   / invalid credentials.
//! * 403 with `{"error":"Forbidden","message":"..."}` for role
//!   refusals.
//!
//! Each middleware is stateless (the verifier handle lives on
//! [`WebState`] which is already attached as an `Extension`). Routes
//! opt in by wrapping their submodule's router with
//! `.layer(from_fn(api_key_auth))` etc.

use axum::{
    extract::Request,
    http::{header, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    Json,
};
use mydia_rs_auth::{verify_api_key_hash, MediaTokenClaims};
use mydia_rs_db::DatabaseConnection;
use mydia_rs_entities::{api_keys, users};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use serde_json::json;

use crate::session::SESSION_KEY_USER_ID;
use crate::WebState;

/// Marker placed on the request extensions when authentication succeeds
/// via the API-key path. Downstream middleware (`require_admin`) reads
/// the user id from here to look up the role. Kept private to the
/// auth-layer surface so callers go through the typed accessors.
#[derive(Clone, Debug)]
pub struct AuthenticatedUser {
    pub user_id: String,
    pub source: AuthSource,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum AuthSource {
    /// Authenticated via an `X-API-Key` header (or `api_key` query
    /// param). The user id was loaded from the `api_keys` row.
    ApiKey,
    /// Authenticated via a media-token bearer JWT. The user id is the
    /// `user_id` claim on the token.
    MediaToken,
    /// Authenticated via the session cookie.
    Session,
}

/// Marker placed on the request extensions when the media-token
/// middleware succeeds. Handlers that need the device id (HLS session
/// start, future audit logs) read it from here.
#[derive(Clone, Debug)]
pub struct MediaTokenContext {
    pub claims: MediaTokenClaims,
}

/// `:api_auth` pipeline port. Verifies an API key against
/// `api_keys.key_hash`. On success, attaches an
/// [`AuthenticatedUser`] extension and forwards the request. On
/// failure (missing key, malformed key, no matching row, expired,
/// revoked), responds with `401 Unauthorized`.
///
/// This mirrors `MydiaWeb.Plugs.ApiAuth.call/2` modulo the
/// Phoenix-side rate limiter, which lives in a separate plug we
/// haven't ported yet (TODO(U33-follow-up.rate-limit)). The order of
/// fallbacks matches: header first, then query.
pub async fn api_key_auth(request: Request, next: Next) -> Response {
    // Drain the bits we need from the request before any awaits so the
    // future stays `Send` (the request body is `!Sync`, so holding
    // `&Request` across an await poisons the future's auto-Send impl).
    let Some(state) = request.extensions().get::<WebState>().cloned() else {
        tracing::error!(
            "api_key_auth: WebState extension missing from request; \
             the boot path forgot to attach it before the auth layer"
        );
        return internal_error("Authentication backend not configured");
    };

    let already_authenticated = request.extensions().get::<AuthenticatedUser>().is_some();
    let session = request
        .extensions()
        .get::<tower_sessions::Session>()
        .cloned();
    let api_key = extract_api_key(&request);
    let request = request;

    if already_authenticated {
        return next.run(request).await;
    }

    // Session-cookie path: a logged-in browser may hit the same
    // endpoints from a server-rendered page. Look up the user_id from
    // the tower-sessions Session extension attached at the merged-router
    // level.
    if let Some(user_id) = session_user_id(session.as_ref()).await {
        return finalize_with_auth(request, next, user_id, AuthSource::Session).await;
    }

    let Some(api_key) = api_key else {
        return unauthorized("API key required");
    };

    match verify_api_key_db(&state.db, &api_key).await {
        Ok(Some(user_id)) => finalize_with_auth(request, next, user_id, AuthSource::ApiKey).await,
        Ok(None) => unauthorized("Invalid API key"),
        Err(err) => {
            tracing::error!(error = ?err, "api_key_auth db lookup failed");
            internal_error("Authentication backend error")
        }
    }
}

/// `:media_api_auth` pipeline port. Same as [`api_key_auth`] but with
/// a media-token bearer JWT path added in front. Order matches
/// Phoenix's `pipeline :media_api_auth`: `AuthPipeline` (session) →
/// `ApiAuth` (`X-API-Key`) → `MediaAuth` (bearer token). A caller with
/// any one of the three is allowed through; only the union fails 401.
pub async fn media_token_auth(request: Request, next: Next) -> Response {
    let Some(state) = request.extensions().get::<WebState>().cloned() else {
        tracing::error!(
            "media_token_auth: WebState extension missing from request; \
             the boot path forgot to attach it before the auth layer"
        );
        return internal_error("Authentication backend not configured");
    };

    let already_authenticated = request.extensions().get::<AuthenticatedUser>().is_some();
    let session = request
        .extensions()
        .get::<tower_sessions::Session>()
        .cloned();
    let api_key = extract_api_key(&request);
    let bearer = extract_bearer_token(&request);
    let request = request;

    if already_authenticated {
        return next.run(request).await;
    }

    if let Some(user_id) = session_user_id(session.as_ref()).await {
        return finalize_with_auth(request, next, user_id, AuthSource::Session).await;
    }

    // API key path next.
    if let Some(api_key) = api_key {
        return match verify_api_key_db(&state.db, &api_key).await {
            Ok(Some(user_id)) => {
                finalize_with_auth(request, next, user_id, AuthSource::ApiKey).await
            }
            Ok(None) => unauthorized("Invalid API key"),
            Err(err) => {
                tracing::error!(error = ?err, "media_token_auth api-key lookup failed");
                internal_error("Authentication backend error")
            }
        };
    }

    // Finally, media-token JWT path.
    let Some(token) = bearer else {
        return unauthorized("Authentication required");
    };

    let Some(signer) = state.media_signer.as_ref() else {
        // Boot path didn't wire a signer — no token can verify.
        // 401 (not 500) because operator-facing config has not been
        // satisfied; the player will surface the same diagnostic
        // either way.
        tracing::warn!(
            "media_token_auth: token presented but no MediaTokenSigner configured; \
             rejecting with 401"
        );
        return unauthorized("Media tokens not configured on this server");
    };

    let verify_result = match state.media_token_cache.as_ref() {
        Some(cache) => cache.lookup_or_verify(signer, &token),
        None => signer.verify(&token),
    };

    match verify_result {
        Ok(claims) => {
            let user_id = claims.user_id.clone();
            let mut request = request;
            request.extensions_mut().insert(AuthenticatedUser {
                user_id,
                source: AuthSource::MediaToken,
            });
            request
                .extensions_mut()
                .insert(MediaTokenContext { claims });
            next.run(request).await
        }
        Err(mydia_rs_auth::MediaTokenError::Expired) => unauthorized("Token expired"),
        Err(mydia_rs_auth::MediaTokenError::WrongType) => unauthorized("Invalid token type"),
        Err(err) => {
            tracing::debug!(error = ?err, "media token verification failed");
            unauthorized("Invalid token")
        }
    }
}

/// `:require_admin` pipeline port. Must follow [`api_key_auth`] (or a
/// session-attaching layer) on the same router; if no
/// [`AuthenticatedUser`] is present, responds with `401`. If present
/// but the user's role isn't `admin`, responds with `403`.
pub async fn require_admin(request: Request, next: Next) -> Response {
    let Some(state) = request.extensions().get::<WebState>().cloned() else {
        tracing::error!(
            "require_admin: WebState extension missing from request; \
             the boot path forgot to attach it before the auth layer"
        );
        return internal_error("Authentication backend not configured");
    };

    let Some(user) = request.extensions().get::<AuthenticatedUser>().cloned() else {
        return unauthorized("Authentication required");
    };

    let user_id = user.user_id.clone();
    match lookup_user_role(&state.db, &user_id).await {
        Ok(Some(role)) if role == "admin" => next.run(request).await,
        Ok(Some(_)) => forbidden("Admin role required"),
        Ok(None) => unauthorized("Authentication required"),
        Err(err) => {
            tracing::error!(error = ?err, user_id = %user_id, "require_admin role lookup failed");
            internal_error("Authentication backend error")
        }
    }
}

/// Insert an [`AuthenticatedUser`] marker into the request extensions
/// and forward to `next`. Pulled out so the three auth pipelines
/// share the final-step machinery.
async fn finalize_with_auth(
    mut request: Request,
    next: Next,
    user_id: String,
    source: AuthSource,
) -> Response {
    request
        .extensions_mut()
        .insert(AuthenticatedUser { user_id, source });
    next.run(request).await
}

// ---------------------------------------------------------------------
// Internals — extraction + verification helpers.
// ---------------------------------------------------------------------

fn extract_api_key(request: &Request) -> Option<String> {
    if let Some(value) = request.headers().get("x-api-key") {
        if let Ok(s) = value.to_str() {
            if !s.is_empty() {
                return Some(s.to_string());
            }
        }
    }
    // Query string fallback: parse manually so we don't pay for a full
    // serde_urlencoded::from_str roundtrip on every request.
    let query = request.uri().query()?;
    for pair in query.split('&') {
        let mut iter = pair.splitn(2, '=');
        let key = iter.next()?;
        if key == "api_key" {
            let value = iter.next()?;
            let decoded = urlencoding_decode(value);
            if !decoded.is_empty() {
                return Some(decoded);
            }
        }
    }
    None
}

fn extract_bearer_token(request: &Request) -> Option<String> {
    if let Some(value) = request.headers().get(header::AUTHORIZATION) {
        if let Ok(s) = value.to_str() {
            if let Some(rest) = s.strip_prefix("Bearer ") {
                if !rest.is_empty() {
                    return Some(rest.to_string());
                }
            }
        }
    }
    let query = request.uri().query()?;
    for pair in query.split('&') {
        let mut iter = pair.splitn(2, '=');
        let key = iter.next()?;
        if key == "token" {
            let value = iter.next()?;
            let decoded = urlencoding_decode(value);
            if !decoded.is_empty() {
                return Some(decoded);
            }
        }
    }
    None
}

/// Minimal percent-decoding for query-string values. Avoids pulling
/// the full `percent-encoding` crate in for a single use site.
fn urlencoding_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                let hi = hex_digit(bytes[i + 1]);
                let lo = hex_digit(bytes[i + 2]);
                if let (Some(hi), Some(lo)) = (hi, lo) {
                    out.push(char::from(hi * 16 + lo));
                    i += 3;
                    continue;
                }
                out.push('%');
                i += 1;
            }
            b'+' => {
                out.push(' ');
                i += 1;
            }
            b => {
                out.push(char::from(b));
                i += 1;
            }
        }
    }
    out
}

fn hex_digit(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

/// Verify an API key by scanning the `api_keys` table.
///
/// Mirrors `Mydia.Accounts.verify_api_key/1`: load every non-revoked,
/// non-expired row, Argon2-verify the plaintext against each
/// `key_hash`, return the owning `user_id` on the first match. This is
/// O(n) over the key set, same as Phoenix; the dataset is small (one
/// row per operator-issued key) so the cost is acceptable. A
/// hashed-prefix lookup is a future optimization.
async fn verify_api_key_db(
    db: &DatabaseConnection,
    plaintext: &str,
) -> Result<Option<String>, sea_orm::DbErr> {
    // Pull the candidate set and filter in Rust — the
    // `DateTimeSecs` wrapper round-trips uniformly across engines, so
    // the in-Rust timestamp comparison is engine-agnostic.
    let rows = api_keys::Entity::find().all(db).await?;
    let now = chrono::Utc::now();
    for row in rows {
        if row.revoked_at.is_some() {
            continue;
        }
        if row.expires_at.is_some_and(|exp| exp.0 <= now) {
            continue;
        }
        if verify_api_key_hash(plaintext, &row.key_hash).is_ok() {
            return Ok(Some(row.user_id.to_string()));
        }
    }
    Ok(None)
}

async fn lookup_user_role(
    db: &DatabaseConnection,
    user_id: &str,
) -> Result<Option<String>, sea_orm::DbErr> {
    let Ok(uuid) = uuid::Uuid::parse_str(user_id) else {
        return Ok(None);
    };
    let wrapper = mydia_rs_db::types::UuidText::from(uuid);
    let backend = db.get_database_backend();
    let row = users::Entity::find()
        .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await?;
    Ok(row.map(|u| u.role))
}

/// Read the session cookie (if any) and return the user id stored
/// under [`SESSION_KEY_USER_ID`]. Returns `None` when no session is
/// attached (e.g. pure-API caller with only the header) or when the
/// session exists but no user-id key is set.
///
/// Takes a cloned `Option<Session>` (rather than `&Request`) so the
/// future stays `Send` — holding `&Request` across an `.await` poisons
/// the auto-Send impl on the enclosing async fn because `Body` is `!Sync`.
async fn session_user_id(session: Option<&tower_sessions::Session>) -> Option<String> {
    let session = session?;
    match session.get::<String>(SESSION_KEY_USER_ID).await {
        Ok(value) => value,
        Err(err) => {
            tracing::debug!(error = ?err, "session read failed in auth_layer");
            None
        }
    }
}

fn unauthorized(message: &str) -> Response {
    let body = json!({"error": "Unauthorized", "message": message});
    (StatusCode::UNAUTHORIZED, Json(body)).into_response()
}

fn forbidden(message: &str) -> Response {
    let body = json!({"error": "Forbidden", "message": message});
    (StatusCode::FORBIDDEN, Json(body)).into_response()
}

fn internal_error(message: &str) -> Response {
    let body = json!({"error": "Internal Server Error", "message": message});
    (StatusCode::INTERNAL_SERVER_ERROR, Json(body)).into_response()
}
