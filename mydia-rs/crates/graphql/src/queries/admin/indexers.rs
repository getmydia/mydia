use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::Indexer;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct IndexerQueries;

#[Object]
impl IndexerQueries {
    async fn indexers(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<Indexer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::indexer_configs::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(Indexer::from_row).collect())
    }

    async fn indexer(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<Option<Indexer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row = mydia_rs_entities::indexer_configs::Entity::find_by_id(parse_id(id.as_str())?)
            .one(&state.db)
            .await?;
        Ok(row.as_ref().and_then(Indexer::from_row))
    }
}
