//! Database rows to GraphQL types.
//!
//! Two kinds of constant answer appear here. Fields that Slice 2b, 3 or 4
//! fills in are left null, which the contract allows and which lets the
//! player degrade field by field. Fields describing a capability Mydia Server
//! does not have (monitoring, organizing, renaming, writing NFO files) answer
//! false, because they are absent from the product rather than unfinished.

use std::collections::HashMap;
use std::path::Path;

use async_graphql::ID;
use chrono::{DateTime, TimeZone, Utc};
use serde::Deserialize;

use mydia_db::episodes::EpisodeRow;
use mydia_db::external_subtitles::ExternalSubtitleRow;
use mydia_db::library_paths::LibraryPathRow;
use mydia_db::media_files::MediaFileRow;
use mydia_db::media_items::MediaItemRow;

use crate::types::common::{LibraryType, MediaCategory};
use crate::types::media::{
    Artwork, Episode, LibraryPath, MediaFile, Movie, Season, SubtitleTrack, TvShow,
};

/// External subtitle rows keyed by the media file they belong to.
pub type ExternalsByFile = HashMap<String, Vec<ExternalSubtitleRow>>;

/// The stored shape of `media_files.subtitle_tracks`, written by
/// `mydia_library::ffprobe::SubtitleTrackFacts`.
///
/// Declared here rather than imported so `mydia-api` does not depend on a
/// domain crate it otherwise has no use for. The JSON column is the interface
/// between the two, and these five field names are that interface.
#[derive(Debug, Deserialize)]
struct StoredSubtitleTrack {
    track_id: String,
    language: String,
    title: String,
    format: String,
    embedded: bool,
}

/// The Elixir server encodes a season's global id as `season:<show>:<n>`
/// (lib/mydia_web/schema/resolvers/node_id.ex:24). Every other type uses its
/// raw row id.
pub fn season_node_id(show_id: &str, season_number: i64) -> String {
    format!("season:{show_id}:{season_number}")
}

fn timestamp(raw: &str) -> DateTime<Utc> {
    DateTime::parse_from_rfc3339(raw)
        .map(|value| value.with_timezone(&Utc))
        .unwrap_or_else(|_| Utc.timestamp_opt(0, 0).single().unwrap_or_else(Utc::now))
}

fn artwork(item: &MediaItemRow) -> Option<Artwork> {
    Some(Artwork {
        poster_url: item.poster_url.clone(),
        backdrop_url: item.backdrop_url.clone(),
        thumbnail_url: item.thumbnail_url.clone(),
    })
}

fn genres(item: &MediaItemRow) -> Option<Vec<Option<String>>> {
    let raw = item.genres.as_deref()?;
    let parsed: Vec<String> = serde_json::from_str(raw).ok()?;

    Some(parsed.into_iter().map(Some).collect())
}

pub fn library_path_from(row: &LibraryPathRow) -> LibraryPath {
    LibraryPath {
        id: ID(row.id.clone()),
        parent: None,
        ancestors: None,
        is_playable: false,
        path: row.path.clone(),
        library_type: match row.library_type.as_str() {
            "movies" => LibraryType::Movies,
            "series" => LibraryType::Series,
            _ => LibraryType::Mixed,
        },
        monitored: row.monitored,
        scan_interval: row.scan_interval.and_then(|v| i32::try_from(v).ok()),
        last_scan_at: row.last_scan_at.as_deref().map(timestamp),
        // Mydia Server is read-only on the library. These are absent
        // capabilities, not settings, and they answer false forever.
        auto_organize: false,
        auto_import: false,
        write_nfo: false,
        auto_rename: false,
        tv_metadata_source: None,
    }
}

