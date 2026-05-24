//! Port of `Mydia.Accounts` slice covering API-key CRUD.
//!
//! Post-U13 cutover: SeaORM-native. Inserts go through
//! `mydia_rs_db::insert_active_model` so the wrapper-typed `id` /
//! `user_id` / `permissions` (`StringArray`) / `inserted_at` columns
//! get the right Postgres casts. Reads use vanilla
//! `Entity::find().filter(...)`.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use chrono::Utc;
use mydia_rs_auth::api_key::hash_api_key;
use mydia_rs_db::types::{DateTimeSecs, StringArray, UuidText};
use mydia_rs_entities::api_keys;
use rand::RngCore;
use sea_orm::entity::prelude::*;
use sea_orm::query::QueryOrder;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::{ActiveValue, DatabaseConnection, Set};
use uuid::Uuid;

pub async fn list_for_user(
    db: &DatabaseConnection,
    user_id: &str,
) -> Result<Vec<api_keys::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(user_id) else {
        return Ok(Vec::new());
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    api_keys::Entity::find()
        .filter(Expr::col(api_keys::Column::UserId).eq(wrapper.into_simple_expr(backend)))
        .order_by_desc(api_keys::Column::InsertedAt)
        .all(db)
        .await
}

pub async fn get_by_id(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<api_keys::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(id) else {
        return Ok(None);
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    api_keys::Entity::find()
        .filter(Expr::col(api_keys::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

/// Issued key bundle returned by [`create`]. `plain_key` is the
/// only place the unhashed value exists — the caller surfaces it once
/// and never persists it.
pub struct IssuedApiKey {
    pub row: api_keys::Model,
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
    db: &DatabaseConnection,
    user_id: &str,
    name: &str,
    permissions: Vec<String>,
    expires_at: Option<chrono::DateTime<chrono::Utc>>,
) -> Result<IssuedApiKey, DbErr> {
    let user_uuid = Uuid::parse_str(user_id)
        .map(UuidText::from)
        .map_err(|err| DbErr::Custom(err.to_string()))?;
    let mut raw = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut raw);
    let token = URL_SAFE_NO_PAD.encode(raw);
    let plain_key = format!("mydia_{token}");
    let prefix: String = token.chars().take(8).collect();
    let key_hash =
        hash_api_key(&plain_key).map_err(|err| DbErr::Custom(format!("hash failure: {err}")))?;
    let id = UuidText::new_v4();
    let now = DateTimeSecs::from(Utc::now());
    let permissions_db = StringArray(permissions);
    let expires_db = expires_at.map(DateTimeSecs::from);

    let am = api_keys::ActiveModel {
        id: Set(id),
        user_id: Set(user_uuid),
        name: Set(name.to_owned()),
        key_hash: Set(key_hash),
        key_prefix: Set(Some(prefix)),
        permissions: Set(Some(permissions_db)),
        expires_at: Set(expires_db),
        inserted_at: Set(now),
        last_used_at: ActiveValue::NotSet,
        revoked_at: ActiveValue::NotSet,
    };

    let row = mydia_rs_db::insert_active_model(am, db).await?;
    Ok(IssuedApiKey { row, plain_key })
}

pub async fn revoke(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<api_keys::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(id) else {
        return Ok(None);
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    let now = DateTimeSecs::from(Utc::now());

    api_keys::Entity::update_many()
        .col_expr(api_keys::Column::RevokedAt, now.into_simple_expr(backend))
        .filter(Expr::col(api_keys::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .exec(db)
        .await?;
    get_by_id(db, id).await
}

pub async fn delete(db: &DatabaseConnection, id: &str) -> Result<bool, DbErr> {
    let Ok(uuid) = Uuid::parse_str(id) else {
        return Ok(false);
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    let res = api_keys::Entity::delete_many()
        .filter(Expr::col(api_keys::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(res.rows_affected > 0)
}
