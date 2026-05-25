use async_graphql::{Context, InputObject, Object};
use mydia_rs_auth::{hash_password, verify_password};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::Set;
use uuid::Uuid;

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::types::UserProfile;

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "UpdateProfileInput")]
pub struct UpdateProfileInput {
    pub display_name: Option<String>,
    pub email: Option<String>,
    pub username: Option<String>,
}

#[derive(Default)]
pub struct ProfileMutations;

#[Object]
impl ProfileMutations {
    async fn update_profile(
        &self,
        ctx: &Context<'_>,
        input: UpdateProfileInput,
    ) -> async_graphql::Result<UserProfile> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let user_uuid = Uuid::parse_str(&user.id.to_string())
            .map(UuidText)
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let mut update = mydia_rs_entities::users::ActiveModel {
            id: Set(user_uuid),
            ..Default::default()
        };

        if let Some(dn) = &input.display_name {
            update.display_name = Set(Some(dn.clone()));
        }
        if let Some(email) = &input.email {
            update.email = Set(Some(email.clone()));
        }
        if let Some(username) = &input.username {
            update.username = Set(Some(username.clone()));
        }
        update.updated_at = Set(DateTimeSecs::from(chrono::Utc::now()));

        let row = mydia_rs_db::update_active_model(update, &state.db).await?;

        Ok(UserProfile::from_row(&row))
    }

    async fn change_password(
        &self,
        ctx: &Context<'_>,
        current_password: String,
        new_password: String,
    ) -> async_graphql::Result<bool> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let user_uuid = Uuid::parse_str(&user.id.to_string())
            .map(UuidText)
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let db_user = mydia_rs_entities::users::Entity::find()
            .filter(
                Expr::col(mydia_rs_entities::users::Column::Id)
                    .eq(user_uuid.into_simple_expr(backend)),
            )
            .one(&state.db)
            .await?
            .ok_or_else(|| async_graphql::Error::new("User not found"))?;

        let password_hash = db_user
            .password_hash
            .as_deref()
            .ok_or_else(|| async_graphql::Error::new("No password set for this account"))?;

        if verify_password(&current_password, password_hash).is_err() {
            return Err(async_graphql::Error::new("Current password is incorrect"));
        }

        let new_hash = hash_password(&new_password)
            .map_err(|e| async_graphql::Error::new(format!("Failed to hash password: {e}")))?;

        let now = DateTimeSecs::from(chrono::Utc::now());
        let active = mydia_rs_entities::users::ActiveModel {
            id: Set(user_uuid),
            password_hash: Set(Some(new_hash)),
            updated_at: Set(now),
            ..Default::default()
        };

        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(true)
    }
}
