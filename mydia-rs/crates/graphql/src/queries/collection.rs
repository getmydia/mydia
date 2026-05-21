//! Collection queries — port of
//! `lib/mydia_web/schema/resolvers/collection_resolver.ex`.
//!
//! Three queries:
//!
//! - `collections` — user's non-system collections (i.e. excludes
//!   the Favorites collection). Order matches Phoenix
//!   (`position ASC, name ASC`).
//! - `collection(id)` — single collection by ID.
//! - `collectionItems(collectionId, first)` — items in a collection,
//!   surfaced as the same `RecentlyAddedItem` shape the discovery
//!   rails use. Phoenix builds this with `build_recently_added_item`
//!   inline; mirrored here.

use async_graphql::{Context, Object, ID};

use crate::context::{CurrentUser, GraphqlAppState, GraphqlRequestContext};
use crate::node_id::{NodeId, NodeRef};
use crate::repos::collections_query;
use crate::types::{Artwork, CollectionObject, MediaType, RecentlyAddedItem};

#[derive(Default)]
pub struct CollectionQueries;

#[Object]
impl CollectionQueries {
    async fn collections(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 50)] first: i32,
    ) -> async_graphql::Result<Vec<CollectionObject>> {
        let Some(user) = maybe_user(ctx) else {
            return Ok(Vec::new());
        };
        let state = ctx.data::<GraphqlAppState>()?;
        let rows =
            collections_query::list_collections_for_user(&state.db, &user.id.to_string()).await?;
        let limit = first.max(0) as usize;
        let mut out = Vec::with_capacity(limit.min(rows.len()));
        for row in rows.iter().filter(|r| !r.is_system).take(limit) {
            let count = collections_query::item_count(&state.db, row.id).await?;
            let posters = collections_query::poster_paths(&state.db, row.id, 4).await?;
            out.push(CollectionObject {
                id: ID(row.id.0.to_string()),
                name: row.name.clone(),
                description: row.description.clone(),
                type_: row.r#type.clone(),
                visibility: row.visibility.clone(),
                item_count: count as i32,
                poster_paths: posters,
            });
        }
        Ok(out)
    }

    async fn collection(
        &self,
        ctx: &Context<'_>,
        id: ID,
    ) -> async_graphql::Result<CollectionObject> {
        let user = require_user(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let row =
            collections_query::get_collection_by_id(&state.db, &user.id.to_string(), id.as_str())
                .await?
                .ok_or_else(|| async_graphql::Error::new("Collection not found"))?;
        let count = collections_query::item_count(&state.db, row.id).await?;
        let posters = collections_query::poster_paths(&state.db, row.id, 4).await?;
        Ok(CollectionObject {
            id: ID(row.id.0.to_string()),
            name: row.name,
            description: row.description,
            type_: row.r#type,
            visibility: row.visibility,
            item_count: count as i32,
            poster_paths: posters,
        })
    }

    async fn collection_items(
        &self,
        ctx: &Context<'_>,
        collection_id: ID,
        #[graphql(default = 50)] first: i32,
    ) -> async_graphql::Result<Vec<RecentlyAddedItem>> {
        let Some(user) = maybe_user(ctx) else {
            return Ok(Vec::new());
        };
        let state = ctx.data::<GraphqlAppState>()?;
        let row = collections_query::get_collection_by_id(
            &state.db,
            &user.id.to_string(),
            collection_id.as_str(),
        )
        .await?
        .ok_or_else(|| async_graphql::Error::new("Collection not found"))?;
        let limit = first.max(0) as i64;
        let items = collections_query::list_items(&state.db, row.id, limit).await?;
        Ok(items.iter().map(build_recently_added_item).collect())
    }
}

fn maybe_user<'a>(ctx: &'a Context<'_>) -> Option<&'a CurrentUser> {
    ctx.data_opt::<GraphqlRequestContext>()
        .and_then(|r| r.current_user.as_ref())
}

fn require_user<'a>(ctx: &'a Context<'_>) -> async_graphql::Result<&'a CurrentUser> {
    maybe_user(ctx).ok_or_else(|| async_graphql::Error::new("Not authenticated"))
}

fn build_recently_added_item(row: &mydia_rs_models::MediaItem) -> RecentlyAddedItem {
    let type_ = row
        .r#type
        .as_deref()
        .and_then(MediaType::from_db_str)
        .unwrap_or(MediaType::Movie);
    let id = match row.r#type.as_deref() {
        Some("tv_show") => NodeId::TvShow(NodeRef::Str(row.id.0.to_string())).encode(),
        Some("episode") => NodeId::Episode(NodeRef::Str(row.id.0.to_string())).encode(),
        _ => NodeId::Movie(NodeRef::Str(row.id.0.to_string())).encode(),
    };
    let artwork = row.metadata.as_ref().and_then(|m| {
        let poster =
            m.0.get("poster_path")
                .and_then(|v| v.as_str())
                .map(str::to_owned);
        let backdrop =
            m.0.get("backdrop_path")
                .and_then(|v| v.as_str())
                .map(str::to_owned);
        if poster.is_none() && backdrop.is_none() {
            None
        } else {
            Some(Artwork {
                poster_url: poster,
                backdrop_url: backdrop,
                thumbnail_url: None,
            })
        }
    });
    RecentlyAddedItem {
        id: ID(id),
        type_,
        title: row.title.clone().unwrap_or_default(),
        year: row.year,
        artwork,
        added_at: row.inserted_at.0,
    }
}
