//! Browse resolvers — port of
//! `lib/mydia_web/schema/resolvers/browse_resolver.ex`.
//!
//! - List queries (`movies`, `tvShows`, `libraries`) emit Relay-style
//!   connections with the Phoenix-shaped `cursor:<offset>` cursor.
//! - Single-item queries (`movie`, `tvShow`, `episode`, `season`,
//!   `libraryPath`) return `Option<T>`; missing IDs surface as
//!   `null` data plus a top-level error matching Phoenix's
//!   `{:error, "Not found"}`. async-graphql translates `Err(...)`
//!   from a resolver into that shape.
//! - `node(id: ID!)` decodes the global ID and dispatches to the
//!   relevant single-item resolver, exactly as
//!   `BrowseResolver.get_node/3` does.
//!
//! Pagination semantics match Phoenix's in-memory implementation:
//! fetch all rows of the requested type, sort, slice. This is the
//! shape the parity replay corpus pins. Keyset pagination is a
//! follow-up.

use async_graphql::{Context, Enum, InputObject, Object, ID};

use crate::context::GraphqlAppState;
use crate::node_id::{NodeId, NodeRef};
use crate::relay::{decode_offset_cursor, offset_cursor};
use crate::repos::{media, settings};
use crate::types::{
    Episode, LibraryPath, Movie, MovieConnection, MovieEdge, PageInfo, Season, TvShow,
    TvShowConnection, TvShowEdge,
};

const DEFAULT_FIRST: i32 = 20;
const MAX_FIRST: i32 = 200;

/// Sort field — port of the Absinthe `:sort_field` enum
/// (`lib/mydia_web/schema/enum_types.ex`).
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum, Default)]
#[graphql(name = "SortField")]
pub enum SortField {
    #[default]
    Title,
    AddedAt,
    Year,
    Rating,
}

#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum, Default)]
#[graphql(name = "SortDirection")]
pub enum SortDirection {
    #[default]
    Asc,
    Desc,
}

/// Sort args — port of the Absinthe `:sort_input` input object.
#[derive(Debug, Default, Clone, Copy, InputObject)]
#[graphql(name = "SortInput")]
pub struct SortInput {
    #[graphql(default)]
    pub field: SortField,
    #[graphql(default)]
    pub direction: SortDirection,
}

/// Media category enum — port of `:media_category`. Values mirror
/// `lib/mydia_web/schema/enum_types.ex:43-50`.
#[derive(Debug, Copy, Clone, PartialEq, Eq, Enum)]
#[graphql(name = "MediaCategory")]
pub enum MediaCategory {
    Anime,
    Standard,
    Documentary,
    StandUp,
    Reality,
    Adult,
}

impl MediaCategory {
    fn as_db_str(self) -> &'static str {
        match self {
            Self::Anime => "anime",
            Self::Standard => "standard",
            Self::Documentary => "documentary",
            Self::StandUp => "stand_up",
            Self::Reality => "reality",
            Self::Adult => "adult",
        }
    }
}

#[derive(Default)]
pub struct BrowseQueries;

