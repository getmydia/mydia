//! Media-shaped types.
//!
//! The 17 types owned by this module (keep in sync with
//! tests/types_media.rs): Movie, TvShow, Season, Episode, ShowNextUp,
//! MovieEdge, MovieConnection, TvShowEdge, TvShowConnection, Artwork,
//! CastMember, MediaFile, MediaSegment, Progress, LibraryPath,
//! RecentlyAddedItem, SubtitleTrack.

use async_graphql::{
    ComplexObject, InputValueError, InputValueResult, Scalar, ScalarType, SimpleObject, Value, ID,
};
use chrono::{DateTime, NaiveDate, Utc};

use crate::types::common::{
    LibraryType, MediaCategory, MediaType, Node, NodeConnection, PageInfo, SegmentType,
    SubtitleFormat,
};

#[derive(Clone)]
pub struct Date(pub NaiveDate);

#[Scalar(name = "Date")]
impl ScalarType for Date {
    fn parse(value: Value) -> InputValueResult<Self> {
        match value {
            Value::String(value) => Ok(Self(
                value
                    .parse::<NaiveDate>()
                    .map_err(|_| InputValueError::custom("not a date"))?,
            )),
            other => Err(InputValueError::expected_type(other)),
        }
    }

    fn to_value(&self) -> Value {
        Value::String(self.0.to_string())
    }
}

#[derive(SimpleObject)]
pub struct Artwork {
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub thumbnail_url: Option<String>,
}

#[derive(SimpleObject)]
pub struct Progress {
    pub position_seconds: i32,
    pub duration_seconds: Option<i32>,
    pub percentage: Option<f64>,
    pub watched: bool,
    pub last_watched_at: Option<DateTime<Utc>>,
}

#[derive(SimpleObject)]
pub struct MediaSegment {
    #[graphql(name = "type")]
    pub segment_type: SegmentType,
    pub start_ms: i32,
    pub end_ms: i32,
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct SubtitleTrack {
    pub track_id: String,
    pub language: String,
    pub title: String,
    pub format: String,
    pub embedded: bool,
}

#[ComplexObject]
impl SubtitleTrack {
    async fn url(&self, _format: Option<SubtitleFormat>) -> Option<String> {
        None
    }
}

#[derive(SimpleObject)]
pub struct MediaFile {
    pub id: ID,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    /// Bytes. i64 rather than i32: a 4 GB film overflows 32 bits, and the
    /// contract's `Int` is Absinthe's non-spec-compliant 2^53 Int, so the
    /// Elixir server already emits real byte counts. async-graphql renders
    /// i64 under the same `Int` scalar, so the SDL is unchanged.
    pub size: Option<i64>,
    pub bitrate: Option<i32>,
    pub direct_play_supported: Option<bool>,
    pub stream_url: Option<String>,
    pub direct_play_url: Option<String>,
    pub subtitles: Option<Vec<Option<SubtitleTrack>>>,
    pub segments: Vec<MediaSegment>,
}

#[derive(SimpleObject)]
#[graphql(name = "CastMember")]
pub struct CastMember {
    pub name: String,
    pub character: Option<String>,
    pub profile_url: Option<String>,
}

#[derive(SimpleObject)]
#[graphql(name = "RecentlyAddedItem")]
pub struct RecentlyAddedItem {
    pub id: ID,
    #[graphql(name = "type")]
    pub media_type: MediaType,
    pub title: String,
    pub year: Option<i32>,
    pub artwork: Option<Artwork>,
    pub added_at: DateTime<Utc>,
    pub new_episode_count: Option<i32>,
    pub latest_season_number: Option<i32>,
    pub latest_episode_number: Option<i32>,
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct Movie {
    pub id: ID,
    #[graphql(skip)]
    pub parent: Option<Box<Node>>,
    #[graphql(skip)]
    pub ancestors: Option<Vec<Option<Node>>>,
    pub is_playable: bool,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i32>,
    pub tvdb_id: Option<i32>,
    pub imdb_id: Option<String>,
    pub category: Option<MediaCategory>,
    pub monitored: bool,
    pub added_at: DateTime<Utc>,
    pub overview: Option<String>,
    pub runtime: Option<i32>,
    pub genres: Option<Vec<Option<String>>>,
    pub content_rating: Option<String>,
    pub trailer_url: Option<String>,
    pub cast: Option<Vec<Option<CastMember>>>,
    pub similar: Option<Vec<Option<RecentlyAddedItem>>>,
    pub rating: Option<f64>,
    pub artwork: Option<Artwork>,
    pub files: Option<Vec<Option<MediaFile>>>,
    pub progress: Option<Progress>,
    pub is_favorite: bool,
}

#[ComplexObject]
impl Movie {
    pub async fn parent(&self) -> Option<&Node> {
        self.parent.as_deref()
    }

