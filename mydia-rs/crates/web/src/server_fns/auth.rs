//! Authentication server functions for U24.a (auth UI).
//!
//! Mirrors `MydiaWeb.SessionController` + `MydiaWeb.FirstTimeSetupLive`
//! but with tower-sessions as the session backend instead of Plug
//! signed cookies. Three endpoints land here:
//!
//! - [`login_with_password`] — bcrypt verify against
//!   `users.password_hash`, write `user_id` into the session, update
//!   `last_login_at`.
//! - [`logout`] — clear the session (deletes the row + the cookie).
//! - [`setup_admin`] — create the initial admin user if the `users`
//!   table is empty, then sign them in. Mirrors
//!   `FirstTimeSetupLive`'s `handle_event("create_admin", ...)` minus
//!   the random-password mode (deferred to U24.b).
//!
//! OIDC PKCE flow lands separately in U24.b.

use dioxus::fullstack::ServerFnError;
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Wire payload for a password login attempt.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LoginPayload {
    pub username: String,
    pub password: String,
}

/// Wire payload for first-time admin setup.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SetupPayload {
    pub username: String,
    pub email: String,
    pub password: String,
}

/// Small DTO returned by the auth server fns. The page redirects on
/// success and renders the message on failure.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct AuthAck {
    pub user_id: String,
    pub username: Option<String>,
    pub role: String,
}

#[get("/api/auth/me")]
pub async fn current_user() -> Result<Option<AuthAck>, ServerFnError> {
    server::current_user().await
}

#[post("/api/auth/login")]
pub async fn login_with_password(payload: LoginPayload) -> Result<AuthAck, ServerFnError> {
    server::login(payload).await
}

#[post("/api/auth/logout")]
pub async fn logout() -> Result<(), ServerFnError> {
    server::logout().await
}

#[post("/api/auth/setup")]
pub async fn setup_admin(payload: SetupPayload) -> Result<AuthAck, ServerFnError> {
    server::setup(payload).await
}

#[get("/api/auth/setup-required")]
pub async fn setup_required() -> Result<bool, ServerFnError> {
    server::setup_required().await
}

/// Client-side check used by the login page to decide whether to
/// render the OIDC button. Returns `true` iff [`WebState::oidc`] was
/// successfully discovered at boot.
#[get("/api/auth/oidc-available")]
pub async fn oidc_available() -> Result<bool, ServerFnError> {
    server::oidc_available().await
}

/// Server-side helper used by [`crate::oidc::callback_handler`] to
/// upsert a user freshly authenticated via OIDC. Exposed at the
/// module boundary so the raw axum callback doesn't need to reach
/// into the server-fn private module path.
#[cfg(feature = "server")]
pub async fn upsert_oidc_user(
    db: &mydia_rs_db::Db,
    payload: &crate::oidc::OidcUserPayload,
) -> Result<String, ServerFnError> {
    server::upsert_oidc_user(db, payload).await
}

/// Server-side helper: pull the logged-in user's id out of the
/// session, or surface a 401-shaped `ServerFnError` if the request
/// is anonymous. Every server fn that mutates user-owned state (e.g.
/// the `library_paths` CRUD endpoints) should call this first.
#[cfg(feature = "server")]
pub async fn require_session_user_id() -> Result<String, ServerFnError> {
    server::require_session_user_id().await
}

/// Server-side helper used by every admin server fn — pulls the
/// session user, looks the row up, and verifies `role == "admin"`.
/// Returns the user id on success; a `not authorized` `ServerFnError`
/// otherwise (the page renders this inline). The 401-vs-403 distinction
/// is collapsed for the same reason
/// [`require_session_user_id`] collapses logged-out and session-expired.
#[cfg(feature = "server")]
pub async fn require_admin_user_id() -> Result<String, ServerFnError> {
    server::require_admin_user_id().await
}

#[cfg(feature = "server")]
mod server {
    use super::{AuthAck, LoginPayload, SetupPayload};
    use crate::server_state::WebState;
    use crate::session::SESSION_KEY_USER_ID;
    use dioxus::fullstack::{FullstackContext, ServerFnError};
    use mydia_rs_auth::password::{hash_password, verify_password, PasswordError};
    use mydia_rs_db::Db;
    use tower_sessions::Session;

    pub(crate) async fn require_session_user_id() -> Result<String, ServerFnError> {
        let session = session_handle().await?;
        let Some(user_id) = session
            .get::<String>(SESSION_KEY_USER_ID)
            .await
            .map_err(|err| ServerFnError::new(format!("session read: {err}")))?
        else {
            // Don't reveal that the session was simply missing —
            // operator-facing pages render the same way for "logged
            // out" and "session expired" so a 401-shaped error works
            // for both.
            return Err(ServerFnError::new("not authenticated"));
        };
        Ok(user_id)
    }

