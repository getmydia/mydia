//! Discovery, search and remote access types.
//!
//! Types owned by this module (keep in sync with tests/types_remaining.rs):
//! ContinueWatchingItem, RecentlyAddedItem, UpNextItem, Collection,
//! SearchResult, SearchSection, SearchResults, RemoteAccessStatus.

use async_graphql::{SimpleObject, ID};

use crate::types::{
    common::{MediaType, SearchResultType},
    media::{Artwork, Episode, MediaFile, Progress, RecentlyAddedItem, TvShow},
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

/// Renders just this group's types as SDL.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn continue_watching_item(&self) -> ContinueWatchingItem {
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
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .register_output_type::<RecentlyAddedItem>()
        .finish()
        .sdl()
}
