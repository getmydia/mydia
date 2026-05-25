use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::DownloadClient;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct DownloadClientQueries;

#[Object]
impl DownloadClientQueries {
    async fn download_clients(
        &self,
        ctx: &Context<'_>,
    ) -> async_graphql::Result<Vec<DownloadClient>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::download_client_configs::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(DownloadClient::from_row).collect())
    }

    async fn download_client(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<DownloadClient>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row =
            mydia_rs_entities::download_client_configs::Entity::find_by_id(parse_id(id.as_str())?)
                .one(&state.db)
                .await?;
        Ok(row.as_ref().and_then(DownloadClient::from_row))
    }
}
