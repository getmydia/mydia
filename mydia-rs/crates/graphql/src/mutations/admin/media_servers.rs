use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::MediaServer;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct MediaServerInput {
    pub name: String,
    pub r#type: String,
    pub enabled: Option<bool>,
    pub url: String,
    pub token: Option<String>,
    pub connection_settings: Option<String>,
}

#[derive(Default)]
pub struct MediaServerMutations;

#[Object]
impl MediaServerMutations {
    async fn create_media_server(
        &self,
        ctx: &Context<'_>,
        input: MediaServerInput,
    ) -> async_graphql::Result<MediaServer> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::media_server_configs::ActiveModel {
            id: Set(UuidText(id)),
            name: Set(input.name),
            r#type: Set(input.r#type),
            enabled: Set(input.enabled),
            url: Set(input.url),
            token: Set(input.token),
            connection_settings: Set(input.connection_settings),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        MediaServer::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create media server"))
    }

    async fn delete_media_server(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::media_server_configs::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }

    async fn toggle_media_server(
        &self,
        ctx: &Context<'_>,
        id: ID,
        enabled: bool,
    ) -> async_graphql::Result<Option<MediaServer>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let active = mydia_rs_entities::media_server_configs::ActiveModel {
            id: sea_orm::Unchanged(parse_id(id.as_str())?),
            enabled: Set(Some(enabled)),
            ..Default::default()
        };
        let row = mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(MediaServer::from_row(&row))
    }
}
