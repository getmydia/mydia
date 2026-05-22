//! tower-sessions glue.
//!
//! Phoenix uses signed cookies via `Plug.Session, store: :cookie,
//! key: "_mydia_key"` — no server-side session table at all. mydia-rs
//! takes the load-bearing decision from the rewrite plan: a new
//! `mydia_rs_sessions` table, cookie name `mydia_rs_session`, both
//! deliberately distinct so the two cookies don't interfere during
//! the parallel-window dogfooding period.
//!
//! What's stored per session: the `user_id` (UUID string) of the
//! authenticated user, if any. That's it. Everything else
//! (`current_user` struct, role, etc.) gets re-read from the DB on
//! every request — cheap with a connection pool and avoids
//! stale-after-revoke gotchas.
//!
//! Cookie attributes match the plan: `HttpOnly`, `Secure`
//! (configurable for HTTP-only LAN deployments), `SameSite=Lax`,
//! name `mydia_rs_session`. Server-fn CSRF defense rests on the
//! Lax cookie + POST-only mutation surface (Dioxus' server fns are
//! POST by default).
//!
//! Gating: this module is declared `#[cfg(feature = "server")]` in
//! `lib.rs`, so no inner `#![cfg(...)]` attribute is needed here.

use axum::Router;
use mydia_rs_db::Db;
use sqlx::{PgPool, SqlitePool};
use std::time::Duration;
use tower_sessions::cookie::SameSite;
use tower_sessions::{Expiry, SessionManagerLayer};
use tower_sessions_sqlx_store::{PostgresStore, SqliteStore};

/// Session cookie name. Differs deliberately from Phoenix's `_mydia_key`
/// so the two backends' cookies don't collide during the parallel-window
/// dogfooding period.
pub const SESSION_COOKIE_NAME: &str = "mydia_rs_session";

/// Default session lifetime — one week. Matches the Phoenix
/// Guardian-token TTL the existing fleet expects.
pub const SESSION_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);

/// Session key holding the authenticated user's UUID. String-typed so
/// the store can round-trip through JSON without a custom serializer.
pub const SESSION_KEY_USER_ID: &str = "user_id";

/// Build the tower-sessions layer for the active DB backend.
///
/// `secure` controls the cookie's `Secure` attribute — set to `false`
/// for HTTP-only LAN deployments. Defaults to `true` in production.
/// The matching `migrate()` call must run once before the first
/// request lands; do it at boot via [`migrate`].
pub fn layer(db: &Db, secure: bool) -> SessionLayer {
    match db.clone() {
        Db::Sqlite(pool) => SessionLayer::Sqlite(layer_sqlite(pool, secure)),
        Db::Postgres(pool) => SessionLayer::Postgres(layer_postgres(pool, secure)),
    }
}

fn layer_sqlite(pool: SqlitePool, secure: bool) -> SessionManagerLayer<SqliteStore> {
    let store = SqliteStore::new(pool);
    base_layer(store, secure)
}

fn layer_postgres(pool: PgPool, secure: bool) -> SessionManagerLayer<PostgresStore> {
    let store = PostgresStore::new(pool);
    base_layer(store, secure)
}

fn base_layer<S>(store: S, secure: bool) -> SessionManagerLayer<S>
where
    S: tower_sessions::SessionStore + Clone,
{
    SessionManagerLayer::new(store)
        .with_name(SESSION_COOKIE_NAME)
        .with_http_only(true)
        .with_secure(secure)
        .with_same_site(SameSite::Lax)
        .with_expiry(Expiry::OnInactivity(time::Duration::seconds(
            SESSION_TTL.as_secs() as i64,
        )))
}

/// Runtime-dispatched session manager layer. We can't return a single
/// generic `SessionManagerLayer<S>` because the two stores are
/// concrete distinct types; this enum lets the app crate attach
/// whichever variant is active.
#[allow(clippy::large_enum_variant)]
pub enum SessionLayer {
    Sqlite(SessionManagerLayer<SqliteStore>),
    Postgres(SessionManagerLayer<PostgresStore>),
}

impl SessionLayer {
    /// Apply the contained layer to `router`. Avoids leaking the
    /// `tower_sessions` generic into `crates/app`.
    pub fn attach(self, router: Router) -> Router {
        match self {
            Self::Sqlite(l) => router.layer(l),
            Self::Postgres(l) => router.layer(l),
        }
    }
}

/// Create the `tower_sessions_*` table on the active backend.
///
/// This is the second mydia-rs-owned schema write (the first is U34's
/// `mydia_runtime_lock`). Both are tables Phoenix's Ecto schemas
/// don't model and don't touch; the rewrite plan's "no migrations
/// from mydia-rs" rule notes these as the explicit exceptions.
pub async fn migrate(db: &Db) -> Result<(), sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            let store = SqliteStore::new(pool.clone());
            store.migrate().await
        }
        Db::Postgres(pool) => {
            let store = PostgresStore::new(pool.clone());
            store.migrate().await
        }
    }
}
