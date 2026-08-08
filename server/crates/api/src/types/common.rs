//! Enums, the Node interface, pagination machinery, and the shared sort
//! input.
//!
//! The 16 types owned by this module (keep in sync with
//! tests/types_common.rs): Node, NodeEdge, NodeConnection, PageInfo,
//! SortInput, and the enums DeviceEventType, MediaType, SearchResultType,
//! LibraryType, SortField, SortDirection, MediaCategory, SubtitleFormat,
//! StreamingStrategy, StreamingCandidateStrategy, SegmentType.

use async_graphql::{Enum, InputObject, Interface, Object, SimpleObject, ID};

#[derive(SimpleObject)]
pub struct PageInfo {
    pub has_next_page: bool,
    pub has_previous_page: bool,
    pub start_cursor: Option<String>,
    pub end_cursor: Option<String>,
}

#[derive(SimpleObject)]
pub struct NodeEdge {
    pub node: Node,
    pub cursor: String,
}

#[derive(SimpleObject)]
pub struct NodeConnection {
    pub edges: Vec<NodeEdge>,
    pub page_info: PageInfo,
    pub total_count: i32,
}

#[derive(InputObject)]
pub struct SortInput {
    pub field: Option<SortField>,
    pub direction: Option<SortDirection>,
}

#[derive(Interface)]
#[graphql(
    field(name = "id", ty = "&ID"),
    field(name = "parent", ty = "Option<&Node>"),
    field(
        name = "children",
        ty = "Option<&NodeConnection>",
        arg(name = "first", ty = "Option<i32>"),
        arg(name = "after", ty = "Option<String>")
    ),
    field(name = "ancestors", ty = "Option<&Vec<Option<Node>>>"),
    field(name = "is_playable", ty = "&bool")
)]
pub enum Node {
    Movie(Box<crate::types::media::Movie>),
    TvShow(Box<crate::types::media::TvShow>),
    Season(Box<crate::types::media::Season>),
    Episode(Box<crate::types::media::Episode>),
    LibraryPath(Box<crate::types::media::LibraryPath>),
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum DeviceEventType {
    Connected,
    Disconnected,
    Revoked,
    Deleted,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum MediaType {
    Movie,
    TvShow,
    Episode,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum SearchResultType {
    Movie,
    TvShow,
    Episode,
    Collection,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum LibraryType {
    Movies,
    Series,
    Mixed,
    Music,
    Books,
    Adult,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum SortField {
    Title,
    AddedAt,
    Year,
    Rating,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum SortDirection {
    Asc,
    Desc,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum MediaCategory {
    Movie,
    AnimeMovie,
    CartoonMovie,
    TvShow,
    AnimeSeries,
    CartoonSeries,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum SubtitleFormat {
    Srt,
    Vtt,
    Ass,
    Ssa,
    Pgs,
    Vobsub,
    Unknown,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum StreamingStrategy {
    HlsCopy,
    Transcode,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum StreamingCandidateStrategy {
    DirectPlay,
    Remux,
    HlsCopy,
    Transcode,
}

#[derive(Enum, Copy, Clone, Eq, PartialEq)]
pub enum SegmentType {
    Intro,
    Credits,
}

/// Renders just this group's types as SDL, so the group can be compared
/// against the contract before the whole schema exists.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn node(&self) -> Node {
            std::future::pending().await
        }

        async fn page_info(&self) -> PageInfo {
            PageInfo {
                has_next_page: false,
                has_previous_page: false,
                start_cursor: None,
                end_cursor: None,
            }
        }

        async fn sort_input(&self, _sort: Option<SortInput>) -> bool {
            false
        }

        async fn device_event_type(&self) -> DeviceEventType {
            DeviceEventType::Connected
        }

        async fn media_type(&self) -> MediaType {
            MediaType::Movie
        }

        async fn search_result_type(&self) -> SearchResultType {
            SearchResultType::Movie
        }

        async fn library_type(&self) -> LibraryType {
            LibraryType::Movies
        }

        async fn media_category(&self) -> MediaCategory {
            MediaCategory::Movie
        }

        async fn subtitle_format(&self) -> SubtitleFormat {
            SubtitleFormat::Srt
        }

        async fn streaming_strategy(&self) -> StreamingStrategy {
            StreamingStrategy::HlsCopy
        }

        async fn streaming_candidate_strategy(&self) -> StreamingCandidateStrategy {
            StreamingCandidateStrategy::DirectPlay
        }

        async fn segment_type(&self) -> SegmentType {
            SegmentType::Intro
        }
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .finish()
        .sdl()
}
