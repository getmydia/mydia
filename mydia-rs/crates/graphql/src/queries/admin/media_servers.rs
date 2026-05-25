use async_graphql::{Context, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::MediaServer;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(Default)]
pub struct MediaServerQueries;

#[Object]
impl MediaServerQueries {
    async fn media_servers(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<MediaServer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = mydia_rs_entities::media_server_configs::Entity::find()
            .all(&state.db)
            .await?;
        Ok(rows.iter().filter_map(MediaServer::from_row).collect())
    }

    async fn media_server(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<Option<MediaServer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row =
            mydia_rs_entities::media_server_configs::Entity::find_by_id(parse_id(id.as_str())?)
                .one(&state.db)
                .await?;
        Ok(row.as_ref().and_then(MediaServer::from_row))
    }
}
