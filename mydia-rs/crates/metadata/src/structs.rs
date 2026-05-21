//! Response struct shapes returned by [`crate::Provider`] adapters.
//!
//! These mirror `lib/mydia/metadata/structs/*.ex` field-for-field. Field
//! names stay `snake_case` so JSON serialization round-trips the Phoenix
//! shape (Ecto schemas + Jason emit `snake_case` by default). Atom-valued
//! Elixir fields (`:movie | :tv_show | :book`, `:tmdb | :tvdb`, ...)
//! become Rust enums with `#[serde(rename_all = "snake_case")]` so the
//! wire format matches `Atom.to_string/1`.
//!
//! These structs are pure data — the `from_api_response`-style parsing
//! helpers live next to the relay clients in [`crate::relay`] and
//! [`crate::open_library`].

use chrono::{DateTime, NaiveDate, Utc};
use serde::{Deserialize, Serialize};

/// Mirrors Elixir `:movie | :tv_show | :book`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MediaType {
    Movie,
    TvShow,
    Book,
}

/// Mirrors Elixir `:tmdb | :tvdb | :metadata_relay | :open_library |
/// :music_relay`. Adapters set this on each emitted struct so the
/// caller can attribute the source without consulting the registry.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Tmdb,
    Tvdb,
    MetadataRelay,
    OpenLibrary,
    MusicRelay,
}

/// Search-result row returned by [`crate::Provider::search`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub provider_id: String,
    pub provider: ProviderKind,
    pub media_type: MediaType,

    pub title: Option<String>,
    pub name: Option<String>,
    pub original_title: Option<String>,
    pub original_name: Option<String>,
    pub year: Option<i32>,
    /// String form; provider responses sometimes ship partial dates
    /// (`"2024"`, `"2024-12"`) that don't parse into `NaiveDate`.
    pub release_date: Option<String>,
    pub first_air_date: Option<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub id: Option<i64>,
    pub imdb_id: Option<String>,
    pub overview: Option<String>,
    pub popularity: Option<f64>,
    pub vote_average: Option<f64>,
    pub vote_count: Option<i64>,
}

/// Cast credit — one entry per actor on the production.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CastMember {
    pub name: String,
    pub character: Option<String>,
    pub order: Option<i32>,
    pub profile_path: Option<String>,
}

/// Crew credit — one entry per non-acting role (director, writer, ...).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct CrewMember {
    pub name: String,
    pub job: String,
    pub department: Option<String>,
    pub profile_path: Option<String>,
}

/// Trailer / teaser / featurette entry.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Video {
    pub id: Option<String>,
    pub key: String,
    pub name: Option<String>,
    pub site: String,
    pub r#type: Option<String>,
    pub official: Option<bool>,
    pub published_at: Option<DateTime<Utc>>,
}

impl Video {
    /// `YouTube`-only embed URL helper. Returns `None` for non-`YouTube` sites.
    #[must_use]
    pub fn youtube_embed_url(&self) -> Option<String> {
        if self.site == "YouTube" && !self.key.is_empty() {
            Some(format!("https://www.youtube.com/embed/{}", self.key))
        } else {
            None
        }
    }
}

/// Single image with sizing and rating metadata.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImageData {
    pub file_path: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub aspect_ratio: Option<f64>,
    pub vote_average: Option<f64>,
    pub vote_count: Option<u32>,
}

impl ImageData {
    /// Build a full URL by joining `base_url` and `file_path`.
    /// Returns `None` if `file_path` is missing or empty. If
    /// `file_path` already starts with `http`, it is returned verbatim.
    #[must_use]
    pub fn full_url(&self, base_url: &str) -> Option<String> {
        match self.file_path.as_deref() {
            None | Some("") => None,
            Some(path) if path.starts_with("http") => Some(path.to_string()),
            Some(path) => {
                let base = base_url.trim_end_matches('/');
                let suffix = if path.starts_with('/') {
                    path.to_string()
                } else {
                    format!("/{path}")
                };
                Some(format!("{base}{suffix}"))
            }
        }
    }
}

/// Aggregated images returned by [`crate::Provider::fetch_images`].
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct ImagesResponse {
    pub posters: Vec<ImageData>,
    pub backdrops: Vec<ImageData>,
    pub logos: Vec<ImageData>,
}

/// Lightweight season summary embedded in [`MediaMetadata::seasons`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeasonInfo {
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    /// String form to match the Elixir field type — TMDB returns
    /// partial dates in this position sometimes.
    pub air_date: Option<String>,
    pub episode_count: Option<i32>,
    pub poster_path: Option<String>,
    pub tvdb_season_id: Option<i64>,
}

/// Full episode metadata.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EpisodeData {
    pub season_number: i32,
    pub episode_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub runtime: Option<i32>,
    pub still_path: Option<String>,
    pub vote_average: Option<f64>,
    pub vote_count: Option<i64>,
}

