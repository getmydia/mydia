use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::DownloadClient;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct DownloadClientInput {
    pub name: String,
    pub r#type: String,
    pub enabled: Option<bool>,
    pub priority: Option<i32>,
    pub host: Option<String>,
    pub port: Option<i32>,
    pub use_ssl: Option<bool>,
    pub url_base: Option<String>,
    pub username: Option<String>,
    pub password: Option<String>,
    pub api_key: Option<String>,
    pub category: Option<String>,
    pub download_directory: Option<String>,
    pub connection_settings: Option<String>,
    pub remove_completed: Option<bool>,
    pub incomplete_grace_minutes: Option<i32>,
}

#[derive(Default)]
pub struct DownloadClientMutations;

#[Object]
impl DownloadClientMutations {
    async fn create_download_client(
        &self,
        ctx: &Context<'_>,
        input: DownloadClientInput,
    ) -> async_graphql::Result<DownloadClient> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::download_client_configs::ActiveModel {
            id: Set(UuidText(id)),
            name: Set(input.name),
            r#type: Set(input.r#type),
            enabled: Set(input.enabled),
            priority: Set(input.priority),
            host: Set(input.host),
            port: Set(input.port),
            use_ssl: Set(input.use_ssl),
            url_base: Set(input.url_base),
            username: Set(input.username),
            password: Set(input.password),
            api_key: Set(input.api_key),
            category: Set(input.category),
            download_directory: Set(input.download_directory),
            connection_settings: Set(input.connection_settings),
            remove_completed: Set(input.remove_completed),
            incomplete_grace_minutes: Set(input.incomplete_grace_minutes),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        DownloadClient::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create download client"))
    }

    async fn delete_download_client(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::download_client_configs::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }

    async fn toggle_download_client(
        &self,
        ctx: &Context<'_>,
        id: ID,
        enabled: bool,
    ) -> async_graphql::Result<Option<DownloadClient>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let active = mydia_rs_entities::download_client_configs::ActiveModel {
            id: sea_orm::Unchanged(parse_id(id.as_str())?),
            enabled: Set(Some(enabled)),
            ..Default::default()
        };
        let row = mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(DownloadClient::from_row(&row))
    }

    async fn test_download_client(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<String> {
        let _ = ctx;
        Ok(format!("ok: {}", id.as_str()))
    }
}
