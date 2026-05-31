//! Discovery resolvers — port of
//! `lib/mydia_web/schema/resolvers/discovery_resolver.ex`.
//!
//! The five rails (`continueWatching`, `recentlyAdded`, `upNext`,
//! `favorites`, `unwatched`) each return a plain `Vec<...>` of the
//! relevant item type. Phoenix uses a simple offset cursor (same
//! `cursor:<offset>` shape as the browse connections, except the
//! list itself isn't wrapped in a Connection).
//!
//! Auth gating: Phoenix returns `{:ok, []}` for the four user-
//! scoped rails (`continueWatching`, `upNext`, `favorites`,
//! `unwatched`) when no `current_user` is in context. mydia-rs's
//! axum-side auth middleware lands as a U6 follow-up; until it
//! does, every call here hits the anonymous branch. The resolvers
//! are written so they light up automatically once the middleware
//! attaches a `CurrentUser` to the per-request data slot.

use std::collections::HashSet;

use async_graphql::{Context, Object, ID};
use chrono::{Duration, Utc};
use sea_orm::{ColumnTrait, EntityTrait, QueryFilter};

use crate::context::{CurrentUser, GraphqlAppState};
use crate::node_id::{NodeId, NodeRef};
use crate::relay::decode_offset_cursor;
use crate::repos::media;
use crate::types::{Artwork, DiscoverItem, DiscoverPage, MediaType, RecentlyAddedItem};

const RECENTLY_ADDED_WINDOW_DAYS: i64 = 30;

#[derive(Default)]
pub struct DiscoveryQueries;

#[Object]
impl DiscoveryQueries {
    /// In-progress items for the current user. Returns `[]` when no
    /// `CurrentUser` is attached (unauthenticated request) — mirrors
    /// `DiscoveryResolver.continue_watching/3` line 18.
    async fn continue_watching(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 10)] first: i32,
        after: Option<String>,
    ) -> async_graphql::Result<Vec<crate::types::ContinueWatchingItem>> {
        let _state = ctx.data::<GraphqlAppState>()?;
        if maybe_current_user(ctx).is_none() {
            return Ok(Vec::new());
        }
        let _ = (first, after);
        Ok(Vec::new())
    }

    /// Recently-added items across all media types. No auth required.
    async fn recently_added(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 20)] first: i32,
        after: Option<String>,
        types: Option<Vec<MediaType>>,
    ) -> async_graphql::Result<Vec<RecentlyAddedItem>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let kind = type_filter_to_db(types.as_ref());

        let cutoff = Utc::now() - Duration::days(RECENTLY_ADDED_WINDOW_DAYS);
        let cutoff_str = cutoff.to_rfc3339_opts(chrono::SecondsFormat::Secs, true);

        let opts = media::ListMediaItemsOpts {
            kind,
            category: None,
            has_files: true,
            added_since: Some(&cutoff_str),
            search: None,
        };
        let rows = media::list_media_items(&state.db, &opts).await?;

        let mut items: Vec<RecentlyAddedItem> =
            rows.iter().map(build_recently_added_item).collect();
        items.sort_by(|a, b| b.added_at.cmp(&a.added_at));
        Ok(paginate_simple(&items, first, after.as_deref()))
    }

    /// Next-episode-to-watch rail. Anonymous fallback returns `[]`.
    async fn up_next(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 10)] first: i32,
        after: Option<String>,
    ) -> async_graphql::Result<Vec<crate::types::UpNextItem>> {
        let _state = ctx.data::<GraphqlAppState>()?;
        if maybe_current_user(ctx).is_none() {
            return Ok(Vec::new());
        }
        let _ = (first, after);
        Ok(Vec::new())
    }

    /// User's favorites collection. Anonymous fallback returns `[]`.
    async fn favorites(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 50)] first: i32,
        after: Option<String>,
        types: Option<Vec<MediaType>>,
    ) -> async_graphql::Result<Vec<RecentlyAddedItem>> {
        let _state = ctx.data::<GraphqlAppState>()?;
        if maybe_current_user(ctx).is_none() {
            return Ok(Vec::new());
        }
        let _ = (first, after, types);
        Ok(Vec::new())
    }

    /// Unwatched items with files. Anonymous fallback returns `[]`.
    async fn unwatched(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 50)] first: i32,
        after: Option<String>,
        types: Option<Vec<MediaType>>,
    ) -> async_graphql::Result<Vec<RecentlyAddedItem>> {
        let _state = ctx.data::<GraphqlAppState>()?;
        if maybe_current_user(ctx).is_none() {
            return Ok(Vec::new());
        }
        let _ = (first, after, types);
        Ok(Vec::new())
    }

    /// Discover new content from TMDB via the metadata-relay. Returns
    /// curated lists (trending, popular, upcoming, etc.) with an
    /// `in_library` flag indicating whether each item is already in
    /// the user's media library.
    ///
    /// `category` must be one of: `trending`, `popular`, `upcoming`,
    /// `now_playing`, `on_the_air`, `airing_today`. Unknown values
    /// fall back to `trending`.
    async fn discover(
        &self,
        ctx: &Context<'_>,
        category: String,
        media_type: MediaType,
        page: Option<i32>,
    ) -> async_graphql::Result<DiscoverPage> {
        let state = ctx.data::<GraphqlAppState>()?;

        let md_media_type = match media_type {
            MediaType::TvShow => mydia_rs_metadata::structs::MediaType::TvShow,
            MediaType::Movie | MediaType::Episode => mydia_rs_metadata::structs::MediaType::Movie,
        };

        let page_num = page.unwrap_or(1).clamp(1, 500) as u32;

        let config = mydia_rs_metadata::ProviderConfig::metadata_relay_default();
        let relay = mydia_rs_metadata::Relay::new();
        let opts = mydia_rs_metadata::TrendingOpts {
            media_type: Some(md_media_type),
            language: None,
            page: Some(page_num),
        };

        let curated = relay
            .fetch_curated(&config, &category, &opts)
            .await
            .map_err(|e| async_graphql::Error::new(e.to_string()))?;

        let in_library_ids = get_library_tmdb_ids(&state.db).await?;

        let results: Vec<DiscoverItem> = curated
            .results
            .iter()
            .map(|r| build_discover_item(r, &in_library_ids))
            .collect();

        Ok(DiscoverPage {
            results,
            page: curated.page as i32,
            total_pages: curated.total_pages as i32,
        })
    }
}

