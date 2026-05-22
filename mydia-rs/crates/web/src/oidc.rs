//! OIDC PKCE login flow (U24.c).
//!
//! Two axum endpoints under `/auth/oidc/`:
//!
//! - `GET /auth/oidc/login` — generates a fresh PKCE verifier, CSRF
//!   token, and nonce, stores them on the tower-sessions session, and
//!   responds with a 302 to the provider's authorization URL.
//! - `GET /auth/oidc/callback` — receives `code` and `state` from the
//!   provider, validates `state` matches the session, exchanges the
//!   code for tokens (sending the PKCE verifier), verifies the id-token
//!   nonce, upserts the user row (keyed by `oidc_sub` + `oidc_issuer`),
//!   writes `user_id` into the session, and 302s to `/`.
//!
//! Provider metadata is discovered once at boot — both `OIDC_ISSUER`
//! (`.well-known/openid-configuration` is appended automatically) and
//! the explicit `OIDC_DISCOVERY_DOCUMENT_URI` route to
//! [`CoreProviderMetadata::discover_async`]. If discovery fails we
//! log and return `None` so the rest of the app boots without OIDC.
//!
//! Authelia 4.39+ note: openidconnect 3.x's authorization URL is a
//! plain query-param redirect — no PAR, no JAR — so the
//! `oidc_disable_par` config field is effectively a no-op against the
//! current API. The field is preserved on `WebState` for parity with
//! the Phoenix-side `RuntimeUeberauth` semantics, and to give us a
//! clean place to add the workaround if a future openidconnect minor
//! starts auto-enabling PAR when the provider advertises it.
//!
//! The module-level `#[cfg(feature = "server")]` in `lib.rs` is the
//! single source of truth for gating this file behind the server
//! build; we don't repeat `#![cfg(...)]` here.

use axum::extract::{Extension, Query};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::get;
use axum::Router;
use openidconnect::core::{
    CoreAuthenticationFlow, CoreClient, CoreGenderClaim, CoreProviderMetadata,
};
use openidconnect::reqwest::async_http_client;
use openidconnect::{
    AuthorizationCode, ClientId, ClientSecret, CsrfToken, EmptyAdditionalClaims, IdTokenClaims,
    IssuerUrl, Nonce, PkceCodeChallenge, PkceCodeVerifier, RedirectUrl, Scope, TokenResponse,
};
use serde::{Deserialize, Serialize};
use tower_sessions::Session;

use crate::server_state::WebState;
use crate::session::SESSION_KEY_USER_ID;

/// Session keys used during the PKCE flow. All three are cleared on
/// callback success so a replay of the same callback URL fails.
const SESSION_KEY_OIDC_PKCE_VERIFIER: &str = "oidc.pkce_verifier";
const SESSION_KEY_OIDC_CSRF_STATE: &str = "oidc.csrf_state";
const SESSION_KEY_OIDC_NONCE: &str = "oidc.nonce";

/// Settings the app crate hands the web crate at boot. Kept as a
/// plain struct rather than re-exporting `mydia_rs_config` so the
/// web crate doesn't need a circular dep on the config crate just to
/// know what an `OidcSettings` looks like.
#[derive(Debug, Clone)]
pub struct OidcSettings {
    /// Issuer URL (e.g. `https://auth.example.com/`). One of
    /// `issuer` or `discovery_document_uri` must be set.
    pub issuer: Option<String>,
    /// Explicit discovery document URL — overrides the issuer's
    /// `.well-known/openid-configuration` default when set.
    pub discovery_document_uri: Option<String>,
    pub client_id: String,
    pub client_secret: String,
    /// Where the provider should POST/GET the code back to. Must
    /// match the value registered with the provider exactly.
    pub redirect_uri: String,
    /// Space-separated scope list (e.g. `"openid profile email"`).
    pub scopes: String,
    /// Authelia 4.39+ kill-switch — see module-level doc.
    pub disable_par: bool,
}

/// Built-once OIDC client carried by [`WebState`]. Cloning is cheap
/// (the inner `CoreClient` is itself cheap to clone — small enums
/// and strings).
#[derive(Clone)]
pub struct OidcContext {
    client: CoreClient,
    scopes: Vec<Scope>,
}

