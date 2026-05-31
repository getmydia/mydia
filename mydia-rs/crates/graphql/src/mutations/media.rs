use async_graphql::{Context, InputObject, Object, ID};
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_metadata::Provider;
use sea_orm::entity::prelude::*;
use sea_orm::sea_query::{Expr, ExprTrait};
use sea_orm::Set;
use tracing::warn;

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
        let now = DateTimeSecs::from(chrono::Utc::now());

        // Check if an item with this tmdb_id already exists
        if let Some(tmdb_id) = input.tmdb_id {
            use mydia_rs_entities::media_items::{Column, Entity};
            let existing = Entity::find()
                .filter(Expr::col(Column::TmdbId).eq(tmdb_id))
                .one(&state.db)
                .await?;

            if let Some(existing_row) = existing {
                // Item exists. If it lacks metadata, refresh it now.
                if existing_row.metadata.is_none() {
                    if let Ok(meta) = fetch_tmdb_metadata(tmdb_id, &input.media_type).await {
                        let title = meta.title.clone().unwrap_or(existing_row.title.clone());
                        let metadata_json = serde_json::to_string(&meta).ok();

                        let updated = mydia_rs_entities::media_items::ActiveModel {
                            id: Set(existing_row.id),
                            title: Set(title),
                            original_title: Set(meta.original_title.clone()),
                            year: Set(meta.year),
                            metadata: Set(metadata_json),
                            updated_at: Set(now),
                            ..Default::default()
                        };
                        let row = mydia_rs_db::update_active_model(updated, &state.db).await?;

                        if input.media_type == "tv_show" {
                            let _ = create_episodes_from_tmdb(
                                &state.db,
                                uuid::Uuid::parse_str(&existing_row.id.0.to_string())
                                    .unwrap_or_default(),
                                tmdb_id,
                            )
                            .await;
                        }

                        return Movie::from_row(&row)
                            .ok_or_else(|| async_graphql::Error::new("Failed to build movie"));
                    }
                }

                // Return existing item as-is (already has metadata, or refresh failed)
                return Movie::from_row(&existing_row)
                    .ok_or_else(|| async_graphql::Error::new("Failed to build movie"));
            }
        }

        let id = uuid::Uuid::new_v4();

        let quality_profile_id = input
            .quality_profile_id
            .as_deref()
            .and_then(|s| uuid::Uuid::parse_str(s).ok())
            .map(UuidText);

        let (title, original_title, year, metadata_json) = if let Some(tmdb_id) = input.tmdb_id {
            match fetch_tmdb_metadata(tmdb_id, &input.media_type).await {
                Ok(meta) => {
                    let title = meta.title.clone().unwrap_or(input.title.clone());
                    let original_title = meta.original_title.clone();
                    let year = meta.year;
                    let metadata_json = serde_json::to_string(&meta).ok();
                    (title, original_title, year, metadata_json)
                }
                Err(e) => {
                    warn!(
                        "Failed to fetch TMDB metadata for {} id={}: {}",
                        input.media_type, tmdb_id, e
                    );
                    (input.title.clone(), None, None, None)
                }
            }
        } else {
            (input.title.clone(), None, None, None)
        };

        let model = mydia_rs_entities::media_items::ActiveModel {
            id: Set(UuidText(id)),
            r#type: Set(input.media_type.clone()),
            title: Set(title),
            original_title: Set(original_title),
            year: Set(year),
            tmdb_id: Set(input.tmdb_id),
            imdb_id: Set(None),
            metadata: Set(metadata_json),
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

        if input.media_type == "tv_show" {
            if let Some(tmdb_id) = input.tmdb_id {
                let _ = create_episodes_from_tmdb(&state.db, id, tmdb_id).await;
            }
        }

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

async fn fetch_tmdb_metadata(
    tmdb_id: i32,
    media_type: &str,
) -> Result<mydia_rs_metadata::MediaMetadata, String> {
    let config = mydia_rs_metadata::ProviderConfig::metadata_relay_default();
    let relay = mydia_rs_metadata::Relay::new();
    let md_media_type = match media_type {
        "tv_show" => mydia_rs_metadata::MediaType::TvShow,
        _ => mydia_rs_metadata::MediaType::Movie,
    };
    let opts = mydia_rs_metadata::FetchOpts {
        media_type: Some(md_media_type),
        language: None,
        provider: Some("tmdb"),
        append_to_response: Vec::new(),
    };
    relay
        .fetch_by_id(&config, &tmdb_id.to_string(), &opts)
        .await
        .map_err(|e| e.to_string())
}

async fn create_episodes_from_tmdb(
    db: &sea_orm::DatabaseConnection,
    media_item_id: uuid::Uuid,
    tmdb_id: i32,
) -> Result<(), String> {
    let config = mydia_rs_metadata::ProviderConfig::metadata_relay_default();
    let relay = mydia_rs_metadata::Relay::new();
    let now = DateTimeSecs::from(chrono::Utc::now());

    // First, fetch the show metadata to get the list of seasons
    let opts = mydia_rs_metadata::FetchOpts {
        media_type: Some(mydia_rs_metadata::MediaType::TvShow),
        language: None,
        provider: Some("tmdb"),
        append_to_response: Vec::new(),
    };
    let metadata = relay
        .fetch_by_id(&config, &tmdb_id.to_string(), &opts)
        .await
        .map_err(|e| e.to_string())?;

    for season_info in &metadata.seasons {
        let season_number = season_info.season_number;
        if season_number <= 0 {
            continue;
        }
        let season_opts = mydia_rs_metadata::SeasonOpts {
            language: None,
            tvdb_season_id: None,
        };
        let Ok(season) = relay
            .fetch_season(&config, &tmdb_id.to_string(), season_number, &season_opts)
            .await
        else {
            continue;
        };

        for ep in &season.episodes {
            let ep_metadata = serde_json::to_string(ep).ok();
            let ep_model = mydia_rs_entities::episodes::ActiveModel {
                id: Set(UuidText(uuid::Uuid::new_v4())),
                media_item_id: Set(UuidText(media_item_id)),
                season_number: Set(ep.season_number),
                episode_number: Set(ep.episode_number),
                title: Set(ep.name.clone()),
                air_date: Set(ep.air_date),
                metadata: Set(ep_metadata),
                monitored: Set(Some(true)),
                inserted_at: Set(now),
                updated_at: Set(now),
            };
            let _ = mydia_rs_db::insert_active_model(ep_model, db).await;
        }
    }

    Ok(())
}
