use async_graphql::{Context, Object, ID};
use chrono::{DateTime, Utc};
use sea_orm::entity::prelude::*;
use sea_orm::QueryOrder;

use crate::auth_guards::require_user;
use crate::context::GraphqlAppState;
use crate::node_id::{NodeId, NodeRef};
use crate::repos::media as media_repo;
use crate::types::CalendarEntry;

#[derive(Default)]
pub struct CalendarQueries;

#[Object]
impl CalendarQueries {
    async fn calendar(
        &self,
        ctx: &Context<'_>,
        start: DateTime<Utc>,
        end: DateTime<Utc>,
    ) -> async_graphql::Result<Vec<CalendarEntry>> {
        require_user(ctx)?;
        if start >= end {
            return Err(async_graphql::Error::new("start must be before end"));
        }

        let state = ctx.data::<GraphqlAppState>()?;
        let start_date = start.date_naive();
        let end_date = end.date_naive();

        let episode_rows = mydia_rs_entities::episodes::Entity::find()
            .filter(mydia_rs_entities::episodes::Column::AirDate.is_not_null())
            .filter(mydia_rs_entities::episodes::Column::AirDate.gte(start_date))
            .filter(mydia_rs_entities::episodes::Column::AirDate.lte(end_date))
            .order_by_asc(mydia_rs_entities::episodes::Column::AirDate)
            .all(&state.db)
            .await?;

        let mut entries = Vec::with_capacity(episode_rows.len());
        for ep in &episode_rows {
            let show_title = media_repo::get_media_item(&state.db, &ep.media_item_id.0.to_string())
                .await?
                .map_or_else(|| "Unknown".to_string(), |s| s.title);

            let has_file = media_repo::episode_has_files(&state.db, &ep.id.0.to_string())
                .await
                .unwrap_or(false);

            entries.push(CalendarEntry {
                id: ID(NodeId::Episode(NodeRef::Str(ep.id.0.to_string())).encode()),
                show_title,
                show_id: ep.media_item_id.0.to_string(),
                season_number: ep.season_number,
                episode_number: ep.episode_number,
                episode_title: ep.title.clone(),
                air_date: ep.air_date,
                monitored: ep.monitored.unwrap_or(false),
                has_file,
            });
        }

        Ok(entries)
    }
}