impl OidcContext {
    /// Discover the provider metadata and build a configured OIDC
    /// client. Returns `None` (with a logged error) on any failure
    /// — the rest of the app boots without OIDC in that case.
    pub async fn try_build(settings: &OidcSettings) -> Option<Self> {
        let Some(issuer_str) = settings
            .discovery_document_uri
            .as_deref()
            .or(settings.issuer.as_deref())
        else {
            tracing::error!("OIDC enabled but neither issuer nor discovery_document_uri set");
            return None;
        };
        let issuer_url = match IssuerUrl::new(issuer_str.to_owned()) {
            Ok(u) => u,
            Err(err) => {
                tracing::error!(%err, value = issuer_str, "invalid OIDC issuer URL");
                return None;
            }
        };

        let metadata =
            match CoreProviderMetadata::discover_async(issuer_url, async_http_client).await {
                Ok(m) => m,
                Err(err) => {
                    tracing::error!(%err, "OIDC provider metadata discovery failed");
                    return None;
                }
            };

        let redirect = match RedirectUrl::new(settings.redirect_uri.clone()) {
            Ok(u) => u,
            Err(err) => {
                tracing::error!(%err, "invalid OIDC redirect URI");
                return None;
            }
        };

        let client = CoreClient::from_provider_metadata(
            metadata,
            ClientId::new(settings.client_id.clone()),
            Some(ClientSecret::new(settings.client_secret.clone())),
        )
        .set_redirect_uri(redirect);

        let scopes = settings
            .scopes
            .split_whitespace()
            .map(|s| Scope::new(s.to_owned()))
            .collect::<Vec<_>>();

        if settings.disable_par {
            // No-op against openidconnect 3.x (no PAR support). Logged
            // so the operator can confirm their kill-switch was read.
            tracing::info!("OIDC_DISABLE_PAR is set; openidconnect 3.x never uses PAR — no-op");
        }

        Some(Self { client, scopes })
    }
}

/// Mount the `/auth/oidc/login` and `/auth/oidc/callback` routes
/// onto a router. Both routes pull the active `WebState` via
/// `Extension`, which carries the optional `OidcContext`. Routes
/// remain registered even when OIDC is disabled — they return a
/// 503-shaped redirect to `/login?error=oidc_disabled` so callers
/// reaching them via a stale config get a clean failure mode.
pub fn router() -> Router {
    Router::new()
        .route("/auth/oidc/login", get(login_handler))
        .route("/auth/oidc/callback", get(callback_handler))
}

async fn login_handler(Extension(state): Extension<WebState>, session: Session) -> Response {
    let Some(ctx) = state.oidc.clone() else {
        return Redirect::to("/login?error=oidc_disabled").into_response();
    };

    let (pkce_challenge, pkce_verifier) = PkceCodeChallenge::new_random_sha256();

    let mut authorize_url = ctx.client.authorize_url(
        CoreAuthenticationFlow::AuthorizationCode,
        CsrfToken::new_random,
        Nonce::new_random,
    );
    for scope in &ctx.scopes {
        authorize_url = authorize_url.add_scope(scope.clone());
    }
    let (auth_url, csrf_state, nonce) = authorize_url.set_pkce_challenge(pkce_challenge).url();

    // Stash everything the callback needs to verify in the session.
    // tower-sessions's set_inactivity_expiry isn't reset here — the
    // existing one-week window is plenty for a redirect round trip.
    if let Err(err) = session
        .insert(
            SESSION_KEY_OIDC_PKCE_VERIFIER,
            pkce_verifier.secret().to_owned(),
        )
        .await
    {
        tracing::error!(%err, "session insert pkce_verifier");
        return oidc_error_redirect("session_write_failed");
    }
    if let Err(err) = session
        .insert(SESSION_KEY_OIDC_CSRF_STATE, csrf_state.secret().to_owned())
        .await
    {
        tracing::error!(%err, "session insert csrf_state");
        return oidc_error_redirect("session_write_failed");
    }
    if let Err(err) = session
        .insert(SESSION_KEY_OIDC_NONCE, nonce.secret().to_owned())
        .await
    {
        tracing::error!(%err, "session insert nonce");
        return oidc_error_redirect("session_write_failed");
    }

    Redirect::to(auth_url.as_ref()).into_response()
}

