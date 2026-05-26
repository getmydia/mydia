use mydia_rs_db::DatabaseConnection;
use sea_orm::DatabaseBackend;
use sqlx::{PgPool, SqlitePool};
use std::time::Duration;
use tower_sessions::cookie::SameSite;
use tower_sessions::{Expiry, SessionManagerLayer};
use tower_sessions_sqlx_store::{PostgresStore, SqliteStore};

const SESSION_COOKIE_NAME_SECURE: &str = "__Host-mydia_session";
const SESSION_COOKIE_NAME_DEV: &str = "mydia_session";

pub const SESSION_TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);

pub const SESSION_KEY_USER_ID: &str = "user_id";

pub fn layer(db: &DatabaseConnection, secure: bool) -> SessionLayer {
    match db.get_database_backend() {
        DatabaseBackend::Sqlite => SessionLayer::Sqlite(layer_sqlite(
            db.get_sqlite_connection_pool().clone(),
            secure,
        )),
        DatabaseBackend::Postgres => SessionLayer::Postgres(layer_postgres(
            db.get_postgres_connection_pool().clone(),
            secure,
        )),
        _ => panic!("Unsupported database backend for mydia-rs SPA sessions"),
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
    let cookie_name = if secure {
        SESSION_COOKIE_NAME_SECURE
    } else {
        SESSION_COOKIE_NAME_DEV
    };

    SessionManagerLayer::new(store)
        .with_name(cookie_name)
        .with_http_only(true)
        .with_secure(secure)
        .with_same_site(SameSite::Lax)
        .with_expiry(Expiry::OnInactivity(time::Duration::seconds(
            SESSION_TTL.as_secs() as i64,
        )))
}

#[derive(Clone)]
#[allow(clippy::large_enum_variant)]
pub enum SessionLayer {
    Sqlite(SessionManagerLayer<SqliteStore>),
    Postgres(SessionManagerLayer<PostgresStore>),
}

impl SessionLayer {
    pub fn attach(self, router: axum::Router) -> axum::Router {
        match self {
            Self::Sqlite(l) => router.layer(l),
            Self::Postgres(l) => router.layer(l),
        }
    }
}

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
        _ => Ok(()),
    }
}
