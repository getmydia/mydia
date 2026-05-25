use async_graphql::{Context, Object};
use sea_orm::entity::prelude::*;
use sea_orm::query::QueryOrder;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::UserRow;

#[derive(Default)]
pub struct UserQueries;

#[Object]
impl UserQueries {
    async fn users(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<UserRow>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::users::Entity::find()
            .order_by_asc(mydia_rs_entities::users::Column::InsertedAt)
            .all(&state.db)
            .await?;
        Ok(rows
            .into_iter()
            .map(|u| UserRow {
                id: async_graphql::ID(u.id.0.to_string()),
                username: u.username,
                email: u.email,
                role: u.role,
                is_oidc: u.oidc_sub.is_some(),
                last_login_at: u.last_login_at.map(|dt| dt.0.to_rfc3339()),
                inserted_at: Some(u.inserted_at.0.to_rfc3339()),
            })
            .collect())
    }
}
