//! The root query type.
//!
//! Every field here is a stub: it returns an empty collection or `None`.
//! Slice 2 onward replace each stub with a real implementation against
//! `mydia_db`. None of them panic, because a panicking resolver would take
//! down a request the player made in good faith.

use async_graphql::{Context, Error, Object, Result, ID};

use crate::context::{authenticated_user, ApiContext};
use crate::mapping::ExternalsByFile;
use crate::types::auth::{remote_device_from, ApiKey, RemoteDevice};
use crate::types::common::{
    MediaCategory, MediaType, Node, PageInfo, SearchResultType, SortInput, SubtitleFormat,
};
use crate::types::discovery::{
    Collection, ContinueWatchingItem, RemoteAccessStatus, SearchResults, UpNextItem,
};
use crate::types::media::{
    Episode, LibraryPath, Movie, MovieConnection, MovieEdge, RecentlyAddedItem,
    SubtitleProviderStatus, SubtitleSearchPayload, TvShow, TvShowConnection, TvShowEdge,
};
use crate::types::streaming::StreamingCandidatesResult;
use mydia_db::media_files::MediaFileRow;
use mydia_db::media_items::{BrowseField, BrowseSort};

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
    async fn node(&self, ctx: &Context<'_>, id: ID) -> Result<Option<Node>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let Some(reference) = crate::node_id::decode(id.as_str()) else {
            return Ok(None);
        };

        let node = match reference {
            crate::node_id::NodeRef::Movie(id) => match find_item(api, &id, "movie").await? {
                Some(item) => {
                    let files = mydia_db::media_files::list_for_item(&api.db, &item.id)
                        .await
                        .map_err(|e| Error::new(e.to_string()))?;
                    let externals = externals_for(&api.db, &files).await?;

                    Some(Node::Movie(Box::new(crate::mapping::movie_from(
                        &item, &files, &externals,
                    ))))
                }
                None => None,
            },
            crate::node_id::NodeRef::TvShow(id) => match find_item(api, &id, "tv_show").await? {
                Some(item) => Some(Node::TvShow(Box::new(load_show(api, &item).await?))),
                None => None,
            },
            crate::node_id::NodeRef::Episode(id) => {
                match mydia_db::episodes::find(&api.db, &id)
                    .await
                    .map_err(|e| Error::new(e.to_string()))?
                {
                    Some(row) => {
                        let files = mydia_db::media_files::list_for_episode(&api.db, &row.id)
                            .await
                            .map_err(|e| Error::new(e.to_string()))?;
                        let externals = externals_for(&api.db, &files).await?;

                        Some(Node::Episode(Box::new(crate::mapping::episode_from(
                            &row, &files, None, &externals,
                        ))))
                    }
                    None => None,
                }
            }
            crate::node_id::NodeRef::LibraryPath(id) => mydia_db::library_paths::find(&api.db, &id)
                .await
                .map_err(|e| Error::new(e.to_string()))?
                .map(|row| Node::LibraryPath(Box::new(crate::mapping::library_path_from(&row)))),
            crate::node_id::NodeRef::Season {
                show_id,
                season_number,
            } => match find_item(api, &show_id, "tv_show").await? {
                Some(item) => load_show(api, &item)
                    .await?
                    .seasons
                    .and_then(|seasons| {
                        seasons
                            .into_iter()
                            .flatten()
                            .find(|season| i64::from(season.season_number) == season_number)
                    })
                    .map(|season| Node::Season(Box::new(season))),
                None => None,
            },
        };

        Ok(node)
    }

    /// List all library paths
    async fn libraries(&self, ctx: &Context<'_>) -> Result<Option<Vec<Option<LibraryPath>>>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let rows = mydia_db::library_paths::list(&api.db)
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        Ok(Some(
            rows.iter()
                .map(|row| Some(crate::mapping::library_path_from(row)))
                .collect(),
        ))
    }

    /// Get a movie by ID
    async fn movie(&self, ctx: &Context<'_>, id: ID) -> Result<Option<Movie>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let Some(item) = mydia_db::media_items::find(&api.db, id.as_str())
            .await
            .map_err(|e| Error::new(e.to_string()))?
        else {
            return Ok(None);
        };

        if item.media_type != "movie" {
            return Ok(None);
        }

        let files = mydia_db::media_files::list_for_item(&api.db, &item.id)
            .await
            .map_err(|e| Error::new(e.to_string()))?;
        let externals = externals_for(&api.db, &files).await?;

        Ok(Some(crate::mapping::movie_from(&item, &files, &externals)))
    }

    /// Get a TV show by ID
    async fn tv_show(&self, ctx: &Context<'_>, id: ID) -> Result<Option<TvShow>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let Some(item) = mydia_db::media_items::find(&api.db, id.as_str())
            .await
            .map_err(|e| Error::new(e.to_string()))?
        else {
            return Ok(None);
        };

        if item.media_type != "tv_show" {
            return Ok(None);
        }

        Ok(Some(load_show(api, &item).await?))
    }

    /// Get an episode by ID
    async fn episode(&self, ctx: &Context<'_>, id: ID) -> Result<Option<Episode>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let Some(row) = mydia_db::episodes::find(&api.db, id.as_str())
            .await
            .map_err(|e| Error::new(e.to_string()))?
        else {
            return Ok(None);
        };

        let files = mydia_db::media_files::list_for_episode(&api.db, &row.id)
            .await
            .map_err(|e| Error::new(e.to_string()))?;
        let externals = externals_for(&api.db, &files).await?;

        Ok(Some(crate::mapping::episode_from(
            &row, &files, None, &externals,
        )))
    }

    /// List all movies with pagination
    async fn movies(
        &self,
        ctx: &Context<'_>,
        first: Option<i32>,
        after: Option<String>,
        sort: Option<SortInput>,
        category: Option<MediaCategory>,
    ) -> Result<Option<MovieConnection>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        // Slice 2a knows only Movie and TvShow. The finer categories need
        // genres, which arrive with the metadata in Slice 2b, so asking for
        // one returns nothing rather than everything.
        if !matches!(category, None | Some(MediaCategory::Movie)) {
            return Ok(Some(MovieConnection {
                edges: Vec::new(),
                page_info: empty_page_info(),
                total_count: 0,
            }));
        }

        let page = Page::new(first, after);
        let total = mydia_db::media_items::count(&api.db, "movie")
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        let items = mydia_db::media_items::browse(
            &api.db,
            "movie",
            browse_sort(sort.as_ref()),
            page.first,
            page.offset,
        )
        .await
        .map_err(|e| Error::new(e.to_string()))?;

        let mut edges = Vec::with_capacity(items.len());

        for (index, item) in items.iter().enumerate() {
            let files = mydia_db::media_files::list_for_item(&api.db, &item.id)
                .await
                .map_err(|e| Error::new(e.to_string()))?;
            let externals = externals_for(&api.db, &files).await?;

            edges.push(MovieEdge {
                node: crate::mapping::movie_from(item, &files, &externals),
                // Page-local, mirroring browse_resolver.ex:93-97. See the
                // note in this task's description before "fixing" it.
                cursor: crate::cursor::encode(index as i64),
            });
        }

        Ok(Some(MovieConnection {
            page_info: page.info(total, edges.len() as i64),
            edges,
            total_count: i32::try_from(total).unwrap_or(i32::MAX),
        }))
    }

    /// List all TV shows with pagination
    async fn tv_shows(
        &self,
        ctx: &Context<'_>,
        first: Option<i32>,
        after: Option<String>,
        sort: Option<SortInput>,
        category: Option<MediaCategory>,
    ) -> Result<Option<TvShowConnection>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        if !matches!(category, None | Some(MediaCategory::TvShow)) {
            return Ok(Some(TvShowConnection {
                edges: Vec::new(),
                page_info: empty_page_info(),
                total_count: 0,
            }));
        }

        let page = Page::new(first, after);
        let total = mydia_db::media_items::count(&api.db, "tv_show")
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        let items = mydia_db::media_items::browse(
            &api.db,
            "tv_show",
            browse_sort(sort.as_ref()),
            page.first,
            page.offset,
        )
        .await
        .map_err(|e| Error::new(e.to_string()))?;

        let mut edges = Vec::with_capacity(items.len());

        for (index, item) in items.iter().enumerate() {
            edges.push(TvShowEdge {
                node: load_show(api, item).await?,
                cursor: crate::cursor::encode(index as i64),
            });
        }

        Ok(Some(TvShowConnection {
            page_info: page.info(total, edges.len() as i64),
            edges,
            total_count: i32::try_from(total).unwrap_or(i32::MAX),
        }))
    }

    /// Get episodes for a specific season of a TV show
    async fn season_episodes(
        &self,
        ctx: &Context<'_>,
        show_id: ID,
        season_number: i32,
    ) -> Result<Option<Vec<Option<Episode>>>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let rows = mydia_db::episodes::list_for_season(
            &api.db,
            show_id.as_str(),
            i64::from(season_number),
        )
        .await
        .map_err(|e| Error::new(e.to_string()))?;

        let mut episodes = Vec::with_capacity(rows.len());

        for row in rows {
            let files = mydia_db::media_files::list_for_episode(&api.db, &row.id)
                .await
                .map_err(|e| Error::new(e.to_string()))?;
            let externals = externals_for(&api.db, &files).await?;

            episodes.push(Some(crate::mapping::episode_from(
                &row, &files, None, &externals,
            )));
        }

        Ok(Some(episodes))
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
    #[graphql(
        deprecation = "Merged into continueWatching, which now carries next episodes as well"
    )]
    async fn up_next(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Result<Option<Vec<Option<UpNextItem>>>> {
        Ok(None)
    }

    /// Get the user's favorite items
    ///
    /// `category` and `sort` exist here for contract parity with the Elixir
    /// schema, which grew them so the player can pin saved filters like
    /// "Favorite Anime Movies". This server answers favorites in Slice 4, so
    /// they are accepted and ignored until then rather than omitted, which
    /// would fail the whole query document for any player that sends them.
    async fn favorites(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _types: Option<Vec<Option<MediaType>>>,
        _category: Option<MediaCategory>,
        _sort: Option<SortInput>,
    ) -> Result<Option<Vec<Option<RecentlyAddedItem>>>> {
        Ok(None)
    }

    /// Get unwatched items with files
    ///
    /// See [`Self::favorites`] for why `category` and `sort` are accepted and
    /// ignored rather than left out.
    async fn unwatched(
        &self,
        _ctx: &Context<'_>,
        _first: Option<i32>,
        _after: Option<String>,
        _types: Option<Vec<Option<MediaType>>>,
        _category: Option<MediaCategory>,
        _sort: Option<SortInput>,
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
    /// Search every enabled subtitle provider for a media file.
    ///
    /// query_types.ex:`:subtitle_search`. This server acquires no media, which
    /// includes not fetching subtitles from providers, so the search is always
    /// empty. It reports that as a provider status rather than an empty result
    /// list with no explanation, so a client can tell "nothing found" apart
    /// from "this backend does not do that".
    ///
    /// The field exists at all because the player talks to both servers and
    /// GraphQL rejects an entire query containing an unknown field. Omitting it
    /// here would break every query that mentions it, not just this field.
    async fn subtitle_search(
        &self,
        ctx: &Context<'_>,
        _media_file_id: ID,
        _languages: Vec<String>,
    ) -> Result<SubtitleSearchPayload> {
        authenticated_user(ctx).await?;

        Ok(SubtitleSearchPayload {
            results: vec![],
            providers: vec![SubtitleProviderStatus {
                name: "Mydia Server".to_string(),
                quota_remaining: None,
                quota_total: None,
                error: Some("This server does not download subtitles from providers.".to_string()),
            }],
        })
    }

    /// Fetch one subtitle track's body directly, without resolving every
    /// track on the media file.
    ///
    /// query_types.ex:`:subtitle_content`. Mirrors `SubtitleTrack::content`
    /// above: this server acquires no media and does not extract subtitle
    /// bodies, so it answers null rather than guessing. Present for contract
    /// parity, since the player selects this field regardless of which
    /// server answered the query.
    async fn subtitle_content(
        &self,
        ctx: &Context<'_>,
        _media_file_id: ID,
        _track_id: String,
        _format: Option<SubtitleFormat>,
    ) -> Result<Option<String>> {
        authenticated_user(ctx).await?;

        Ok(None)
    }

    async fn streaming_candidates(
        &self,
        ctx: &Context<'_>,
        content_type: String,
        id: ID,
    ) -> Result<Option<StreamingCandidatesResult>> {
        let api = ctx.data::<ApiContext>()?;
        authenticated_user(ctx).await?;

        let row = crate::streaming::resolve_file(&api.db, &content_type, id.as_str()).await?;

        Ok(Some(crate::streaming::candidates_for(&row)))
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

/// Finds an item and confirms it is the type the caller asked for, so
/// `movie:<a show's id>` resolves to nothing rather than to a mislabelled node.
async fn find_item(
    api: &ApiContext,
    id: &str,
    media_type: &str,
) -> Result<Option<mydia_db::media_items::MediaItemRow>> {
    let found = mydia_db::media_items::find(&api.db, id)
        .await
        .map_err(|e| Error::new(e.to_string()))?;

    Ok(found.filter(|item| item.media_type == media_type))
}

/// Loads a show with every episode and each episode's files.
///
/// One query per episode. A season of 24 is 24 queries, which is acceptable at
/// this scale and is the honest simple version; batching belongs with the
/// dataloader Slice 4 will need anyway for progress.
pub(crate) async fn load_show(
    api: &ApiContext,
    item: &mydia_db::media_items::MediaItemRow,
) -> Result<TvShow> {
    let rows = mydia_db::episodes::list_for_show(&api.db, &item.id)
        .await
        .map_err(|e| Error::new(e.to_string()))?;

    let mut episodes = Vec::with_capacity(rows.len());

    for row in rows {
        let files = mydia_db::media_files::list_for_episode(&api.db, &row.id)
            .await
            .map_err(|e| Error::new(e.to_string()))?;

        episodes.push((row, files));
    }

    let all_files: Vec<MediaFileRow> = episodes
        .iter()
        .flat_map(|(_, files)| files.iter().cloned())
        .collect();
    let externals = externals_for(&api.db, &all_files).await?;

    Ok(crate::mapping::tv_show_from(item, &episodes, &externals))
}

/// Loads external subtitle rows for a set of files in one query, grouped by
/// file.
///
/// One query per file reads fine for a movie, which has one or two, but
/// `load_show` passes every file of every episode: a long-running series turns
/// a single `tvShow` query into hundreds of round trips.
async fn externals_for(db: &mydia_db::Db, files: &[MediaFileRow]) -> Result<ExternalsByFile> {
    let ids: Vec<String> = files.iter().map(|f| f.id.clone()).collect();

    let rows = mydia_db::external_subtitles::list_for_files(db, &ids)
        .await
        .map_err(|e| Error::new(e.to_string()))?;

    let mut map = ExternalsByFile::new();

    for row in rows {
        map.entry(row.media_file_id.clone()).or_default().push(row);
    }

    Ok(map)
}

/// One page's worth of arguments, with the Elixir server's defaults
/// (browse_resolver.ex:66-68).
struct Page {
    first: i64,
    offset: i64,
}

impl Page {
    fn new(first: Option<i32>, after: Option<String>) -> Self {
        Self {
            first: first.map(i64::from).unwrap_or(20).max(0),
            offset: after
                .as_deref()
                .map(|cursor| crate::cursor::decode(cursor) + 1)
                .unwrap_or(0)
                .max(0),
        }
    }

    /// pageInfo cursors use the real offset, unlike the edge cursors above.
    fn info(&self, total: i64, returned: i64) -> PageInfo {
        if returned == 0 {
            return PageInfo {
                has_next_page: total > self.offset,
                has_previous_page: self.offset > 0,
                start_cursor: None,
                end_cursor: None,
            };
        }

        PageInfo {
            has_next_page: total > self.offset + returned,
            has_previous_page: self.offset > 0,
            start_cursor: Some(crate::cursor::encode(self.offset)),
            end_cursor: Some(crate::cursor::encode(self.offset + returned - 1)),
        }
    }
}

fn browse_sort(sort: Option<&SortInput>) -> BrowseSort {
    use crate::types::common::{SortDirection, SortField};

    let field = match sort.and_then(|s| s.field) {
        Some(SortField::Year) => BrowseField::Year,
        Some(SortField::AddedAt) => BrowseField::AddedAt,
        Some(SortField::Rating) => BrowseField::Rating,
        // The contract carries seven more fields that this server cannot
        // answer yet: runtime, popularity, content rating and release date
        // need the metadata JSON, last played and watch state need the
        // progress join, and random needs seeded ordering. Listing them
        // explicitly rather than letting them vanish into the wildcard, so
        // adding one here is a compile-time prompt rather than a silent
        // fallback nobody notices.
        Some(
            SortField::Runtime
            | SortField::Popularity
            | SortField::ContentRating
            | SortField::ReleaseDate
            | SortField::LastPlayed
            | SortField::WatchState
            | SortField::Random,
        ) => BrowseField::Title,
        // Title is the default and the fallback, matching MediaSort's
        // catch-all clause.
        Some(SortField::Title) | None => BrowseField::Title,
    };

    BrowseSort {
        field,
        descending: matches!(sort.and_then(|s| s.direction), Some(SortDirection::Desc)),
    }
}
