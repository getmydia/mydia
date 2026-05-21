//! Port of `Mydia.Accounts` slice the `auth/api_key` resolvers consume.

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_db::Db;
use mydia_rs_models::User;
use uuid::Uuid;

const USER_COLUMNS: &str =
    "id, username, email, password_hash, oidc_sub, oidc_issuer, role, display_name, \
     avatar_url, last_login_at, inserted_at, updated_at";

pub async fn get_user_by_username(db: &Db, username: &str) -> Result<Option<User>, sqlx::Error> {
    let sql = format!("SELECT {USER_COLUMNS} FROM users WHERE username = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, User>(&sql)
                .bind(username)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, User>(&sql)
                .bind(username)
                .fetch_optional(pool)
                .await
        }
    }
}

pub async fn get_user_by_email(db: &Db, email: &str) -> Result<Option<User>, sqlx::Error> {
    let sql = format!("SELECT {USER_COLUMNS} FROM users WHERE email = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, User>(&sql)
                .bind(email)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, User>(&sql)
                .bind(email)
                .fetch_optional(pool)
                .await
        }
    }
}

pub async fn get_user_by_id(db: &Db, id: &str) -> Result<Option<User>, sqlx::Error> {
    let user_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql = format!("SELECT {USER_COLUMNS} FROM users WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, User>(&sql)
                .bind(user_uuid)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, User>(&sql)
                .bind(user_uuid)
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
            sqlx::query("UPDATE users SET last_login_at = ?, updated_at = ? WHERE id = ?")
                .bind(now)
                .bind(now)
                .bind(user_uuid)
                .execute(pool)
                .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query("UPDATE users SET last_login_at = $1, updated_at = $2 WHERE id = $3")
                .bind(now)
                .bind(now)
                .bind(user_uuid)
                .execute(pool)
                .await?;
        }
    }
    Ok(())
}