    pub(crate) async fn require_admin_user_id() -> Result<String, ServerFnError> {
        let user_id = require_session_user_id().await?;
        let st = state().await?;
        let role = lookup_user_role(&st.db, &user_id).await?;
        if role.as_deref() == Some("admin") {
            Ok(user_id)
        } else {
            Err(ServerFnError::new("not authorized"))
        }
    }

    async fn lookup_user_role(db: &Db, id: &str) -> Result<Option<String>, ServerFnError> {
        let row: Option<(String,)> = match db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT role FROM users WHERE id = ? LIMIT 1")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("lookup role: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as("SELECT role FROM users WHERE id = $1 LIMIT 1")
                .bind(id)
                .fetch_optional(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("lookup role: {err}")))?,
        };
        Ok(row.map(|(role,)| role))
    }

    /// Server-fn-helpers that the dual-target functions delegate to.
    pub(super) async fn state() -> Result<WebState, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context"))?;
        ctx.extension::<WebState>()
            .ok_or_else(|| ServerFnError::new("WebState extension missing"))
    }

    async fn session_handle() -> Result<Session, ServerFnError> {
        FullstackContext::extract::<Session, _>()
            .await
            .map_err(|err| ServerFnError::new(format!("session unavailable: {err}")))
    }

    pub(super) async fn current_user() -> Result<Option<AuthAck>, ServerFnError> {
        let session = session_handle().await?;
        let Some(user_id) = session
            .get::<String>(SESSION_KEY_USER_ID)
            .await
            .map_err(|err| ServerFnError::new(format!("session read: {err}")))?
        else {
            return Ok(None);
        };
        let st = state().await?;
        match load_user_brief(&st.db, &user_id).await {
            Ok(Some(ack)) => Ok(Some(ack)),
            Ok(None) => {
                // The user row went away between login and this read
                // (admin deleted them, for example). Clear the
                // dangling session so the page redirects to /login on
                // the next paint.
                let _ = session.delete().await;
                Ok(None)
            }
            Err(err) => Err(err),
        }
    }

    pub(super) async fn login(payload: LoginPayload) -> Result<AuthAck, ServerFnError> {
        let username = payload.username.trim();
        if username.is_empty() || payload.password.is_empty() {
            return Err(ServerFnError::new("Invalid username or password"));
        }
        let st = state().await?;

        let row = lookup_user_for_login(&st.db, username).await?;
        let Some((id, db_username, password_hash, role)) = row else {
            // Indistinguishable from "wrong password" by design — we
            // do not leak which side failed.
            return Err(ServerFnError::new("Invalid username or password"));
        };

        let Some(hash) = password_hash else {
            // OIDC-only users (no password set) hit this path. Mirror
            // Phoenix's `verify_password(_, _) -> false` clause.
            return Err(ServerFnError::new("Invalid username or password"));
        };

        match verify_password(&payload.password, &hash) {
            Ok(()) => {}
            Err(PasswordError::Mismatch) => {
                return Err(ServerFnError::new("Invalid username or password"));
            }
            Err(err) => {
                tracing::warn!(%err, "password verify failed unexpectedly");
                return Err(ServerFnError::new("Invalid username or password"));
            }
        }

        touch_last_login(&st.db, &id).await?;

        let session = session_handle().await?;
        // tower-sessions cycles the session id on successful login —
        // this protects against session fixation (an attacker who
        // pre-set the cookie can't reuse it after the victim authenticates).
        session
            .cycle_id()
            .await
            .map_err(|err| ServerFnError::new(format!("session cycle_id: {err}")))?;
        session
            .insert(SESSION_KEY_USER_ID, &id)
            .await
            .map_err(|err| ServerFnError::new(format!("session insert: {err}")))?;

        Ok(AuthAck {
            user_id: id,
            username: Some(db_username),
            role,
        })
    }

    pub(super) async fn logout() -> Result<(), ServerFnError> {
        let session = session_handle().await?;
        session
            .delete()
            .await
            .map_err(|err| ServerFnError::new(format!("session delete: {err}")))?;
        Ok(())
    }

    pub(super) async fn setup_required() -> Result<bool, ServerFnError> {
        let st = state().await?;
        Ok(count_users(&st.db).await? == 0)
    }

    pub(super) async fn oidc_available() -> Result<bool, ServerFnError> {
        let st = state().await?;
        Ok(st.oidc_available())
    }

    /// Upsert an OIDC-authenticated user.
    ///
    /// Mirrors `Mydia.Accounts.upsert_user_from_oidc/3`:
    ///   1. If a user already exists with the same `(oidc_sub,
    ///      oidc_issuer)` pair, update the mutable identity fields
    ///      (`email`, `display_name`, `avatar_url`) and return their id.
    ///   2. Otherwise insert a fresh row keyed by a new UUID.
    ///
    /// The role assignment falls back to `"user"` (see
    /// `oidc::extract_user_payload`); group/role-claim mapping is a
    /// follow-up tied to a `MydiaAdditionalClaims` shape.
    pub(crate) async fn upsert_oidc_user(
        db: &mydia_rs_db::Db,
        payload: &crate::oidc::OidcUserPayload,
    ) -> Result<String, ServerFnError> {
        let existing = lookup_oidc_user(db, &payload.sub, &payload.issuer).await?;
        let now = chrono::Utc::now();

        if let Some(existing_id) = existing {
            update_oidc_user(db, &existing_id, payload, now).await?;
            return Ok(existing_id);
        }

        let id = uuid::Uuid::new_v4().to_string();
        insert_oidc_user(db, &id, payload, now).await?;
        Ok(id)
    }

    async fn lookup_oidc_user(
        db: &mydia_rs_db::Db,
        sub: &str,
        issuer: &str,
    ) -> Result<Option<String>, ServerFnError> {
        let row: Option<(String,)> = match db {
            mydia_rs_db::Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id FROM users WHERE oidc_sub = ? AND oidc_issuer = ? LIMIT 1",
            )
            .bind(sub)
            .bind(issuer)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup oidc user: {err}")))?,
            mydia_rs_db::Db::Postgres(pool) => sqlx::query_as(
                "SELECT id FROM users WHERE oidc_sub = $1 AND oidc_issuer = $2 LIMIT 1",
            )
            .bind(sub)
            .bind(issuer)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup oidc user: {err}")))?,
        };
        Ok(row.map(|(id,)| id))
    }

    async fn insert_oidc_user(
        db: &mydia_rs_db::Db,
        id: &str,
        payload: &crate::oidc::OidcUserPayload,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), ServerFnError> {
        match db {
            mydia_rs_db::Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, email, display_name, avatar_url, oidc_sub, oidc_issuer, role, last_login_at, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(id)
                .bind(payload.email.as_deref())
                .bind(payload.display_name.as_deref())
                .bind(payload.avatar_url.as_deref())
                .bind(&payload.sub)
                .bind(&payload.issuer)
                .bind(&payload.role)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert oidc user: {err}")))?;
            }
            mydia_rs_db::Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, email, display_name, avatar_url, oidc_sub, oidc_issuer, role, last_login_at, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)",
                )
                .bind(id)
                .bind(payload.email.as_deref())
                .bind(payload.display_name.as_deref())
                .bind(payload.avatar_url.as_deref())
                .bind(&payload.sub)
                .bind(&payload.issuer)
                .bind(&payload.role)
                .bind(now)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("insert oidc user: {err}")))?;
            }
        }
        Ok(())
    }

    async fn update_oidc_user(
        db: &mydia_rs_db::Db,
        id: &str,
        payload: &crate::oidc::OidcUserPayload,
        now: chrono::DateTime<chrono::Utc>,
    ) -> Result<(), ServerFnError> {
        // last_login_at is bumped here as well so OIDC users see a
        // current timestamp on the profile page — touch_last_login
        // is bcrypt-path only.
        match db {
            mydia_rs_db::Db::Sqlite(pool) => {
                sqlx::query(
                    "UPDATE users SET email = ?, display_name = ?, avatar_url = ?, last_login_at = ?, updated_at = ? WHERE id = ?",
                )
                .bind(payload.email.as_deref())
                .bind(payload.display_name.as_deref())
                .bind(payload.avatar_url.as_deref())
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("update oidc user: {err}")))?;
            }
            mydia_rs_db::Db::Postgres(pool) => {
                sqlx::query(
                    "UPDATE users SET email = $1, display_name = $2, avatar_url = $3, last_login_at = $4, updated_at = $5 WHERE id = $6",
                )
                .bind(payload.email.as_deref())
                .bind(payload.display_name.as_deref())
                .bind(payload.avatar_url.as_deref())
                .bind(now)
                .bind(now)
                .bind(id)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("update oidc user: {err}")))?;
            }
        }
        Ok(())
    }

    pub(super) async fn setup(payload: SetupPayload) -> Result<AuthAck, ServerFnError> {
        validate_setup_payload(&payload)?;
        let st = state().await?;
        if count_users(&st.db).await? != 0 {
            return Err(ServerFnError::new(
                "Setup is closed: an admin user already exists",
            ));
        }

        let id = uuid::Uuid::new_v4().to_string();
        let now = chrono::Utc::now();
        let hash = hash_password(&payload.password)
            .map_err(|err| ServerFnError::new(format!("hash password: {err}")))?;

        match &st.db {
            Db::Sqlite(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, username, email, password_hash, role, last_login_at, inserted_at, updated_at) \
                     VALUES (?, ?, ?, ?, 'admin', ?, ?, ?)",
                )
                .bind(&id)
                .bind(payload.username.trim())
                .bind(payload.email.trim())
                .bind(&hash)
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .bind(now.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create admin: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query(
                    "INSERT INTO users (id, username, email, password_hash, role, last_login_at, inserted_at, updated_at) \
                     VALUES ($1, $2, $3, $4, 'admin', $5, $6, $7)",
                )
                .bind(&id)
                .bind(payload.username.trim())
                .bind(payload.email.trim())
                .bind(&hash)
                .bind(now)
                .bind(now)
                .bind(now)
                .execute(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("create admin: {err}")))?;
            }
        }

        // Sign the new admin in immediately so they land on the home
        // page logged-in, matching Phoenix's
        // `FirstTimeSetupLive.handle_event("create_admin", ...)` path
        // which redirects to /auth/auto-login.
        let session = session_handle().await?;
        session
            .cycle_id()
            .await
            .map_err(|err| ServerFnError::new(format!("session cycle_id: {err}")))?;
        session
            .insert(SESSION_KEY_USER_ID, &id)
            .await
            .map_err(|err| ServerFnError::new(format!("session insert: {err}")))?;

        Ok(AuthAck {
            user_id: id,
            username: Some(payload.username.trim().to_owned()),
            role: "admin".to_owned(),
        })
    }

    fn validate_setup_payload(payload: &SetupPayload) -> Result<(), ServerFnError> {
        let username = payload.username.trim();
        if !(3..=50).contains(&username.chars().count()) {
            return Err(ServerFnError::new("Username must be 3-50 characters"));
        }
        let email = payload.email.trim();
        if !email.contains('@') || email.split_whitespace().count() != 1 {
            return Err(ServerFnError::new("Email must be a valid address"));
        }
        if payload.password.chars().count() < 8 {
            return Err(ServerFnError::new("Password must be at least 8 characters"));
        }
        Ok(())
    }

    async fn lookup_user_for_login(
        db: &Db,
        username: &str,
    ) -> Result<Option<(String, String, Option<String>, String)>, ServerFnError> {
        type LoginRow = (String, String, Option<String>, String);
        let row: Option<LoginRow> = match db {
            Db::Sqlite(pool) => sqlx::query_as(
                "SELECT id, username, password_hash, role FROM users WHERE username = ? LIMIT 1",
            )
            .bind(username)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup user: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as(
                "SELECT id, username, password_hash, role FROM users WHERE username = $1 LIMIT 1",
            )
            .bind(username)
            .fetch_optional(pool)
            .await
            .map_err(|err| ServerFnError::new(format!("lookup user: {err}")))?,
        };
        Ok(row)
    }

    async fn touch_last_login(db: &Db, id: &str) -> Result<(), ServerFnError> {
        let now = chrono::Utc::now();
        match db {
            Db::Sqlite(pool) => {
                sqlx::query("UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?")
                    .bind(now.to_rfc3339())
                    .bind(now.to_rfc3339())
                    .bind(id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("touch last_login: {err}")))?;
            }
            Db::Postgres(pool) => {
                sqlx::query("UPDATE users SET last_login_at = $1, updated_at = $2 WHERE id = $3")
                    .bind(now)
                    .bind(now)
                    .bind(id)
                    .execute(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("touch last_login: {err}")))?;
            }
        }
        Ok(())
    }

    async fn count_users(db: &Db) -> Result<i64, ServerFnError> {
        let (n,): (i64,) = match db {
            Db::Sqlite(pool) => sqlx::query_as("SELECT COUNT(*) FROM users")
                .fetch_one(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("count users: {err}")))?,
            Db::Postgres(pool) => sqlx::query_as("SELECT COUNT(*) FROM users")
                .fetch_one(pool)
                .await
                .map_err(|err| ServerFnError::new(format!("count users: {err}")))?,
        };
        Ok(n)
    }

    async fn load_user_brief(db: &Db, id: &str) -> Result<Option<AuthAck>, ServerFnError> {
        type BriefRow = (String, Option<String>, String);
        let row: Option<BriefRow> = match db {
            Db::Sqlite(pool) => {
                sqlx::query_as("SELECT id, username, role FROM users WHERE id = ? LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("load user: {err}")))?
            }
            Db::Postgres(pool) => {
                sqlx::query_as("SELECT id, username, role FROM users WHERE id = $1 LIMIT 1")
                    .bind(id)
                    .fetch_optional(pool)
                    .await
                    .map_err(|err| ServerFnError::new(format!("load user: {err}")))?
            }
        };
        Ok(row.map(|(id, username, role)| AuthAck {
            user_id: id,
            username,
            role,
        }))
    }
}
