//! Media-shaped types.
//!
//! The 18 types owned by this module (keep in sync with
//! tests/types_media.rs): Movie, TvShow, Season, Episode, ShowNextUp,
//! MovieEdge, MovieConnection, TvShowEdge, TvShowConnection, Artwork,
//! CastMember, MediaFile, MediaStream, MediaSegment, Progress, LibraryPath,
//! RecentlyAddedItem, SubtitleTrack, SubtitleCandidate, SubtitleProviderStatus,
//! SubtitleSearchPayload, SubtitleTrackSetting.

use async_graphql::{
    ComplexObject, InputValueError, InputValueResult, Scalar, ScalarType, SimpleObject, Value, ID,
};
use chrono::{DateTime, NaiveDate, Utc};

use crate::types::common::{
    LibraryType, MediaCategory, MediaStreamType, MediaType, Node, NodeConnection, PageInfo,
    SegmentType, SubtitleFormat,
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

/// Rolled-up watch state for a browsable item.
///
/// This server does not compute playback state yet, so every construction
/// site sets `watch_status: None`, exactly as it already does for `progress`.
/// The type exists to satisfy the structural contract in `sdl_parity.rs`:
/// GraphQL rejects a whole document when it names an unknown field, so a
/// missing field here breaks every player query that asks for it.
#[derive(SimpleObject)]
pub struct WatchStatus {
    pub watched: bool,
    pub percentage: Option<f64>,
    pub unwatched_episode_count: Option<i32>,
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
    /// The file this track belongs to. Not part of the contract; the URL
    /// resolver needs it. The Elixir resolver does the same thing by stuffing
    /// `_media_file_id` onto the track map (subtitle_resolver.ex:31).
    #[graphql(skip)]
    pub media_file_id: String,
}

#[ComplexObject]
impl SubtitleTrack {
    /// common_types.ex:394-406. Note the prefix: subtitles live under
    /// /api/player/v1, not the /api/v1 the stream URLs use.
    ///
    /// Every SubtitleFormat variant is matched: Elixir's Atom.to_string/1
    /// lowercases the enum atom into the query value, including ssa/pgs/
    /// vobsub/unknown which the plan's three-arm match omitted.
    async fn url(&self, format: Option<SubtitleFormat>) -> Option<String> {
        let format = match format.unwrap_or(SubtitleFormat::Vtt) {
            SubtitleFormat::Srt => "srt",
            SubtitleFormat::Vtt => "vtt",
            SubtitleFormat::Ass => "ass",
            SubtitleFormat::Ssa => "ssa",
            SubtitleFormat::Pgs => "pgs",
            SubtitleFormat::Vobsub => "vobsub",
            SubtitleFormat::Unknown => "unknown",
        };

        Some(format!(
            "/api/player/v1/subtitles/file/{}/{}?format={}",
            self.media_file_id, self.track_id, format
        ))
    }

    /// common_types.ex:496-500. Image-based tracks carry bitmaps, so there is
    /// no text to hand a client. Same rule as
    /// `Mydia.Subtitles.Format.image_format?/1`.
    async fn deliverable(&self) -> bool {
        !matches!(
            self.format.as_str(),
            "pgs" | "vobsub" | "dvd_subtitle" | "hdmv_pgs_subtitle"
        )
    }

    /// common_types.ex:502-506. Present for contract parity; this server does
    /// not yet convert or extract subtitle bodies, and answers null rather than
    /// guessing. Clients that need the body here use `url` above, which this
    /// server does serve. Returning null is a valid contract response: the
    /// Elixir field is nullable precisely because an undeliverable track has no
    /// body to give.
    async fn content(&self, _format: Option<SubtitleFormat>) -> Option<String> {
        None
    }
}

/// One subtitle a provider is offering, before it has been downloaded.
///
/// common_types.ex:`:subtitle_candidate`. Acquisition is not this server's
/// job (it grabs no media), so nothing here is ever constructed. The type
/// exists because the player talks to both servers and GraphQL rejects an
/// entire query containing an unknown field, so the shape has to match even
/// where the behaviour does not.
#[derive(SimpleObject)]
pub struct SubtitleCandidate {
    pub token: String,
    pub language: String,
    pub release_name: Option<String>,
    pub format: String,
    pub rating: Option<f64>,
    pub download_count: Option<i32>,
    pub hearing_impaired: bool,
    pub hash_match: bool,
    pub score: i32,
    pub provider_name: String,
}

/// What one provider had to say about a search.
///
/// common_types.ex:`:subtitle_provider_status`.
#[derive(SimpleObject)]
pub struct SubtitleProviderStatus {
    pub name: String,
    pub quota_remaining: Option<i32>,
    pub quota_total: Option<i32>,
    pub error: Option<String>,
}

/// Results of a subtitle search across every enabled provider.
///
/// common_types.ex:`:subtitle_search_payload`.
#[derive(SimpleObject)]
pub struct SubtitleSearchPayload {
    pub results: Vec<SubtitleCandidate>,
    pub providers: Vec<SubtitleProviderStatus>,
}

/// A stored timing correction for one subtitle track.
///
/// common_types.ex:`:subtitle_track_setting`. This server stores no subtitle
/// corrections, so `subtitleTrackSettings` always answers an empty list, which
/// is indistinguishable from "nothing has been corrected" and needs no special
/// handling on the client.
#[derive(SimpleObject)]
pub struct SubtitleTrackSetting {
    pub track_ref: String,
    pub offset_ms: i32,
}

/// One elementary stream of a media file, as reported by ffprobe.
///
/// Values are raw. Composing display strings ("HEVC Main 10", "7.1 (8 ch)") is
/// the client's job, which keeps this type a straight mirror of the contract.
///
/// The disposition fields are `isDefault` / `isForced` rather than `default` /
/// `forced`: `default` is a reserved word in Dart, and these names reach the
/// Flutter player verbatim through GraphQL codegen.
#[derive(SimpleObject)]
pub struct MediaStream {
    pub index: Option<i32>,
    #[graphql(name = "type")]
    pub stream_type: MediaStreamType,
    pub codec: Option<String>,
    pub codec_long: Option<String>,
    pub profile: Option<String>,
    pub level: Option<i32>,
    pub language: Option<String>,
    pub title: Option<String>,
    pub bitrate: Option<i32>,
    pub is_default: Option<bool>,
    pub is_forced: Option<bool>,
    pub is_hearing_impaired: Option<bool>,
    pub is_commentary: Option<bool>,
    pub width: Option<i32>,
    pub height: Option<i32>,
    pub frame_rate: Option<f64>,
    pub pixel_format: Option<String>,
    pub bit_depth: Option<i32>,
    pub color_space: Option<String>,
    pub color_transfer: Option<String>,
    pub color_primaries: Option<String>,
    pub dolby_vision_profile: Option<i32>,
    pub aspect_ratio: Option<String>,
    pub channels: Option<i32>,
    pub channel_layout: Option<String>,
    pub sample_rate: Option<i32>,
}

#[derive(SimpleObject)]
pub struct MediaFile {
    pub id: ID,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    /// Dolby Vision profile (5, 7, 8) if present.
    pub dolby_vision_profile: Option<i32>,
    /// DV base-layer compatibility id: 1 = HDR10 base, 4 = HLG base, 0 = none.
    pub dolby_vision_bl_compat_id: Option<i32>,
    pub file_name: Option<String>,
    pub directory: Option<String>,
    pub container: Option<String>,
    pub duration: Option<f64>,
    /// Null means detailed per-stream capture has not run for this file, which
    /// is what the player's Media Info panel renders as "not captured yet".
    pub streams: Option<Vec<Option<MediaStream>>>,
    /// Sidecar subtitle files only. `subtitles` carries these too, after the
    /// embedded tracks; this field lets a client ask for just the external ones
    /// without the embedded half.
    pub external_subtitles: Option<Vec<Option<SubtitleTrack>>>,
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
    pub watch_status: Option<WatchStatus>,
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
    pub watch_status: Option<WatchStatus>,
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
    pub watch_status: Option<WatchStatus>,
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
    pub watch_status: Option<WatchStatus>,
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
    pub watch_status: Option<WatchStatus>,
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
