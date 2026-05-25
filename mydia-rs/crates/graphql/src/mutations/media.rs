use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::Set;

use crate::auth_guards::require_admin;
use crate::context::GraphqlAppState;
use crate::types::Movie;

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "AddMediaToLibraryInput")]
pub struct AddMediaToLibraryInput {
    pub media_type: String,
    pub title: String,
    pub tmdb_id: Option<i32>,
    pub tvdb_id: Option<i32>,
    pub quality_profile_id: Option<String>,
    pub monitored: Option<bool>,
    pub monitoring_preset: Option<String>,
}

#[derive(Debug, Clone, InputObject)]
#[graphql(name = "FinalizeImportInput")]
pub struct FinalizeImportInput {
    pub session_id: String,
}

fn parse_id(id: &str) -> async_graphql::Result<UuidText> {
    uuid::Uuid::parse_str(id)
        .map(UuidText)
        .map_err(|_| async_graphql::Error::new("Invalid ID format"))
}

#[derive(Default)]
pub struct MediaMutations;

#[Object]
impl MediaMutations {
    async fn toggle_media_monitored(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let item_id = parse_id(id.as_str())?;

        let item = mydia_rs_entities::media_items::Entity::find()
            .filter(
                Expr::col(mydia_rs_entities::media_items::Column::Id)
                    .eq(item_id.into_simple_expr(backend)),
            )
            .one(&state.db)
            .await?
            .ok_or_else(|| async_graphql::Error::new("Media item not found"))?;

        let new_val = !item.monitored.unwrap_or(false);
        let now = DateTimeSecs::from(chrono::Utc::now());

        let active = mydia_rs_entities::media_items::ActiveModel {
            id: Set(item_id),
            monitored: Set(Some(new_val)),
            updated_at: Set(now),
            ..Default::default()
        };

        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(new_val)
    }

    async fn toggle_episode_monitored(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let backend = state.db.get_database_backend();
        let ep_id = parse_id(id.as_str())?;

        let ep = mydia_rs_entities::episodes::Entity::find()
            .filter(
                Expr::col(mydia_rs_entities::episodes::Column::Id)
                    .eq(ep_id.into_simple_expr(backend)),
            )
            .one(&state.db)
            .await?
            .ok_or_else(|| async_graphql::Error::new("Episode not found"))?;

        let new_val = !ep.monitored.unwrap_or(false);
        let now = DateTimeSecs::from(chrono::Utc::now());

        let active = mydia_rs_entities::episodes::ActiveModel {
            id: Set(ep_id),
            monitored: Set(Some(new_val)),
            updated_at: Set(now),
            ..Default::default()
        };

        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(new_val)
    }

    async fn delete_media(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let item_id = parse_id(id.as_str())?;

        let result = mydia_rs_entities::media_items::Entity::delete_by_id(item_id)
            .exec(&state.db)
            .await?;

        Ok(result.rows_affected > 0)
    }

    async fn add_media_to_library(
        &self,
        ctx: &Context<'_>,
        input: AddMediaToLibraryInput,
    ) -> async_graphql::Result<Movie> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let id = uuid::Uuid::new_v4();
        let now = DateTimeSecs::from(chrono::Utc::now());

        let quality_profile_id = input
            .quality_profile_id
            .as_deref()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .map(UuidText);

        let model = mydia_rs_entities::media_items::ActiveModel {
            id: Set(UuidText(id)),
            r#type: Set(input.media_type),
            title: Set(input.title),
            original_title: Set(None),
            year: Set(None),
            tmdb_id: Set(input.tmdb_id),
            imdb_id: Set(None),
            metadata: Set(None),
            monitored: Set(input.monitored),
            inserted_at: Set(now),
            updated_at: Set(now),
            quality_profile_id: Set(quality_profile_id),
            category: Set(None),
            category_override: Set(false),
            monitoring_preset: Set(input.monitoring_preset),
            tvdb_id: Set(input.tvdb_id),
            seasons_refreshed_at: Set(None),
        };

        let row = mydia_rs_db::insert_active_model(model, &state.db).await?;
        Movie::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Failed to create media item"))
    }

    async fn finalize_import(
        &self,
        ctx: &Context<'_>,
        input: FinalizeImportInput,
    ) -> async_graphql::Result<bool> {
        require_admin(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let session_id = parse_id(&input.session_id)?;

        let now = DateTimeSecs::from(chrono::Utc::now());

        let active = mydia_rs_entities::import_sessions::ActiveModel {
            id: Set(session_id),
            status: Set("completed".to_string()),
            completed_at: Set(Some(now)),
            updated_at: Set(now),
            ..Default::default()
        };

        mydia_rs_db::update_active_model(active, &state.db).await?;
        Ok(true)
    }
}
