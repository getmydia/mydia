use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::ImportList;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct ImportListQueries;

#[Object]
impl ImportListQueries {
    async fn import_lists(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<ImportList>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::import_lists::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(ImportList::from_row).collect())
    }

    async fn import_list(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<ImportList>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row = mydia_rs_entities::import_lists::Entity::find_by_id(parse_id(id.as_str())?)
            .one(&state.db)
            .await?;
        Ok(row.as_ref().and_then(ImportList::from_row))
    }
}