/// Season payload returned by [`crate::Provider::fetch_season`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SeasonData {
    pub season_number: i32,
    pub name: Option<String>,
    pub overview: Option<String>,
    pub air_date: Option<NaiveDate>,
    pub poster_path: Option<String>,
    pub episode_count: Option<i32>,
    pub episodes: Vec<EpisodeData>,
}

/// Full media metadata returned by [`crate::Provider::fetch_by_id`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MediaMetadata {
    pub provider_id: String,
    pub provider: ProviderKind,
    pub media_type: MediaType,

    pub id: Option<i64>,
    pub title: Option<String>,
    pub original_title: Option<String>,
    pub year: Option<i32>,
    pub release_date: Option<NaiveDate>,
    pub overview: Option<String>,
    pub tagline: Option<String>,
    pub runtime: Option<i32>,
    pub status: Option<String>,
    pub genres: Vec<String>,
    pub poster_path: Option<String>,
    pub backdrop_path: Option<String>,
    pub popularity: Option<f64>,
    pub vote_average: Option<f64>,
    pub vote_count: Option<i64>,
    pub imdb_id: Option<String>,
    pub production_companies: Vec<String>,
    pub production_countries: Vec<String>,
    pub spoken_languages: Vec<String>,
    pub homepage: Option<String>,
    pub cast: Vec<CastMember>,
    pub crew: Vec<CrewMember>,
    pub alternative_titles: Vec<String>,
    pub videos: Vec<Video>,
    pub origin_country: Vec<String>,
    pub original_language: Option<String>,

    pub number_of_seasons: Option<i32>,
    pub number_of_episodes: Option<i32>,
    pub episode_run_time: Vec<i32>,
    pub first_air_date: Option<NaiveDate>,
    pub last_air_date: Option<NaiveDate>,
    pub in_production: Option<bool>,
    pub seasons: Vec<SeasonInfo>,
}

/// Book metadata returned by [`crate::open_library::OpenLibrary`].
///
/// Note: Books do not carry `media_type` because the type is implicit —
/// the Elixir struct deliberately omits it. Callers branch on the
/// struct variant rather than a runtime discriminant.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BookMetadata {
    pub provider_id: String,
    pub provider: ProviderKind,
    pub title: Option<String>,
    pub subtitle: Option<String>,
    pub authors: Vec<String>,
    pub isbn_10: Option<String>,
    pub isbn_13: Option<String>,
    pub publish_date: Option<String>,
    pub publisher: Option<String>,
    pub number_of_pages: Option<i32>,
    pub description: Option<String>,
    pub cover_url: Option<String>,
    pub genres: Vec<String>,
    pub series_name: Option<String>,
    pub series_position: Option<f64>,
    pub language: Option<String>,
    /// Free-form additional identifiers (Goodreads, LCCN, ...). Carried
    /// as JSON because the upstream Open Library schema is sparse.
    pub identifiers: Option<serde_json::Value>,
}

/// Connection probe response. The Elixir behaviour returns a free-form
/// `map()` here; in Rust this is a fixed two-field struct because the
/// only call sites read these two keys.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionInfo {
    pub status: String,
    pub provider: String,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn media_type_serializes_as_snake_case_atom() {
        let json = serde_json::to_string(&MediaType::TvShow).unwrap();
        assert_eq!(json, "\"tv_show\"");
    }

    #[test]
    fn provider_kind_serializes_as_snake_case_atom() {
        let json = serde_json::to_string(&ProviderKind::MetadataRelay).unwrap();
        assert_eq!(json, "\"metadata_relay\"");
    }

    #[test]
    fn image_full_url_handles_relative_and_absolute() {
        let img = ImageData {
            file_path: Some("/poster.jpg".into()),
            ..Default::default()
        };
        assert_eq!(
            img.full_url("https://image.tmdb.org/t/p/w500"),
            Some("https://image.tmdb.org/t/p/w500/poster.jpg".into())
        );

        let absolute = ImageData {
            file_path: Some("https://cdn.example.com/x.jpg".into()),
            ..Default::default()
        };
        assert_eq!(
            absolute.full_url("https://image.tmdb.org/t/p/w500"),
            Some("https://cdn.example.com/x.jpg".into())
        );

        let empty = ImageData::default();
        assert_eq!(empty.full_url("https://x.example"), None);
    }

    #[test]
    fn video_embed_url_only_for_youtube() {
        let yt = Video {
            id: None,
            key: "abc".into(),
            name: None,
            site: "YouTube".into(),
            r#type: None,
            official: None,
            published_at: None,
        };
        assert_eq!(
            yt.youtube_embed_url(),
            Some("https://www.youtube.com/embed/abc".into())
        );

        let vimeo = Video {
            site: "Vimeo".into(),
            ..yt
        };
        assert!(vimeo.youtube_embed_url().is_none());
    }
}