/// Embedded tracks come from the scan's JSON column; external ones are read
/// from `external_subtitles` by the caller and passed in. Elixir runs ffprobe
/// per request for the embedded half (extractor.ex:46-54); this does not need
/// to, because Slice 2a already persisted it.
pub fn media_file_from(row: &MediaFileRow, external: &[ExternalSubtitleRow]) -> MediaFile {
    let mut tracks: Vec<Option<SubtitleTrack>> = row
        .subtitle_tracks
        .as_deref()
        .map(|raw| {
            // A malformed column yields an empty list rather than an error:
            // the file is still browsable, it just has no subtitle tracks.
            serde_json::from_str::<Vec<StoredSubtitleTrack>>(raw)
                .unwrap_or_default()
                .into_iter()
                .map(|track| {
                    Some(SubtitleTrack {
                        track_id: track.track_id,
                        language: track.language,
                        title: track.title,
                        format: track.format,
                        embedded: track.embedded,
                        media_file_id: row.id.clone(),
                    })
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();

    let external_tracks = || -> Vec<Option<SubtitleTrack>> {
        external
            .iter()
            .map(|sub| {
                Some(SubtitleTrack {
                    track_id: sub.id.clone(),
                    language: sub.language.clone(),
                    title: external_title(&sub.language),
                    format: sub.format.clone(),
                    embedded: false,
                    media_file_id: row.id.clone(),
                })
            })
            .collect()
    };

    // Embedded first, then external, matching extractor.ex:59.
    tracks.extend(external_tracks());

    MediaFile {
        id: ID(row.id.clone()),
        resolution: row.resolution.clone(),
        codec: row.codec.clone(),
        audio_codec: row.audio_codec.clone(),
        hdr_format: row.hdr_format.clone(),
        file_name: Path::new(&row.path)
            .file_name()
            .map(|name| name.to_string_lossy().into_owned()),
        directory: Path::new(&row.path)
            .parent()
            .map(|dir| dir.to_string_lossy().into_owned()),
        container: row.container.clone(),
        duration: row.duration_seconds,
        // Null, not empty: the contract distinguishes "capture has not run"
        // from "ran and found nothing", and this scanner does not persist
        // per-stream detail yet. The player renders null as "not captured
        // yet" and degrades cleanly, the same way `segments` does below.
        streams: None,
        external_subtitles: Some(external_tracks()),
        size: row.size,
        bitrate: row.bitrate.and_then(|v| i32::try_from(v).ok()),
        // Elixir hardcodes true behind a "TODO: Implement based on client
        // capabilities" (common_types.ex:25-31). Mirrored deliberately: a
        // computed answer would diverge on a field the conformance suite
        // compares, and would risk the player refusing files it handles fine.
        direct_play_supported: Some(true),
        stream_url: Some(format!("/api/v1/stream/file/{}", row.id)),
        direct_play_url: Some(format!(
            "/api/v1/stream/file/{}?strategy=DIRECT_PLAY",
            row.id
        )),
        subtitles: Some(tracks),
        // Slice 8.
        segments: Vec::new(),
    }
}

fn files_of(files: &[MediaFileRow], externals: &ExternalsByFile) -> Option<Vec<Option<MediaFile>>> {
    Some(
        files
            .iter()
            .map(|f| {
                let external = externals.get(&f.id).map(Vec::as_slice).unwrap_or(&[]);
                Some(media_file_from(f, external))
            })
            .collect(),
    )
}

/// extractor.ex:203-207.
fn external_title(language: &str) -> String {
    format!("{} (External)", language_name(language))
}

/// extractor.ex:210-233. Duplicated from mydia-library rather than depended
/// on: this is contract text, and mydia-api should not pull in a scanning
/// crate for one match statement.
fn language_name(code: &str) -> String {
    match code {
        "eng" | "en" => "English",
        "spa" | "es" => "Spanish",
        "fra" | "fr" => "French",
        "deu" | "de" => "German",
        "ita" | "it" => "Italian",
        "por" | "pt" => "Portuguese",
        "jpn" | "ja" => "Japanese",
        "kor" | "ko" => "Korean",
        "chi" | "zh" => "Chinese",
        "rus" | "ru" => "Russian",
        "ara" | "ar" => "Arabic",
        "und" => "Unknown",
        other => return other.to_uppercase(),
    }
    .to_string()
}

pub fn movie_from(
    item: &MediaItemRow,
    files: &[MediaFileRow],
    externals: &ExternalsByFile,
) -> Movie {
    Movie {
        id: ID(item.id.clone()),
        parent: None,
        ancestors: None,
        is_playable: !files.is_empty(),
        title: item.title.clone(),
        original_title: item.original_title.clone(),
        year: item.year.and_then(|v| i32::try_from(v).ok()),
        tmdb_id: item.tmdb_id.and_then(|v| i32::try_from(v).ok()),
        tvdb_id: item.tvdb_id.and_then(|v| i32::try_from(v).ok()),
        imdb_id: item.imdb_id.clone(),
        category: Some(MediaCategory::Movie),
        // There is no monitoring in this product.
        monitored: false,
        added_at: timestamp(&item.added_at),
        overview: item.overview.clone(),
        runtime: item.runtime.and_then(|v| i32::try_from(v).ok()),
        genres: genres(item),
        content_rating: item.content_rating.clone(),
        trailer_url: None,
        cast: None,
        similar: None,
        rating: item.rating,
        artwork: artwork(item),
        files: files_of(files, externals),
        // Progress and favorites land in Slice 4.
        progress: None,
        watch_status: None,
        is_favorite: false,
    }
}

pub fn episode_from(
    row: &EpisodeRow,
    files: &[MediaFileRow],
    show: Option<Box<TvShow>>,
    externals: &ExternalsByFile,
) -> Episode {
    Episode {
        id: ID(row.id.clone()),
        parent: None,
        ancestors: None,
        is_playable: !files.is_empty(),
        season_number: i32::try_from(row.season_number).unwrap_or(0),
        episode_number: i32::try_from(row.episode_number).unwrap_or(0),
        title: row.title.clone(),
        air_date: None,
        monitored: false,
        overview: row.overview.clone(),
        runtime: row.runtime.and_then(|v| i32::try_from(v).ok()),
        thumbnail_url: row.thumbnail_url.clone(),
        files: files_of(files, externals),
        progress: None,
        watch_status: None,
        has_file: !files.is_empty(),
        show,
    }
}

pub fn tv_show_from(
    item: &MediaItemRow,
    episodes: &[(EpisodeRow, Vec<MediaFileRow>)],
    externals: &ExternalsByFile,
) -> TvShow {
    let mut season_numbers: Vec<i64> = episodes.iter().map(|(e, _)| e.season_number).collect();
    season_numbers.sort_unstable();
    season_numbers.dedup();

    let seasons: Vec<Option<Season>> = season_numbers
        .iter()
        .map(|number| {
            let in_season: Vec<&(EpisodeRow, Vec<MediaFileRow>)> = episodes
                .iter()
                .filter(|(e, _)| e.season_number == *number)
                .collect();

            let count = i32::try_from(in_season.len()).unwrap_or(i32::MAX);

            Some(Season {
                id: ID(season_node_id(&item.id, *number)),
                parent: None,
                ancestors: None,
                is_playable: in_season.iter().any(|(_, files)| !files.is_empty()),
                season_number: i32::try_from(*number).unwrap_or(0),
                episode_count: count,
                aired_episode_count: Some(count),
                has_files: in_season.iter().any(|(_, files)| !files.is_empty()),
                watch_status: None,
                episodes: Some(
                    in_season
                        .iter()
                        .map(|(row, files)| Some(episode_from(row, files, None, externals)))
                        .collect(),
                ),
            })
        })
        .collect();

    // Season 0 is specials, which the player does not count as a season.
    let numbered_seasons = season_numbers.iter().filter(|n| **n > 0).count();

    let next = episodes
        .iter()
        .min_by_key(|(e, _)| (e.season_number, e.episode_number))
        .map(|(row, files)| episode_from(row, files, None, externals));

    TvShow {
        id: ID(item.id.clone()),
        parent: None,
        ancestors: None,
        is_playable: episodes.iter().any(|(_, files)| !files.is_empty()),
        title: item.title.clone(),
        original_title: item.original_title.clone(),
        year: item.year.and_then(|v| i32::try_from(v).ok()),
        tmdb_id: item.tmdb_id.and_then(|v| i32::try_from(v).ok()),
        tvdb_id: item.tvdb_id.and_then(|v| i32::try_from(v).ok()),
        imdb_id: item.imdb_id.clone(),
        category: Some(MediaCategory::TvShow),
        monitored: false,
        added_at: timestamp(&item.added_at),
        overview: item.overview.clone(),
        status: item.status.clone(),
        genres: genres(item),
        content_rating: item.content_rating.clone(),
        trailer_url: None,
        cast: None,
        similar: None,
        rating: item.rating,
        artwork: artwork(item),
        seasons: Some(seasons),
        season_count: Some(i32::try_from(numbered_seasons).unwrap_or(i32::MAX)),
        episode_count: Some(i32::try_from(episodes.len()).unwrap_or(i32::MAX)),
        watch_status: None,
        next_episode: next,
        // next_up needs watch state, which is Slice 4.
        next_up: None,
        is_favorite: false,
        metadata_source: item.metadata_source.clone(),
    }
}
