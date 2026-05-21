//! Port of `Mydia.Accounts` slice covering API-key CRUD.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use mydia_rs_auth::api_key::hash_api_key;
use mydia_rs_db::types::{DateTimeSecs, StringArray, UuidText};
use mydia_rs_db::Db;
use mydia_rs_models::ApiKey;
use rand::RngCore;
use uuid::Uuid;

const COLUMNS: &str =
    "id, user_id, name, key_hash, key_prefix, permissions, last_used_at, expires_at, \
     revoked_at, inserted_at";

pub async fn list_for_user(db: &Db, user_id: &str) -> Result<Vec<ApiKey>, sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql =
        format!("SELECT {COLUMNS} FROM api_keys WHERE user_id = $1 ORDER BY inserted_at DESC");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, ApiKey>(&sql)
                .bind(user_uuid)
                .fetch_all(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, ApiKey>(&sql)
                .bind(user_uuid)
                .fetch_all(pool)
                .await
        }
    }
}

pub async fn get_by_id(db: &Db, id: &str) -> Result<Option<ApiKey>, sqlx::Error> {
    let key_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let sql = format!("SELECT {COLUMNS} FROM api_keys WHERE id = $1");
    match db {
        Db::Sqlite(pool) => {
            let sql = sql.replace("$1", "?");
            sqlx::query_as::<_, ApiKey>(&sql)
                .bind(key_uuid)
                .fetch_optional(pool)
                .await
        }
        Db::Postgres(pool) => {
            sqlx::query_as::<_, ApiKey>(&sql)
                .bind(key_uuid)
                .fetch_optional(pool)
                .await
        }
    }
}

/// Issued key bundle returned by [`create`]. `plain_key` is the
/// only place the unhashed value exists — the caller surfaces it once
/// and never persists it.
pub struct IssuedApiKey {
    pub row: ApiKey,
    pub plain_key: String,
}

/// Generate, hash, and persist a new API key. Returns the row plus the
/// plaintext key. Mirrors `Mydia.Accounts.create_api_key/2`.
///
/// The plaintext format is `mydia_<32 url-safe base64 chars>` — a
/// random 24-byte token. The stored `key_prefix` is the first 8 chars
/// of the plaintext (after the `mydia_` marker), so admin pages can
/// distinguish keys without revealing them.
pub async fn create(
    db: &Db,
    user_id: &str,
    name: &str,
    permissions: Vec<String>,
    expires_at: Option<chrono::DateTime<chrono::Utc>>,
) -> Result<IssuedApiKey, sqlx::Error> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let mut raw = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut raw);
    let token = URL_SAFE_NO_PAD.encode(raw);
    let plain_key = format!("mydia_{token}");
    let prefix: String = token.chars().take(8).collect();
    let key_hash = hash_api_key(&plain_key)
        .map_err(|err| sqlx::Error::Protocol(format!("hash failure: {err}")))?;
    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let permissions_db = StringArray(permissions);
    let expires_db = expires_at.map(DateTimeSecs::from);

    match db {
        Db::Sqlite(pool) => {
            sqlx::query(
                "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, \
                 permissions, expires_at, inserted_at) \
                 VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
            )
            .bind(id)
            .bind(user_uuid)
            .bind(name)
            .bind(&key_hash)
            .bind(&prefix)
            .bind(&permissions_db)
            .bind(expires_db)
            .bind(now)
            .execute(pool)
            .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query(
                "INSERT INTO api_keys (id, user_id, name, key_hash, key_prefix, \
                 permissions, expires_at, inserted_at) \
                 VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
            )
            .bind(id)
            .bind(user_uuid)
            .bind(name)
            .bind(&key_hash)
            .bind(&prefix)
            .bind(&permissions_db)
            .bind(expires_db)
            .bind(now)
            .execute(pool)
            .await?;
        }
    }

    let row = get_by_id(db, &id.0.to_string())
        .await?
        .ok_or(sqlx::Error::RowNotFound)?;
    Ok(IssuedApiKey { row, plain_key })
}

pub async fn revoke(db: &Db, id: &str) -> Result<Option<ApiKey>, sqlx::Error> {
    let key_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let now = DateTimeSecs::from(Utc::now());
    match db {
        Db::Sqlite(pool) => {
            sqlx::query("UPDATE api_keys SET revoked_at = ? WHERE id = ?")
                .bind(now)
                .bind(key_uuid)
                .execute(pool)
                .await?;
        }
        Db::Postgres(pool) => {
            sqlx::query("UPDATE api_keys SET revoked_at = $1 WHERE id = $2")
                .bind(now)
                .bind(key_uuid)
                .execute(pool)
                .await?;
        }
    }
    get_by_id(db, id).await
}

pub async fn delete(db: &Db, id: &str) -> Result<bool, sqlx::Error> {
    let key_uuid = Uuid::parse_str(id)
        .map(UuidText::from)
        .map_err(|_| sqlx::Error::RowNotFound)?;
    let rows_affected = match db {
        Db::Sqlite(pool) => sqlx::query("DELETE FROM api_keys WHERE id = ?")
            .bind(key_uuid)
            .execute(pool)
            .await?
            .rows_affected(),
        Db::Postgres(pool) => sqlx::query("DELETE FROM api_keys WHERE id = $1")
            .bind(key_uuid)
            .execute(pool)
            .await?
            .rows_affected(),
    };
    Ok(rows_affected > 0)
}
