//! Port of `Mydia.Accounts` slice the `auth/api_key` resolvers consume.
//!
//! Tier-(a) pilot: every query in this file is portable SQL (no JSON
//! extract, no datetime arithmetic, no dialect-divergent functions) so
//! the Postgres arms go through `sqlx::query_as!`/`query!`. The macros
//! check column lists, parameter counts, and types at compile time
//! against the Postgres prepare DB; `cargo sqlx prepare --workspace`
//! materializes the per-query JSON cache under `mydia-rs/.sqlx/`.
//!
//! The `SQLite` arms keep the runtime form (`sqlx::query_as::<_, T>(...)`).
//! `sqlx::query_as!` is single-dialect at compile time, so we cannot run
//! both arms through the macro against a Postgres-only prepare target.
//! Portable SQL means the `SQLite` arm is the mechanical `$N -> ?` rewrite
//! of the Postgres arm, so when the Postgres macro compiles the `SQLite`
//! arm is guaranteed to be the equivalent statement.
//!
//! The earlier hand-rolled `.replace("$1", "?")` shape is gone: sqlx-sqlite
//! accepts `$N` placeholders unchanged, so each arm carries its own SQL
//! string verbatim. That keeps the macro-checked Postgres SQL byte-equal
//! to the production query and removes a runtime substitution from
//! every call.

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use mydia_rs_models::User;
use uuid::Uuid;

pub async fn get_user_by_username(db: &Db, username: &str) -> Result<Option<User>, sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, User>(
                "SELECT id, username, email, password_hash, oidc_sub, oidc_issuer, role, \
                 display_name, avatar_url, last_login_at, inserted_at, updated_at \
                 FROM users WHERE username = $1",
            )
            .bind(username)
            .fetch_optional(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as!(
                User,
                r#"SELECT
                    id as "id!: UuidText",
                    username,
                    email,
                    password_hash,
                    oidc_sub,
                    oidc_issuer,
                    role as "role!",
                    display_name,
                    avatar_url,
                    last_login_at as "last_login_at?: DateTimeSecs",
                    inserted_at as "inserted_at!: DateTimeSecs",
                    updated_at as "updated_at!: DateTimeSecs"
                  FROM users
                  WHERE username = $1"#,
                username
            )
            .fetch_optional(pool)
            .await
        }
    }
}

pub async fn get_user_by_email(db: &Db, email: &str) -> Result<Option<User>, sqlx::Error> {
    match db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, User>(
                "SELECT id, username, email, password_hash, oidc_sub, oidc_issuer, role, \
                 display_name, avatar_url, last_login_at, inserted_at, updated_at \
                 FROM users WHERE email = $1",
            )
            .bind(email)
            .fetch_optional(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as!(
                User,
                r#"SELECT
                    id as "id!: UuidText",
                    username,
                    email,
                    password_hash,
                    oidc_sub,
                    oidc_issuer,
                    role as "role!",
                    display_name,
                    avatar_url,
                    last_login_at as "last_login_at?: DateTimeSecs",
                    inserted_at as "inserted_at!: DateTimeSecs",
                    updated_at as "updated_at!: DateTimeSecs"
                  FROM users
                  WHERE email = $1"#,
                email
            )
            .fetch_optional(pool)
            .await
        }
    }
}

pub async fn get_user_by_id(db: &Db, id: &str) -> Result<Option<User>, sqlx::Error> {
    let user_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    match db {
        Db::Sqlite(pool) => {
            sqlx::query_as::<_, User>(
                "SELECT id, username, email, password_hash, oidc_sub, oidc_issuer, role, \
                 display_name, avatar_url, last_login_at, inserted_at, updated_at \
                 FROM users WHERE id = $1",
            )
            .bind(user_uuid)
            .fetch_optional(pool)
            .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as!(
                User,
                r#"SELECT
                    id as "id!: UuidText",
                    username,
                    email,
                    password_hash,
                    oidc_sub,
                    oidc_issuer,
                    role as "role!",
                    display_name,
                    avatar_url,
                    last_login_at as "last_login_at?: DateTimeSecs",
                    inserted_at as "inserted_at!: DateTimeSecs",
                    updated_at as "updated_at!: DateTimeSecs"
                  FROM users
                  WHERE id = $1"#,
                user_uuid as UuidText
            )
            .fetch_optional(pool)
            .await
        }
    }
}

pub async fn update_last_login(db: &Db, user_id: &str) -> Result<(), sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let now = DateTimeSecs::from(Utc::now());
    match db {
        Db::Sqlite(pool) => {
            sqlx::query("UPDATE users SET last_login_at = $1, updated_at = $2 WHERE id = $3")
                .bind(now)
                .bind(now)
                .bind(user_uuid)
                .execute(pool)
                .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query!(
                "UPDATE users SET last_login_at = $1, updated_at = $2 WHERE id = $3",
                now as DateTimeSecs,
                now as DateTimeSecs,
                user_uuid as UuidText
            )
            .execute(pool)
            .await?;
        }
    }
    Ok(())
}
