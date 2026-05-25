use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::ImportList;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct ImportListInput {
    pub name: String,
    pub r#type: String,
    pub media_type: String,
    pub enabled: Option<bool>,
    pub sync_interval: Option<i32>,
    pub auto_add: Option<bool>,
    pub monitored: Option<bool>,
    pub quality_profile_id: Option<String>,
    pub library_path_id: Option<String>,
}

#[derive(Default)]
pub struct ImportListMutations;

#[Object]
impl ImportListMutations {
    async fn create_import_list(
        &self,
        ctx: &Context<'_>,
        input: ImportListInput,
    ) -> async_graphql::Result<ImportList> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::import_lists::ActiveModel {
            id: Set(UuidText(id)),
            name: Set(input.name),
            r#type: Set(input.r#type),
            media_type: Set(input.media_type),
            enabled: Set(input.enabled.unwrap_or(true)),
            sync_interval: Set(input.sync_interval.unwrap_or(1440)),
            auto_add: Set(input.auto_add.unwrap_or(false)),
            monitored: Set(input.monitored.unwrap_or(false)),
            quality_profile_id: Set(input
                .quality_profile_id
                .and_then(|s| uuid::Uuid::parse_str(&s).ok())
                .map(UuidText)),
            library_path_id: Set(input
                .library_path_id
                .and_then(|s| uuid::Uuid::parse_str(&s).ok())
                .map(UuidText)),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        ImportList::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create import list"))
    }

    async fn delete_import_list(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::import_lists::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }

    async fn toggle_import_list(
        &self,
        ctx: &Context<'_>,
        id: ID,
        enabled: bool,
    ) -> async_graphql::Result<Option<ImportList>> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let active = mydia_rs_entities::import_lists::ActiveModel {
            id: sea_orm::Unchanged(parse_id(id.as_str())?),
            enabled: Set(enabled),
            ..Default::default()
        };
        let row = mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(ImportList::from_row(&row))
    }
}
