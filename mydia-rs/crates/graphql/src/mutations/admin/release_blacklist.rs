use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::ReleaseBlacklistEntry;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct ReleaseBlacklistInput {
    pub indexer: String,
    pub guid: String,
    pub title: String,
    pub failure_reason: String,
}

#[derive(Default)]
pub struct ReleaseBlacklistMutations;

#[Object]
impl ReleaseBlacklistMutations {
    async fn create_release_blacklist_entry(
        &self,
        ctx: &Context<'_>,
        input: ReleaseBlacklistInput,
    ) -> async_graphql::Result<ReleaseBlacklistEntry> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::release_blacklist::ActiveModel {
            id: Set(UuidText(id)),
            indexer: Set(input.indexer),
            guid: Set(input.guid),
            title: Set(input.title),
            failure_reason: Set(input.failure_reason),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        ReleaseBlacklistEntry::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create release blacklist entry"))
    }

    async fn delete_release_blacklist_entry(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::release_blacklist::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }
}