    pub async fn children(
        &self,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Option<&NodeConnection> {
        None
    }

    pub async fn ancestors(&self) -> Option<&Vec<Option<Node>>> {
        self.ancestors.as_ref()
    }
}

#[derive(SimpleObject)]
pub struct ShowNextUp {
    pub episode: Episode,
    pub progress_state: String,
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct TvShow {
    pub id: ID,
    #[graphql(skip)]
    pub parent: Option<Box<Node>>,
    #[graphql(skip)]
    pub ancestors: Option<Vec<Option<Node>>>,
    pub is_playable: bool,
    pub title: String,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub tmdb_id: Option<i32>,
    pub tvdb_id: Option<i32>,
    pub imdb_id: Option<String>,
    pub category: Option<MediaCategory>,
    pub monitored: bool,
    pub added_at: DateTime<Utc>,
    pub overview: Option<String>,
    pub status: Option<String>,
    pub genres: Option<Vec<Option<String>>>,
    pub content_rating: Option<String>,
    pub trailer_url: Option<String>,
    pub cast: Option<Vec<Option<CastMember>>>,
    pub similar: Option<Vec<Option<RecentlyAddedItem>>>,
    pub rating: Option<f64>,
    pub artwork: Option<Artwork>,
    pub seasons: Option<Vec<Option<Season>>>,
    pub season_count: Option<i32>,
    pub episode_count: Option<i32>,
    pub next_episode: Option<Episode>,
    pub next_up: Option<ShowNextUp>,
    pub is_favorite: bool,
    pub metadata_source: Option<String>,
}

#[ComplexObject]
impl TvShow {
    pub async fn parent(&self) -> Option<&Node> {
        self.parent.as_deref()
    }

