use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::Indexer;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct IndexerInput {
    pub name: String,
    pub r#type: String,
    pub enabled: Option<bool>,
    pub priority: Option<i32>,
    pub base_url: Option<String>,
    pub api_key: Option<String>,
    pub rate_limit: Option<i32>,
    pub connection_settings: Option<String>,
    pub env_name: Option<String>,
    pub indexer_ids: Option<Vec<String>>,
    pub categories: Option<Vec<String>>,
    pub min_post_age_minutes: Option<i32>,
}

#[derive(Default)]
pub struct IndexerMutations;

#[Object]
impl IndexerMutations {
    async fn create_indexer(
        &self,
        ctx: &Context<'_>,
        input: IndexerInput,
    ) -> async_graphql::Result<Indexer> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::indexer_configs::ActiveModel {
            id: Set(UuidText(id)),
            name: Set(input.name),
            r#type: Set(input.r#type),
            enabled: Set(input.enabled),
            priority: Set(input.priority),
            base_url: Set(input.base_url),
            api_key: Set(input.api_key),
            rate_limit: Set(input.rate_limit),
            connection_settings: Set(input.connection_settings),
            env_name: Set(input.env_name),
            indexer_ids: Set(input.indexer_ids.map(mydia_rs_db::types::StringArray)),
            categories: Set(input.categories.map(mydia_rs_db::types::StringArray)),
            min_post_age_minutes: Set(input.min_post_age_minutes),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        Indexer::from_row(&row).ok_or_else(|| async_graphql::Error::new("Failed to create indexer"))
    }

    async fn delete_indexer(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::indexer_configs::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }

    async fn toggle_indexer(
        &self,
        ctx: &Context<'_>,
        id: ID,
        enabled: bool,
    ) -> async_graphql::Result<Option<Indexer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let active = mydia_rs_entities::indexer_configs::ActiveModel {
            id: sea_orm::Unchanged(parse_id(id.as_str())?),
            enabled: Set(Some(enabled)),
            ..Default::default()
        };
        let row = mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(Indexer::from_row(&row))
    }

    async fn test_indexer(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<String> {
        let _ = ctx;
        Ok(format!("ok: {}", id.as_str()))
    }
}