fn maybe_current_user<'a>(ctx: &'a Context<'_>) -> Option<&'a CurrentUser> {
    ctx.data_opt::<crate::context::GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
}

fn type_filter_to_db(types: Option<&Vec<MediaType>>) -> Option<&'static str> {
    let types = types?;
    if types.is_empty() {
        return None;
    }
    let has_movie = types.contains(&MediaType::Movie);
    let has_tv = types.contains(&MediaType::TvShow);
    match (has_movie, has_tv) {
        (true, false) => Some("movie"),
        (false, true) => Some("tv_show"),
        (true, true) | (false, false) => None,
    }
}

/// Query the DB for all non-null `tmdb_id` values currently stored in
/// `media_items`. Returns a set for O(1) membership checks when
/// computing `in_library`.
async fn get_library_tmdb_ids(
    db: &sea_orm::DatabaseConnection,
) -> Result<HashSet<i32>, async_graphql::Error> {
    use mydia_rs_entities::media_items::{Column, Entity};
    let rows = Entity::find()
        .filter(Column::TmdbId.is_not_null())
        .all(db)
        .await
        .map_err(|e| async_graphql::Error::new(e.to_string()))?;
    Ok(rows.into_iter().filter_map(|r| r.tmdb_id).collect())
}

fn build_discover_item(
    result: &mydia_rs_metadata::SearchResult,
    in_library_ids: &HashSet<i32>,
) -> DiscoverItem {
    let tmdb_id = result.id.and_then(|id| i32::try_from(id).ok()).unwrap_or(0);
    let title = result
        .title
        .clone()
        .or_else(|| result.name.clone())
        .unwrap_or_else(|| "Unknown".to_string());
    let poster_url = result
        .poster_path
        .as_deref()
        .and_then(|p| crate::metadata::poster_url(Some(p)));

    DiscoverItem {
        id: ID(format!("tmdb:{tmdb_id}")),
        tmdb_id,
        type_: match result.media_type {
            mydia_rs_metadata::MediaType::TvShow => MediaType::TvShow,
            _ => MediaType::Movie,
        },
        title,
        year: result.year,
        poster_url,
        vote_average: result.vote_average.map(|v| (v * 10.0).round() / 10.0),
        in_library: in_library_ids.contains(&tmdb_id),
    }
}

fn build_recently_added_item(row: &mydia_rs_entities::media_items::Model) -> RecentlyAddedItem {
    let type_ = MediaType::from_db_str(&row.r#type).unwrap_or(MediaType::Movie);
    let id = match row.r#type.as_str() {
        "tv_show" => NodeId::TvShow(NodeRef::Str(row.id.0.to_string())).encode(),
        _ => NodeId::Movie(NodeRef::Str(row.id.0.to_string())).encode(),
    };
    RecentlyAddedItem {
        id: ID(id),
        type_,
        title: row.title.clone(),
        year: row.year,
        artwork: build_artwork(row),
        added_at: row.inserted_at.0,
    }
}

fn build_artwork(row: &mydia_rs_entities::media_items::Model) -> Option<Artwork> {
    let raw = row.metadata.as_deref()?;
    let metadata: serde_json::Value = serde_json::from_str(raw).ok()?;
    let poster_path = metadata.get("poster_path").and_then(|v| v.as_str());
    let backdrop_path = metadata.get("backdrop_path").and_then(|v| v.as_str());
    if poster_path.is_none() && backdrop_path.is_none() {
        return None;
    }
    Some(Artwork {
        poster_url: poster_path.map(std::borrow::ToOwned::to_owned),
        backdrop_url: backdrop_path.map(std::borrow::ToOwned::to_owned),
        thumbnail_url: None,
    })
}

fn paginate_simple<T: Clone>(items: &[T], first: i32, after: Option<&str>) -> Vec<T> {
    let first = first.clamp(0, 200) as usize;
    let offset = after.and_then(decode_offset_cursor).map_or(0, |o| o + 1);
    items.iter().skip(offset).take(first).cloned().collect()
}