    pub async fn children(
        &self,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Option<&NodeConnection> {
        None
    }

    pub async fn ancestors(&self) -> Option<&Vec<Option<Node>>> {
        self.ancestors.as_ref()
    }
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct Season {
    pub id: ID,
    #[graphql(skip)]
    pub parent: Option<Box<Node>>,
    #[graphql(skip)]
    pub ancestors: Option<Vec<Option<Node>>>,
    pub is_playable: bool,
    pub season_number: i32,
    pub episode_count: i32,
    pub aired_episode_count: Option<i32>,
    pub has_files: bool,
    pub episodes: Option<Vec<Option<Episode>>>,
}

#[ComplexObject]
impl Season {
    pub async fn parent(&self) -> Option<&Node> {
        self.parent.as_deref()
    }

    pub async fn children(
        &self,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Option<&NodeConnection> {
        None
    }

    pub async fn ancestors(&self) -> Option<&Vec<Option<Node>>> {
        self.ancestors.as_ref()
    }
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct Episode {
    pub id: ID,
    #[graphql(skip)]
    pub parent: Option<Box<Node>>,
    #[graphql(skip)]
    pub ancestors: Option<Vec<Option<Node>>>,
    pub is_playable: bool,
    pub season_number: i32,
    pub episode_number: i32,
    pub title: Option<String>,
    pub air_date: Option<Date>,
    pub monitored: bool,
    pub overview: Option<String>,
    pub runtime: Option<i32>,
    pub thumbnail_url: Option<String>,
    pub files: Option<Vec<Option<MediaFile>>>,
    pub progress: Option<Progress>,
    pub has_file: bool,
    pub show: Option<Box<TvShow>>,
}

#[ComplexObject]
impl Episode {
    pub async fn parent(&self) -> Option<&Node> {
        self.parent.as_deref()
    }

    pub async fn children(
        &self,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Option<&NodeConnection> {
        None
    }

    pub async fn ancestors(&self) -> Option<&Vec<Option<Node>>> {
        self.ancestors.as_ref()
    }
}

#[derive(SimpleObject)]
pub struct MovieEdge {
    pub node: Movie,
    pub cursor: String,
}

#[derive(SimpleObject)]
pub struct MovieConnection {
    pub edges: Vec<MovieEdge>,
    pub page_info: PageInfo,
    pub total_count: i32,
}

#[derive(SimpleObject)]
pub struct TvShowEdge {
    pub node: TvShow,
    pub cursor: String,
}

#[derive(SimpleObject)]
pub struct TvShowConnection {
    pub edges: Vec<TvShowEdge>,
    pub page_info: PageInfo,
    pub total_count: i32,
}

#[derive(SimpleObject)]
#[graphql(complex)]
pub struct LibraryPath {
    pub id: ID,
    #[graphql(skip)]
    pub parent: Option<Box<Node>>,
    #[graphql(skip)]
    pub ancestors: Option<Vec<Option<Node>>>,
    pub is_playable: bool,
    pub path: String,
    #[graphql(name = "type")]
    pub library_type: LibraryType,
    pub monitored: bool,
    pub scan_interval: Option<i32>,
    pub last_scan_at: Option<DateTime<Utc>>,
    pub auto_organize: bool,
    pub auto_import: bool,
    pub write_nfo: bool,
    pub auto_rename: bool,
    pub tv_metadata_source: Option<String>,
}

#[ComplexObject]
impl LibraryPath {
    pub async fn parent(&self) -> Option<&Node> {
        self.parent.as_deref()
    }

    pub async fn children(
        &self,
        _first: Option<i32>,
        _after: Option<String>,
    ) -> Option<&NodeConnection> {
        None
    }

    pub async fn ancestors(&self) -> Option<&Vec<Option<Node>>> {
        self.ancestors.as_ref()
    }
}

/// Renders just this group's types as SDL.
pub fn sdl_fragment() -> String {
    use async_graphql::{EmptyMutation, EmptySubscription, Object, Schema};

    struct FragmentQuery;

    #[Object]
    impl FragmentQuery {
        async fn movie(&self) -> Movie {
            std::future::pending().await
        }

        async fn tv_show(&self) -> TvShow {
            std::future::pending().await
        }

        async fn season(&self) -> Season {
            std::future::pending().await
        }

        async fn episode(&self) -> Episode {
            std::future::pending().await
        }

        async fn show_next_up(&self) -> ShowNextUp {
            std::future::pending().await
        }

        async fn movie_connection(&self) -> MovieConnection {
            std::future::pending().await
        }

        async fn tv_show_connection(&self) -> TvShowConnection {
            std::future::pending().await
        }

        async fn artwork(&self) -> Artwork {
            std::future::pending().await
        }

        async fn media_file(&self) -> MediaFile {
            std::future::pending().await
        }

        async fn media_segment(&self) -> MediaSegment {
            std::future::pending().await
        }

        async fn progress(&self) -> Progress {
            std::future::pending().await
        }

        async fn library_path(&self) -> LibraryPath {
            std::future::pending().await
        }

        async fn subtitle_track(&self) -> SubtitleTrack {
            std::future::pending().await
        }
    }

    Schema::build(FragmentQuery, EmptyMutation, EmptySubscription)
        .finish()
        .sdl()
}
