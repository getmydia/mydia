use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::UuidText;
use mydia_rs_pubsub::Event;
use sea_orm::entity::prelude::*;
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::LibraryPath;

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid id format"))
}

#[derive(InputObject)]
pub struct LibraryPathInput {
    pub path: String,
    pub r#type: String,
    pub monitored: Option<bool>,
    pub scan_interval: Option<i32>,
    pub quality_profile_id: Option<String>,
}

#[derive(Default)]
pub struct LibraryPathMutations;

#[Object]
impl LibraryPathMutations {
    async fn create_library_path(
        &self,
        ctx: &Context<'_>,
        input: LibraryPathInput,
    ) -> async_graphql::Result<LibraryPath> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let id = uuid::Uuid::new_v4();

        let model = mydia_rs_entities::library_paths::ActiveModel {
            id: Set(UuidText(id)),
            path: Set(input.path),
            r#type: Set(input.r#type),
            monitored: Set(input.monitored),
            scan_interval: Set(input.scan_interval),
            quality_profile_id: Set(input
                .quality_profile_id
                .and_then(|s| uuid::Uuid::parse_str(&s).ok().map(UuidText))),
            from_env: Set(false),
            disabled: Set(false),
            write_nfo: Set(false),
            ..Default::default()
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        LibraryPath::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create library path"))
    }

    async fn delete_library_path(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        mydia_rs_entities::library_paths::Entity::delete_by_id(parse_id(id.as_str())?)
            .exec(&state.db)
            .await?;
        Ok(true)
    }

    async fn trigger_scan(&self, ctx: &Context<'_>, path_id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        state.pubsub.publish(
            "library_scanner",
            Event::from_json(serde_json::json!({"path_id": path_id.as_str()})),
        );
        Ok(true)
    }
}
