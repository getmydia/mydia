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
use mydia_rs_db::DatabaseConnection;
use sea_orm::DatabaseBackend;
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
///
/// tower-sessions-sqlx-store wants the raw `sqlx::PgPool` /
/// `sqlx::SqlitePool`; `SeaORM` exposes those through
/// `get_postgres_connection_pool()` / `get_sqlite_connection_pool()`.
/// This is the one remaining backend check in the web crate — it
/// dispatches an entirely separate store type, not per-engine SQL.
pub fn layer(db: &DatabaseConnection, secure: bool) -> SessionLayer {
    match db.get_database_backend() {
        DatabaseBackend::Sqlite => {
            SessionLayer::Sqlite(layer_sqlite(db.get_sqlite_connection_pool().clone(), secure))
        }
        DatabaseBackend::Postgres => SessionLayer::Postgres(layer_postgres(
            db.get_postgres_connection_pool().clone(),
            secure,
        )),
        DatabaseBackend::MySql => {
            panic!("MySQL backend is not supported by mydia-rs sessions")
        }
        _ => panic!("Unsupported database backend for mydia-rs sessions"),
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
pub async fn migrate(db: &DatabaseConnection) -> Result<(), sqlx::Error> {
    match db.get_database_backend() {
        DatabaseBackend::Sqlite => {
            let store = SqliteStore::new(db.get_sqlite_connection_pool().clone());
            store.migrate().await
        }
        DatabaseBackend::Postgres => {
            let store = PostgresStore::new(db.get_postgres_connection_pool().clone());
            store.migrate().await
        }
        // mydia-rs is dual-engine SQLite/Postgres only; other backends are
        // never reachable in landed code but stay covered as a no-op so
        // future SeaORM additions don't trigger an exhaustiveness break.
        _ => Ok(()),
    }
}
