use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct AdminRemoteAccessMutations;

#[Object]
impl AdminRemoteAccessMutations {
    async fn revoke_paired_device(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let uid = parse_id(id.as_str())?;
        mydia_rs_entities::remote_devices::Entity::delete_by_id(uid)
            .exec(&state.db)
            .await?;
        Ok(true)
    }
}
