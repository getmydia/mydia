//! The root query type.
//!
//! Every field here is a stub: it returns an empty collection or `None`.
//! Slice 2 onward replace each stub with a real implementation against
//! `mydia_db`. None of them panic, because a panicking resolver would take
//! down a request the player made in good faith.

use async_graphql::{Context, Error, Object, Result, ID};

use crate::context::{authenticated_user, not_implemented, ApiContext};
use crate::types::auth::{remote_device_from, ApiKey, RemoteDevice};
use crate::types::common::{MediaCategory, MediaType, Node, PageInfo, SearchResultType, SortInput};
use crate::types::discovery::{
    Collection, ContinueWatchingItem, RemoteAccessStatus, SearchResults, UpNextItem,
};
use crate::types::media::{
    Episode, LibraryPath, Movie, MovieConnection, RecentlyAddedItem, TvShow, TvShowConnection,
};
use crate::types::streaming::StreamingCandidatesResult;

/// An empty page, for connection fields that back an empty library. The
/// player relies on `edges: []` and a real `PageInfo`, not `null`, to render
/// an empty state rather than treat the field as missing.
fn empty_page_info() -> PageInfo {
    PageInfo {
        has_next_page: false,
        has_previous_page: false,
        start_cursor: None,
        end_cursor: None,
    }
}

pub struct RootQueryType;

#[Object(name = "RootQueryType")]
impl RootQueryType {
    /// Get any node by its global ID
    async fn node(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<Node>> {
        Ok(None)
    }

    /// List all library paths
    async fn libraries(&self, _ctx: &Context<'_>) -> Result<Option<Vec<Option<LibraryPath>>>> {
        Ok(None)
    }

    /// Get a movie by ID
    async fn movie(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<Movie>> {
        Ok(None)
    }

    /// Get a TV show by ID
    async fn tv_show(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<TvShow>> {
        Ok(None)
    }

    /// Get an episode by ID
    async fn episode(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<Episode>> {
        Ok(None)
    }

    /// List all movies with pagination
    async fn movies(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _sort: Option<SortInput>,
        _category: Option<MediaCategory>,
    ) -> Result<Option<MovieConnection>> {
        Ok(Some(MovieConnection {
            edges: Vec::new(),
            page_info: empty_page_info(),
            total_count: 0,
        }))
    }

    /// List all TV shows with pagination
    async fn tv_shows(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _sort: Option<SortInput>,
        _category: Option<MediaCategory>,
    ) -> Result<Option<TvShowConnection>> {
        Ok(Some(TvShowConnection {
            edges: Vec::new(),
            page_info: empty_page_info(),
            total_count: 0,
        }))
    }

    /// Get episodes for a specific season of a TV show
    async fn season_episodes(
        &self,
        _ctx: &Context<'_>,
        _show_id: ID,
        _season_number: i32,
    ) -> Result<Option<Vec<Option<Episode>>>> {
        Ok(None)
    }

    /// Get items the user is currently watching (in-progress)
    async fn continue_watching(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Result<Option<Vec<Option<ContinueWatchingItem>>>> {
        Ok(None)
    }

    /// Get recently added content
    async fn recently_added(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _types: Option<Vec<Option<MediaType>>>,
    ) -> Result<Option<Vec<Option<RecentlyAddedItem>>>> {
        Ok(None)
    }

    /// Get next episodes to watch across all TV shows
    async fn up_next(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Result<Option<Vec<Option<UpNextItem>>>> {
        Ok(None)
    }

    /// Get the user's favorite items
    async fn favorites(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _types: Option<Vec<Option<MediaType>>>,
    ) -> Result<Option<Vec<Option<RecentlyAddedItem>>>> {
        Ok(None)
    }

    /// Get unwatched items with files
    async fn unwatched(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _types: Option<Vec<Option<MediaType>>>,
    ) -> Result<Option<Vec<Option<RecentlyAddedItem>>>> {
        Ok(None)
    }

    /// Search the library across movies, TV shows, episodes, and collections
    async fn search(
        &self,
        _ctx: &Context<'_>,
        _query: String,
        _types: Option<Vec<Option<SearchResultType>>>,
        _first: Option<i32>,
    ) -> Result<Option<SearchResults>> {
        Ok(None)
    }

    /// List all API keys for the current user
    async fn api_keys(&self, _ctx: &Context<'_>) -> Result<Option<Vec<Option<ApiKey>>>> {
        Ok(None)
    }

    /// List all devices for the current user
    async fn devices(&self, ctx: &Context<'_>) -> Result<Option<Vec<Option<RemoteDevice>>>> {
        let api = ctx.data::<ApiContext>()?;
        let user = authenticated_user(ctx).await?;

        let devices = mydia_db::devices::list_for_user(&api.db, &user.id)
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        let devices = devices
            .into_iter()
            .map(|d| remote_device_from(d).map(Some))
            .collect::<Result<Vec<_>>>()?;

        Ok(Some(devices))
    }

    /// Get remote access / P2P connection status
    async fn remote_access_status(&self, _ctx: &Context<'_>) -> Result<Option<RemoteAccessStatus>> {
        Ok(None)
    }

    /// Get streaming candidates for a media item
    async fn streaming_candidates(
        &self,
        _ctx: &Context<'_>,
        _content_type: String,
        _id: ID,
    ) -> Result<Option<StreamingCandidatesResult>> {
        Err(not_implemented("streamingCandidates"))
    }

    /// List user's collections (excluding system collections)
    async fn collections(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
    ) -> Result<Option<Vec<Option<Collection>>>> {
        Ok(None)
    }

    /// Get a single collection by ID
    async fn collection(&self, _ctx: &Context<'_>, _id: ID) -> Result<Option<Collection>> {
        Ok(None)
    }

    /// Get items in a collection
    async fn collection_items(
        &self,
        _ctx: &Context<'_>,
        _collection_id: ID,
        _first: Option<i32>,
    ) -> Result<Option<Vec<Option<RecentlyAddedItem>>>> {
        Ok(None)
    }
}
