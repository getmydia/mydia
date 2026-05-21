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

use async_graphql::{Context, Object, ID};
use chrono::{Duration, Utc};

use crate::context::{CurrentUser, GraphqlAppState};
use crate::node_id::{NodeId, NodeRef};
use crate::relay::decode_offset_cursor;
use crate::repos::media;
use crate::types::{Artwork, MediaType, RecentlyAddedItem};

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
        // Playback context port lands alongside the auth middleware
        // (U6 follow-up). Once `playback_progress` is queryable from
        // Rust, this resolver consumes it and applies the same
        // 90%-completion filter Phoenix uses.
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
        let kind = type_filter_to_db(&types);

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
        // Phoenix sorts by inserted_at DESC after fetching.
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
    /// Favorites moved to the `collections` table in
    /// `priv/repo/migrations/20251228233656_migrate_favorites_to_collections.exs`;
    /// the Collections context port lands in U14 and this resolver
    /// activates then.
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
}

fn maybe_current_user<'a>(ctx: &'a Context<'_>) -> Option<&'a CurrentUser> {
    ctx.data_opt::<crate::context::GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
}

/// Map a `Vec<MediaType>` from the GraphQL surface to the single
/// `type` filter Phoenix accepts. Phoenix's logic: if both Movie and
/// TvShow are included, no filter; otherwise return the lone kind.
fn type_filter_to_db(types: &Option<Vec<MediaType>>) -> Option<&'static str> {
    let Some(types) = types else { return None };
    if types.is_empty() {
        return None;
    }
    let has_movie = types.contains(&MediaType::Movie);
    let has_tv = types.contains(&MediaType::TvShow);
    match (has_movie, has_tv) {
        (true, true) => None,
        (true, false) => Some("movie"),
        (false, true) => Some("tv_show"),
        (false, false) => None,
    }
}

fn build_recently_added_item(row: &mydia_rs_models::MediaItem) -> RecentlyAddedItem {
    let type_ = row
        .r#type
        .as_deref()
        .and_then(MediaType::from_db_str)
        .unwrap_or(MediaType::Movie);
    let id = match row.r#type.as_deref() {
        Some("tv_show") => NodeId::TvShow(NodeRef::Str(row.id.0.to_string())).encode(),
        _ => NodeId::Movie(NodeRef::Str(row.id.0.to_string())).encode(),
    };
    RecentlyAddedItem {
        id: ID(id),
        type_,
        title: row.title.clone().unwrap_or_default(),
        year: row.year,
        artwork: build_artwork(row),
        added_at: row.inserted_at.0,
    }
}

fn build_artwork(row: &mydia_rs_models::MediaItem) -> Option<Artwork> {
    let metadata = row.metadata.as_ref()?;
    let poster_path = metadata.0.get("poster_path").and_then(|v| v.as_str());
    let backdrop_path = metadata.0.get("backdrop_path").and_then(|v| v.as_str());
    if poster_path.is_none() && backdrop_path.is_none() {
        return None;
    }
    Some(Artwork {
        // U10.c will route these through the metadata-relay-aware
        // ImageUrl helpers. For U10.b we surface the raw paths so
        // the field is non-empty without misrepresenting the URL.
        poster_url: poster_path.map(|p| p.to_owned()),
        backdrop_url: backdrop_path.map(|p| p.to_owned()),
        thumbnail_url: None,
    })
}

fn paginate_simple<T: Clone>(items: &[T], first: i32, after: Option<&str>) -> Vec<T> {
    let first = first.clamp(0, 200) as usize;
    let offset = after
        .and_then(decode_offset_cursor)
        .map(|o| o + 1)
        .unwrap_or(0);
    items.iter().skip(offset).take(first).cloned().collect()
}