#[Object]
impl BrowseQueries {
    /// List all movies, sorted and paginated.
    async fn movies(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 20)] first: i32,
        after: Option<String>,
        sort: Option<SortInput>,
        category: Option<MediaCategory>,
    ) -> async_graphql::Result<MovieConnection> {
        let state = ctx.data::<GraphqlAppState>()?;
        let opts = media::ListMediaItemsOpts {
            kind: Some("movie"),
            category: category.map(|c| c.as_db_str()),
            has_files: true,
            added_since: None,
            search: None,
        };
        let rows = media::list_media_items(&state.db, &opts).await?;
        let sort = sort.unwrap_or_default();
        let sorted = sort_media_items(rows, sort);
        let total = sorted.len() as i32;

        let (page, page_info) = paginate(&sorted, first, after.as_deref());
        let edges = page
            .into_iter()
            .filter_map(|(item, cursor)| {
                Movie::from_row(&item).map(|node| MovieEdge { node, cursor })
            })
            .collect();

        Ok(MovieConnection {
            edges,
            page_info,
            total_count: total,
        })
    }

    /// List all TV shows.
    async fn tv_shows(
        &self,
        ctx: &Context<'_>,
        #[graphql(default = 20)] first: i32,
        after: Option<String>,
        sort: Option<SortInput>,
        category: Option<MediaCategory>,
    ) -> async_graphql::Result<TvShowConnection> {
        let state = ctx.data::<GraphqlAppState>()?;
        let opts = media::ListMediaItemsOpts {
            kind: Some("tv_show"),
            category: category.map(|c| c.as_db_str()),
            has_files: true,
            added_since: None,
            search: None,
        };
        let rows = media::list_media_items(&state.db, &opts).await?;
        let sort = sort.unwrap_or_default();
        let sorted = sort_media_items(rows, sort);
        let total = sorted.len() as i32;

        let (page, page_info) = paginate(&sorted, first, after.as_deref());
        let edges = page
            .into_iter()
            .filter_map(|(item, cursor)| {
                TvShow::from_row(&item).map(|node| TvShowEdge { node, cursor })
            })
            .collect();

        Ok(TvShowConnection {
            edges,
            page_info,
            total_count: total,
        })
    }

    /// Fetch one movie by global node ID or plain UUID.
    async fn movie(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<Movie> {
        let state = ctx.data::<GraphqlAppState>()?;
        let row_id = resolve_id(id.as_str(), Some("movie"))?;
        let item = media::get_media_item(&state.db, &row_id)
            .await?
            .ok_or_else(|| async_graphql::Error::new("Movie not found"))?;
        Movie::from_row(&item).ok_or_else(|| async_graphql::Error::new("Not a movie"))
    }

    /// Fetch one TV show.
    async fn tv_show(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<TvShow> {
        let state = ctx.data::<GraphqlAppState>()?;
        let row_id = resolve_id(id.as_str(), Some("show"))?;
        let item = media::get_media_item(&state.db, &row_id)
            .await?
            .ok_or_else(|| async_graphql::Error::new("TV show not found"))?;
        TvShow::from_row(&item).ok_or_else(|| async_graphql::Error::new("Not a TV show"))
    }

    /// Fetch one episode.
    async fn episode(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<Episode> {
        let state = ctx.data::<GraphqlAppState>()?;
        let row_id = resolve_id(id.as_str(), Some("episode"))?;
        let row = media::get_episode(&state.db, &row_id)
            .await?
            .ok_or_else(|| async_graphql::Error::new("Episode not found"))?;
        Ok(Episode::from_row(&row))
    }

    /// List all library paths.
    async fn libraries(&self, ctx: &Context<'_>) -> async_graphql::Result<Vec<LibraryPath>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let rows = settings::list_library_paths(&state.db).await?;
        Ok(rows.iter().filter_map(LibraryPath::from_row).collect())
    }

    /// Get a specific library path.
    async fn library_path(&self, ctx: &Context<'_>, id: ID) -> async_graphql::Result<LibraryPath> {
        let state = ctx.data::<GraphqlAppState>()?;
        let row_id = resolve_id(id.as_str(), Some("library"))?;
        let row = settings::get_library_path(&state.db, &row_id)
            .await?
            .ok_or_else(|| async_graphql::Error::new("Library path not found"))?;
        LibraryPath::from_row(&row)
            .ok_or_else(|| async_graphql::Error::new("Library path missing type"))
    }

    /// List episodes for a given show + season number.
    async fn season_episodes(
        &self,
        ctx: &Context<'_>,
        show_id: ID,
        season_number: i32,
    ) -> async_graphql::Result<Vec<Episode>> {
        let state = ctx.data::<GraphqlAppState>()?;
        let show_id = resolve_id(show_id.as_str(), Some("show"))?;
        let rows = media::list_episodes(&state.db, &show_id).await?;
        Ok(rows
            .into_iter()
            .filter(|e| e.season_number == Some(season_number))
            .map(|e| Episode::from_row(&e))
            .collect())
    }

    /// Materialise a virtual `Season` for a show + season number.
    async fn season(
        &self,
        ctx: &Context<'_>,
        show_id: ID,
        season_number: i32,
    ) -> async_graphql::Result<Season> {
        let state = ctx.data::<GraphqlAppState>()?;
        let show_id = resolve_id(show_id.as_str(), Some("show"))?;
        let _show = media::get_media_item(&state.db, &show_id)
            .await?
            .ok_or_else(|| async_graphql::Error::new("TV show not found"))?;
        let episodes = media::list_episodes(&state.db, &show_id).await?;
        let season_eps: Vec<&mydia_rs_models::Episode> = episodes
            .iter()
            .filter(|e| e.season_number == Some(season_number))
            .collect();
        if season_eps.is_empty() {
            return Err(async_graphql::Error::new("Season not found"));
        }
        let mut has_files = false;
        for ep in &season_eps {
            if media::episode_has_files(&state.db, &ep.id.0.to_string()).await? {
                has_files = true;
                break;
            }
        }
        Season::build(&show_id, season_number, &episodes, has_files)
            .ok_or_else(|| async_graphql::Error::new("Season not found"))
    }
}

/// Sort a Vec<MediaItem> in place using the given sort args.
/// Phoenix sorts in-memory after the DB fetch; mirror that behavior
/// to keep parity with the captured corpus.
fn sort_media_items(
    mut rows: Vec<mydia_rs_models::MediaItem>,
    sort: SortInput,
) -> Vec<mydia_rs_models::MediaItem> {
    rows.sort_by(|a, b| {
        let ord = match sort.field {
            SortField::Title => a
                .title
                .as_deref()
                .unwrap_or("")
                .to_lowercase()
                .cmp(&b.title.as_deref().unwrap_or("").to_lowercase()),
            SortField::Year => a.year.cmp(&b.year),
            SortField::AddedAt => a.inserted_at.0.cmp(&b.inserted_at.0),
            SortField::Rating => media_item_rating(a).total_cmp(&media_item_rating(b)),
        };
        if matches!(sort.direction, SortDirection::Desc) {
            ord.reverse()
        } else {
            ord
        }
    });
    rows
}

fn media_item_rating(row: &mydia_rs_models::MediaItem) -> f64 {
    row.metadata
        .as_ref()
        .and_then(|m| m.0.get("vote_average").and_then(|v| v.as_f64()))
        .unwrap_or(0.0)
}

/// Apply Phoenix's offset-based pagination + cursor encoding.
/// Returns the page slice paired with cursor strings and the
/// connection-level PageInfo.
fn paginate(
    items: &[mydia_rs_models::MediaItem],
    first: i32,
    after: Option<&str>,
) -> (Vec<(mydia_rs_models::MediaItem, String)>, PageInfo) {
    let first = first.clamp(0, MAX_FIRST) as usize;
    let offset = after
        .and_then(decode_offset_cursor)
        .map(|o| o + 1)
        .unwrap_or(0);

    let total = items.len();
    let end = (offset + first).min(total);
    let slice = if offset < total {
        &items[offset..end]
    } else {
        &[]
    };

    let paginated: Vec<(mydia_rs_models::MediaItem, String)> = slice
        .iter()
        .enumerate()
        .map(|(i, item)| (item.clone(), offset_cursor(offset + i)))
        .collect();

    let has_next_page = end < total;
    let has_previous_page = offset > 0;
    let start_cursor = paginated.first().map(|(_, c)| c.clone());
    let end_cursor = paginated.last().map(|(_, c)| c.clone());

    let _ = DEFAULT_FIRST; // referenced by docs only
    (
        paginated,
        PageInfo {
            has_next_page,
            has_previous_page,
            start_cursor,
            end_cursor,
        },
    )
}

/// Decode a node ID or accept a raw UUID. Phoenix's resolvers
/// accept both forms — the `id` field is `ID` (string), and the
/// client may pass either the encoded `movie:<uuid>` form or the
/// raw UUID. When `expected_tag` is `Some(tag)`, decoded node IDs
/// of other kinds are rejected so a stray `movie(id: "show:...")`
/// fails cleanly.
fn resolve_id(input: &str, expected_tag: Option<&str>) -> async_graphql::Result<String> {
    match NodeId::decode(input) {
        Ok(node) => {
            if let Some(expected) = expected_tag {
                if node.type_tag() != expected {
                    return Err(async_graphql::Error::new(format!(
                        "Invalid {} id: expected `{expected}:<id>`",
                        expected
                    )));
                }
            }
            Ok(match node {
                NodeId::Movie(NodeRef::Str(s))
                | NodeId::TvShow(NodeRef::Str(s))
                | NodeId::Episode(NodeRef::Str(s))
                | NodeId::LibraryPath(NodeRef::Str(s)) => s,
                NodeId::Movie(NodeRef::Int(n))
                | NodeId::TvShow(NodeRef::Int(n))
                | NodeId::Episode(NodeRef::Int(n))
                | NodeId::LibraryPath(NodeRef::Int(n)) => n.to_string(),
                NodeId::Season { show_id, .. } => match show_id {
                    NodeRef::Str(s) => s,
                    NodeRef::Int(n) => n.to_string(),
                },
            })
        }
        Err(_) => {
            // Accept raw UUID/string as well — Phoenix's resolvers do.
            if input.is_empty() {
                Err(async_graphql::Error::new("Empty id"))
            } else {
                Ok(input.to_owned())
            }
        }
    }
}

/// Polymorphic `node(id)` lookup — port of `BrowseResolver.get_node/3`.
pub async fn resolve_node(ctx: &Context<'_>, id: ID) -> async_graphql::Result<Option<NodeBlob>> {
    let state = ctx.data::<GraphqlAppState>()?;
    let decoded =
        NodeId::decode(id.as_str()).map_err(|_| async_graphql::Error::new("Invalid node ID"))?;

    match decoded {
        NodeId::Movie(reference) => {
            let row_id = node_ref_to_string(reference);
            let row = media::get_media_item(&state.db, &row_id).await?;
            Ok(row.and_then(|r| Movie::from_row(&r)).map(NodeBlob::Movie))
        }
        NodeId::TvShow(reference) => {
            let row_id = node_ref_to_string(reference);
            let row = media::get_media_item(&state.db, &row_id).await?;
            Ok(row.and_then(|r| TvShow::from_row(&r)).map(NodeBlob::TvShow))
        }
        NodeId::Episode(reference) => {
            let row_id = node_ref_to_string(reference);
            let row = media::get_episode(&state.db, &row_id).await?;
            Ok(row.map(|r| NodeBlob::Episode(Episode::from_row(&r))))
        }
        NodeId::LibraryPath(reference) => {
            let row_id = node_ref_to_string(reference);
            let row = settings::get_library_path(&state.db, &row_id).await?;
            Ok(row
                .and_then(|r| LibraryPath::from_row(&r))
                .map(NodeBlob::LibraryPath))
        }
        NodeId::Season {
            show_id,
            season_number,
        } => {
            let show_id_str = node_ref_to_string(show_id);
            let episodes = media::list_episodes(&state.db, &show_id_str).await?;
            let has_files = check_any_episode_has_files(
                &state.db,
                &episodes
                    .iter()
                    .filter(|e| e.season_number == Some(season_number))
                    .collect::<Vec<_>>(),
            )
            .await?;
            Ok(
                Season::build(&show_id_str, season_number, &episodes, has_files)
                    .map(NodeBlob::Season),
            )
        }
    }
}

fn node_ref_to_string(reference: NodeRef) -> String {
    match reference {
        NodeRef::Str(s) => s,
        NodeRef::Int(n) => n.to_string(),
    }
}

async fn check_any_episode_has_files(
    db: &mydia_rs_db::Db,
    episodes: &[&mydia_rs_models::Episode],
) -> Result<bool, sqlx::Error> {
    for ep in episodes {
        if media::episode_has_files(db, &ep.id.0.to_string()).await? {
            return Ok(true);
        }
    }
    Ok(false)
}

/// Polymorphic Node-interface stand-in until the full `Interface`
/// enum lands in U10.c. Each variant wraps the concrete type; the
/// `node(id)` resolver returns `Option<NodeBlob>` and async-graphql
/// renders the inner SimpleObject.
#[derive(async_graphql::Union)]
#[graphql(name = "NodeUnion")]
pub enum NodeBlob {
    Movie(Movie),
    TvShow(TvShow),
    Episode(Episode),
    Season(Season),
    LibraryPath(LibraryPath),
}
