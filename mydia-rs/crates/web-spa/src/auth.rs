use axum::extract::{Extension, Query};
use axum::response::{IntoResponse, Redirect, Response};
use axum::routing::{get, post};
use axum::Router;
use openidconnect::core::CoreAuthenticationFlow;
use openidconnect::core::CoreGenderClaim;
use openidconnect::reqwest::async_http_client;
use openidconnect::{
    AuthorizationCode, CsrfToken, EmptyAdditionalClaims, IdTokenClaims, Nonce, PkceCodeChallenge,
    PkceCodeVerifier, TokenResponse,
};
use serde::{Deserialize, Serialize};
use tower_sessions::Session;

use crate::server_state::SpaState;
use crate::session_config::SESSION_KEY_USER_ID;

const SESSION_KEY_OIDC_PKCE_VERIFIER: &str = "oidc.pkce_verifier";
const SESSION_KEY_OIDC_CSRF_STATE: &str = "oidc.csrf_state";
const SESSION_KEY_OIDC_NONCE: &str = "oidc.nonce";

pub fn router() -> Router {
    Router::new()
        .route("/auth/oidc/login", get(login_handler))
        .route("/auth/oidc/callback", get(callback_handler))
        .route("/auth/logout", post(logout_handler))
}

async fn login_handler(Extension(state): Extension<SpaState>, session: Session) -> Response {
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

#[derive(Debug, Deserialize)]
struct CallbackParams {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
    error_description: Option<String>,
}

async fn callback_handler(
    Extension(state): Extension<SpaState>,
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

    let stored_state = take_session_string(&session, SESSION_KEY_OIDC_CSRF_STATE).await;
    let stored_verifier = take_session_string(&session, SESSION_KEY_OIDC_PKCE_VERIFIER).await;
    let stored_nonce = take_session_string(&session, SESSION_KEY_OIDC_NONCE).await;

    let (Some(stored_state), Some(stored_verifier), Some(stored_nonce)) =
        (stored_state, stored_verifier, stored_nonce)
    else {
        tracing::warn!("OIDC callback fired but no in-flight session state found");
        return oidc_error_redirect("missing_session_state");
    };

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

    let user_id = match upsert_oidc_user(&state.db, &user_payload).await {
        Ok(id) => id,
        Err(err) => {
            tracing::error!(%err, "OIDC user upsert failed");
            return oidc_error_redirect("user_upsert_failed");
        }
    };

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

async fn logout_handler(session: Session) -> Response {
    let _ = session.delete().await;
    Redirect::to("/login").into_response()
}

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
    Redirect::to(&format!("/login?error={code}")).into_response()
}

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

    let display_name = claims
        .name()
        .and_then(|n| n.get(None).map(|s| s.as_str().to_owned()))
        .or_else(|| email.clone());

    let avatar_url = claims
        .picture()
        .and_then(|p| p.get(None).map(|s| s.as_str().to_owned()));

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

async fn upsert_oidc_user(
    db: &mydia_rs_db::DatabaseConnection,
    payload: &OidcUserPayload,
) -> Result<String, String> {
    use mydia_rs_db::insert_active_model;
    use mydia_rs_db::types::{DateTimeSecs, UuidText};
    use mydia_rs_entities::users;
    use sea_orm::entity::prelude::*;
    use sea_orm::sea_query::ExprTrait;
    use sea_orm::Set;

    let existing = users::Entity::find()
        .filter(users::Column::OidcSub.eq(payload.sub.clone()))
        .filter(users::Column::OidcIssuer.eq(payload.issuer.clone()))
        .one(db)
        .await
        .map_err(|err| format!("lookup oidc user: {err}"))?;

    let now = chrono::Utc::now();
    let now_wrapper = DateTimeSecs::from(now);

    if let Some(existing_row) = existing {
        let backend = db.get_database_backend();
        users::Entity::update_many()
            .col_expr(
                users::Column::Email,
                sea_orm::sea_query::Expr::value(payload.email.clone()),
            )
            .col_expr(
                users::Column::DisplayName,
                sea_orm::sea_query::Expr::value(payload.display_name.clone()),
            )
            .col_expr(
                users::Column::AvatarUrl,
                sea_orm::sea_query::Expr::value(payload.avatar_url.clone()),
            )
            .col_expr(
                users::Column::LastLoginAt,
                now_wrapper.into_simple_expr(backend),
            )
            .col_expr(
                users::Column::UpdatedAt,
                now_wrapper.into_simple_expr(backend),
            )
            .filter(
                sea_orm::sea_query::Expr::col(users::Column::Id)
                    .eq(existing_row.id.into_simple_expr(backend)),
            )
            .exec(db)
            .await
            .map_err(|err| format!("update oidc user: {err}"))?;
        return Ok(existing_row.id.to_string());
    }

    let id_uuid = uuid::Uuid::new_v4();
    let id = UuidText::from(id_uuid);

    let am = users::ActiveModel {
        id: Set(id),
        username: Set(None),
        email: Set(payload.email.clone()),
        password_hash: Set(None),
        oidc_sub: Set(Some(payload.sub.clone())),
        oidc_issuer: Set(Some(payload.issuer.clone())),
        role: Set(payload.role.clone()),
        display_name: Set(payload.display_name.clone()),
        avatar_url: Set(payload.avatar_url.clone()),
        last_login_at: Set(Some(now_wrapper)),
        inserted_at: Set(now_wrapper),
        updated_at: Set(now_wrapper),
    };
    insert_active_model(am, db)
        .await
        .map_err(|err| format!("insert oidc user: {err}"))?;

    Ok(id_uuid.to_string())
}
