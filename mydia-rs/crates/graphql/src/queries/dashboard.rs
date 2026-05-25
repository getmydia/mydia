use async_graphql::{Context, Object};
use chrono::{Duration, Utc};
use sea_orm::entity::prelude::*;
use sea_orm::{QueryOrder, QuerySelect};

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::types::DashboardStats;

#[derive(Default)]
pub struct DashboardQueries;

#[Object]
impl DashboardQueries {
    async fn dashboard_stats(&self, ctx: &Context<'_>) -> async_graphql::Result<DashboardStats> {
        require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;

        let total_movies = mydia_rs_entities::media_items::Entity::find()
            .filter(mydia_rs_entities::media_items::Column::Type.eq("movie"))
            .count(&state.db)
            .await? as i32;

        let total_tv_shows = mydia_rs_entities::media_items::Entity::find()
            .filter(mydia_rs_entities::media_items::Column::Type.eq("tv_show"))
            .count(&state.db)
            .await? as i32;

        let total_episodes = mydia_rs_entities::episodes::Entity::find()
            .count(&state.db)
            .await? as i32;

        let watched_episodes = mydia_rs_entities::playback_progress::Entity::find()
            .filter(mydia_rs_entities::playback_progress::Column::Watched.eq(true))
            .count(&state.db)
            .await? as i32;

        let total_libraries = mydia_rs_entities::library_paths::Entity::find()
            .count(&state.db)
            .await? as i32;

        let today = Utc::now().date_naive();

        let missing_episodes = mydia_rs_entities::episodes::Entity::find()
            .filter(mydia_rs_entities::episodes::Column::AirDate.lte(today))
            .left_join(mydia_rs_entities::media_files::Entity)
            .filter(mydia_rs_entities::media_files::Column::EpisodeId.is_null())
            .count(&state.db)
            .await? as i32;

        let monitored_movies = mydia_rs_entities::media_items::Entity::find()
            .filter(mydia_rs_entities::media_items::Column::Type.eq("movie"))
            .filter(mydia_rs_entities::media_items::Column::Monitored.eq(true))
            .count(&state.db)
            .await? as i32;

        let monitored_tv_shows = mydia_rs_entities::media_items::Entity::find()
            .filter(mydia_rs_entities::media_items::Column::Type.eq("tv_show"))
            .filter(mydia_rs_entities::media_items::Column::Monitored.eq(true))
            .count(&state.db)
            .await? as i32;

        Ok(DashboardStats {
            total_movies,
            total_tv_shows,
            total_episodes,
            watched_episodes,
            total_libraries,
            missing_episodes,
            monitored_movies,
            monitored_tv_shows,
        })
    }

    async fn recent_episodes(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 10)] limit: i32,
    ) -> async_graphql::Result<Vec<crate::types::Episode>> {
        require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let today = Utc::now().date_naive();

        let rows = mydia_rs_entities::episodes::Entity::find()
            .filter(mydia_rs_entities::episodes::Column::AirDate.is_not_null())
            .filter(mydia_rs_entities::episodes::Column::AirDate.lte(today))
            .order_by_desc(mydia_rs_entities::episodes::Column::AirDate)
            .limit(limit.clamp(1, 50) as u64)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(crate::types::Episode::from_row).collect())
    }

    async fn upcoming_episodes(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 14)] days: i32,
    ) -> async_graphql::Result<Vec<crate::types::Episode>> {
        require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let today = Utc::now().date_naive();
        let end = today + Duration::days(i64::from(days.clamp(1, 90)));

        let rows = mydia_rs_entities::episodes::Entity::find()
            .filter(mydia_rs_entities::episodes::Column::AirDate.is_not_null())
            .filter(mydia_rs_entities::episodes::Column::AirDate.gte(today))
            .filter(mydia_rs_entities::episodes::Column::AirDate.lte(end))
            .order_by_asc(mydia_rs_entities::episodes::Column::AirDate)
            .all(&state.db)
            .await?;

        Ok(rows.iter().map(crate::types::Episode::from_row).collect())
    }
}
