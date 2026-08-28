//! Discovery, search and remote access types.
//!
//! Types owned by this module (keep in sync with tests/types_remaining.rs):
//! ContinueWatchingItem, RemoveFromContinueWatchingResult, RecentlyAddedItem,
//! UpNextItem, Collection, SearchResult, SearchSection, SearchResults,
//! RemoteAccessStatus, ServerCompatibility, CalendarEntry, CalendarEntryKind.

use async_graphql::{Enum, SimpleObject, ID};

use crate::types::{
    common::{MediaType, SearchResultType},
    media::{Artwork, Date, Episode, MediaFile, Progress, RecentlyAddedItem, TvShow},
};

#[derive(SimpleObject)]
pub struct ContinueWatchingItem {
    pub id: ID,
    #[graphql(name = "type")]
    pub media_type: MediaType,
    pub title: String,
    pub artwork: Option<Artwork>,
    pub progress: Progress,
    pub files: Option<Vec<Option<MediaFile>>>,
    pub show_id: Option<ID>,
    pub show_title: Option<String>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    /// Why this item is on the rail: continue for a resume point, next for the
    /// successor of a finished episode.
    pub state: Option<String>,
}

#[derive(SimpleObject)]
pub struct RemoveFromContinueWatchingResult {
    pub media_item_id: ID,
    pub removed: bool,
}

#[derive(SimpleObject)]
pub struct UpNextItem {
    pub episode: Episode,
    pub show: TvShow,
    pub progress_state: String,
}

#[derive(SimpleObject)]
pub struct Collection {
    pub id: ID,
    pub name: String,
    pub description: Option<String>,
    #[graphql(name = "type")]
    pub collection_type: String,
    pub visibility: String,
    pub item_count: i32,
    pub poster_paths: Option<Vec<Option<String>>>,
}

#[derive(SimpleObject)]
pub struct SearchResult {
    pub id: ID,
    #[graphql(name = "type")]
    pub result_type: SearchResultType,
    pub title: String,
    pub year: Option<i32>,
    pub artwork: Option<Artwork>,
    pub score: Option<f64>,
    pub subtitle: Option<String>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub parent_id: Option<ID>,
}

#[derive(SimpleObject)]
pub struct SearchSection {
    #[graphql(name = "type")]
    pub result_type: SearchResultType,
    pub results: Vec<SearchResult>,
    pub total_count: i32,
}

#[derive(SimpleObject)]
pub struct SearchResults {
    pub sections: Vec<SearchSection>,
    pub total_count: i32,
}

#[derive(SimpleObject)]
pub struct RemoteAccessStatus {
    pub enabled: bool,
    pub endpoint_addr: Option<String>,
    pub connected_peers: i32,
}

/// What this server needs from a connecting player.
///
/// Schema-only, like every type in this crate: the values a real server would
/// return are Elixir-side constants. It exists because the player talks to
/// both servers and GraphQL rejects an entire query containing an unknown
/// field, so omitting it here would break the query, not just the field.
#[derive(SimpleObject)]
pub struct ServerCompatibility {
    pub version: String,
    pub min_player_version: String,
    pub recommended_player_version: String,
}

/// Whether a calendar entry is an episode or a movie
#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum CalendarEntryKind {
    /// A TV episode, dated by its air date
    Episode,
    /// A movie, dated by its release date
    Movie,
}

/// One dated item on the player's calendar
#[derive(SimpleObject)]
pub struct CalendarEntry {
    /// Episode ID, or media item ID for a movie
    pub id: ID,
    /// Episode or movie
    pub kind: CalendarEntryKind,
    /// Air date, or release date for a movie
    pub air_date: Date,
    /// Episode title, or movie title
    pub title: String,
    /// Season number, null for a movie
    pub season_number: Option<i32>,
    /// Episode number, null for a movie
    pub episode_number: Option<i32>,
    /// The parent show, or the movie itself
    pub media_item_id: ID,
    /// Show name, or movie title
    pub media_item_title: String,
    pub artwork: Option<Artwork>,
    /// Playable files for this entry, empty when the library holds nothing
    pub files: Vec<MediaFile>,
}

/// Renders just this group's types as SDL.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn continue_watching_item(&self) -> ContinueWatchingItem {
            std::future::pending().await
        }

        async fn remove_from_continue_watching_result(&self) -> RemoveFromContinueWatchingResult {
            std::future::pending().await
        }

        async fn up_next_item(&self) -> UpNextItem {
            std::future::pending().await
        }

        async fn collection(&self) -> Collection {
            std::future::pending().await
        }

        async fn search_result(&self) -> SearchResult {
            std::future::pending().await
        }

        async fn search_section(&self) -> SearchSection {
            std::future::pending().await
        }

        async fn search_results(&self) -> SearchResults {
            std::future::pending().await
        }

        async fn remote_access_status(&self) -> RemoteAccessStatus {
            std::future::pending().await
        }

        async fn server_compatibility(&self) -> ServerCompatibility {
            std::future::pending().await
        }

        async fn calendar_entry(&self) -> CalendarEntry {
            std::future::pending().await
        }
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .register_output_type::<RecentlyAddedItem>()
        .finish()
        .sdl()
}
