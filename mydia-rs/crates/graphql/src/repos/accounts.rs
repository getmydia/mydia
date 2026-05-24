//! Port of `Mydia.Accounts` slice the `auth/api_key` resolvers consume.
//!
//! Post-U13 cutover: SeaORM-native. Every lookup uses
//! `users::Entity::find()` against `&DatabaseConnection`. The
//! `update_last_login` write goes through `Entity::update_many` with
//! the wrapper-typed `id`/`*_at` columns binding through
//! `into_simple_expr(backend)` so Postgres receives the right
//! `::uuid` / `::timestamptz` casts.

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_entities::users;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::DatabaseConnection;
use uuid::Uuid;

pub async fn get_user_by_username(
    db: &DatabaseConnection,
    username: &str,
) -> Result<Option<users::Model>, DbErr> {
    users::Entity::find()
        .filter(users::Column::Username.eq(username.to_owned()))
        .one(db)
        .await
}

pub async fn get_user_by_email(
    db: &DatabaseConnection,
    email: &str,
) -> Result<Option<users::Model>, DbErr> {
    users::Entity::find()
        .filter(users::Column::Email.eq(email.to_owned()))
        .one(db)
        .await
}

pub async fn get_user_by_id(
    db: &DatabaseConnection,
    id: &str,
) -> Result<Option<users::Model>, DbErr> {
    let Ok(uuid) = Uuid::parse_str(id) else {
        return Ok(None);
    };
    let wrapper = UuidText::from(uuid);
    let backend = db.get_database_backend();
    users::Entity::find()
        .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .one(db)
        .await
}

pub async fn update_last_login(db: &DatabaseConnection, user_id: &str) -> Result<(), DbErr> {
    let uuid = Uuid::parse_str(user_id).map_err(|err| DbErr::Custom(err.to_string()))?;
    let wrapper = UuidText::from(uuid);
    let now = DateTimeSecs::from(Utc::now());
    let backend = db.get_database_backend();

    users::Entity::update_many()
        .col_expr(users::Column::LastLoginAt, now.into_simple_expr(backend))
        .col_expr(users::Column::UpdatedAt, now.into_simple_expr(backend))
        .filter(Expr::col(users::Column::Id).eq(wrapper.into_simple_expr(backend)))
        .exec(db)
        .await?;
    Ok(())
}
