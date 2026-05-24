//! Episode — port of `lib/mydia_web/schema/media_types.ex:236-300`.

use async_graphql::{ComplexObject, Context, SimpleObject, ID};
use chrono::NaiveDate;
use serde_json::Value;

use crate::context::GraphqlAppState;
use crate::metadata;
use crate::node_id::{NodeId, NodeRef};
use crate::repos::media as media_repo;
use crate::types::{MediaFile, Progress, TvShow};

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "Episode", complex)]
pub struct Episode {
    /// Encoded `episode:<uuid>` form.
    pub id: ID,
    /// Plain UUID of the parent media item (the show).
    pub media_item_id: String,
    pub season_number: i32,
    pub episode_number: i32,
    pub title: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub monitored: bool,

    #[graphql(skip)]
    pub plain_id: String,
    #[graphql(skip)]
    pub raw_metadata: Option<Value>,
}

#[ComplexObject]
impl Episode {
    async fn overview(&self) -> Option<String> {
        metadata::get_str(self.raw_metadata.as_ref(), "overview")
            .map(std::borrow::ToOwned::to_owned)
    }

    async fn runtime(&self) -> Option<i32> {
        metadata::get_i64(self.raw_metadata.as_ref(), "runtime").map(|n| n as i32)
    }

    /// Episode thumbnail — `metadata.still_path` prefixed with the
    /// TMDB CDN.
    async fn thumbnail_url(&self) -> Option<String> {
        metadata::still_url(metadata::get_str(self.raw_metadata.as_ref(), "still_path"))
    }

    /// Files for this episode.
    async fn files(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<MediaFile>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = media_repo::list_media_files_for_episode(&state.db, &self.plain_id).await?;
        Ok(rows.iter().map(MediaFile::from_row).collect())
    }

    async fn has_file(&self, ctx: &Context<'_>) -> async_graphql::Result<bool> {
        let state = ctx.data::<GraphqlAppState>()?;
        media_repo::episode_has_files(&state.db, &self.plain_id)
            .await
            .map_err(Into::into)
    }

    /// User playback progress on this episode. Anonymous fallback.
    async fn progress(&self, _ctx: &Context<'_>) -> Option<Progress> {
        None
    }

    /// Parent show — full `TvShow` object. The Phoenix resolver loads
    /// the show by `episode.media_item_id`.
    async fn show(&self, ctx: &Context<'_>) -> async_graphql::Result<Option<TvShow>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let row = media_repo::get_media_item(&state.db, &self.media_item_id).await?;
        Ok(row.and_then(|r| TvShow::from_row(&r)))
    }
}

impl Episode {
    pub fn from_row(row: &mydia_rs_entities::episodes::Model) -> Self {
        Self {
            id: NodeId::Episode(NodeRef::Str(row.id.0.to_string()))
                .encode()
                .into(),
            media_item_id: row.media_item_id.0.to_string(),
            season_number: row.season_number,
            episode_number: row.episode_number,
            title: row.title.clone(),
            air_date: row.air_date,
            monitored: row.monitored.unwrap_or(false),
            plain_id: row.id.0.to_string(),
            raw_metadata: row
                .metadata
                .as_deref()
                .and_then(|s| serde_json::from_str(s).ok()),
        }
    }
}