/// Provider-supplied query params on the redirect. Either `code +
/// state` (happy path) or `error + error_description` (auth denial,
/// invalid request, etc.).
#[derive(Debug, Deserialize)]
struct CallbackParams {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

async fn callback_handler(
    Extension(state): Extension<WebState>,
    session: Session,
    Query(params): Query<CallbackParams>,
) -> Response {
    let Some(ctx) = state.oidc.clone() else {
        return Redirect::to("/login?error=oidc_disabled").into_response();
    };

    if let Some(err) = params.error {
        let detail = params.error_description.as_deref().unwrap_or("");
        tracing::warn!(error = %err, description = %detail, "OIDC callback returned provider error");
        return oidc_error_redirect("provider_error");
    }

    let (Some(code), Some(returned_state)) = (params.code, params.state) else {
        tracing::warn!("OIDC callback missing code or state");
        return oidc_error_redirect("missing_code");
    };

    // Read + clear the three pending session entries. Cleared even
    // on failure so a single PKCE verifier is never reused.
    let stored_state = take_session_string(&session, SESSION_KEY_OIDC_CSRF_STATE).await;
    let stored_verifier = take_session_string(&session, SESSION_KEY_OIDC_PKCE_VERIFIER).await;
    let stored_nonce = take_session_string(&session, SESSION_KEY_OIDC_NONCE).await;

    let (Some(stored_state), Some(stored_verifier), Some(stored_nonce)) =
        (stored_state, stored_verifier, stored_nonce)
    else {
        tracing::warn!("OIDC callback fired but no in-flight session state found");
        return oidc_error_redirect("missing_session_state");
    };

    // Constant-time CSRF compare — though for OAuth state values the
    // entropy is high enough that timing-equality is more discipline
    // than necessity.
    if !constant_time_eq(stored_state.as_bytes(), returned_state.as_bytes()) {
        tracing::warn!("OIDC callback state mismatch");
        return oidc_error_redirect("state_mismatch");
    }

    let token_response = match ctx
        .client
        .exchange_code(AuthorizationCode::new(code))
        .set_pkce_verifier(PkceCodeVerifier::new(stored_verifier))
        .request_async(async_http_client)
        .await
    {
        Ok(tr) => tr,
        Err(err) => {
            tracing::error!(%err, "OIDC token exchange failed");
            return oidc_error_redirect("token_exchange_failed");
        }
    };

    let Some(id_token) = token_response.id_token() else {
        tracing::error!("OIDC token response missing id_token");
        return oidc_error_redirect("missing_id_token");
    };

    let claims = match id_token.claims(&ctx.client.id_token_verifier(), &Nonce::new(stored_nonce)) {
        Ok(c) => c,
        Err(err) => {
            tracing::error!(%err, "OIDC id_token verification failed");
            return oidc_error_redirect("id_token_invalid");
        }
    };

    let user_payload = match extract_user_payload(claims) {
        Ok(p) => p,
        Err(err) => {
            tracing::error!(%err, "OIDC claims missing required fields");
            return oidc_error_redirect("invalid_claims");
        }
    };

    let user_id = match crate::server_fns::auth::upsert_oidc_user(&state.db, &user_payload).await {
        Ok(id) => id,
        Err(err) => {
            tracing::error!(%err, "OIDC user upsert failed");
            return oidc_error_redirect("user_upsert_failed");
        }
    };

    // Fix session fixation: cycle the id before we associate the
    // freshly-authenticated user. Same discipline as the password
    // login path.
    if let Err(err) = session.cycle_id().await {
        tracing::error!(%err, "OIDC session cycle_id failed");
        return oidc_error_redirect("session_write_failed");
    }
    if let Err(err) = session.insert(SESSION_KEY_USER_ID, &user_id).await {
        tracing::error!(%err, "OIDC session insert user_id failed");
        return oidc_error_redirect("session_write_failed");
    }

    Redirect::to("/").into_response()
}

/// Constant-time bytewise comparison. Equal length, then xor-fold.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

async fn take_session_string(session: &Session, key: &str) -> Option<String> {
    let value = session.get::<String>(key).await.ok().flatten();
    let _ = session.remove::<serde_json::Value>(key).await;
    value
}

fn oidc_error_redirect(code: &str) -> Response {
    // Keep error codes URL-safe and short — they show up in the
    // login page's URL bar; the login page renders a friendlier
    // message keyed by the code in a follow-up unit.
    Redirect::to(&format!("/login?error={code}")).into_response()
}

/// Required user fields extracted from the verified id-token claims.
/// Mirrors `process_oidc_auth/1` in `auth_controller.ex` field-for-field.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OidcUserPayload {
    pub sub: String,
    pub issuer: String,
    pub email: Option<String>,
    pub display_name: Option<String>,
    pub avatar_url: Option<String>,
    pub role: String,
}

fn extract_user_payload(
    claims: &IdTokenClaims<EmptyAdditionalClaims, CoreGenderClaim>,
) -> Result<OidcUserPayload, &'static str> {
    let sub = claims.subject().as_str().to_owned();
    if sub.is_empty() {
        return Err("missing sub");
    }
    let issuer = claims.issuer().as_str().to_owned();
    let email = claims.email().map(|e| e.as_str().to_owned());

    // `name` on standard OIDC claims; fall back to email or sub for
    // a never-empty display string. Mirrors the Phoenix path
    // (`auth.info.name || auth.info.email`).
    let display_name = claims
        .name()
        .and_then(|n| n.get(None).map(|s| s.as_str().to_owned()))
        .or_else(|| email.clone());

    let avatar_url = claims
        .picture()
        .and_then(|p| p.get(None).map(|s| s.as_str().to_owned()));

    // Phoenix's `determine_role/1` reads `roles` and `groups` from the
    // userinfo extra struct. openidconnect surfaces those via the
    // claims' `additional_claims()` extension point, which requires a
    // custom `AdditionalClaims` impl. For U24.c we ship a sensible
    // default (`"user"`) — full role-mapping (admin/user/readonly)
    // lives behind a typed `MydiaAdditionalClaims` struct as a
    // follow-up; the existing admin can grant elevated roles via the
    // admin users page once it lands in U28.
    let role = "user".to_owned();

    Ok(OidcUserPayload {
        sub,
        issuer,
        email,
        display_name,
        avatar_url,
        role,
    })
}
