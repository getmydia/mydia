use mydia_api::mapping::{
    media_file_from, movie_from, season_node_id, tv_show_from, ExternalsByFile,
};
use mydia_db::episodes::EpisodeRow;
use mydia_db::media_files::MediaFileRow;
use mydia_db::media_items::MediaItemRow;

fn no_externals() -> ExternalsByFile {
    ExternalsByFile::new()
}

fn item(media_type: &str, title: &str) -> MediaItemRow {
    MediaItemRow {
        id: "item-1".to_string(),
        library_path_id: "lp-1".to_string(),
        media_type: media_type.to_string(),
        title: title.to_string(),
        identity_key: title.to_lowercase(),
        original_title: None,
        year: Some(1999),
        tmdb_id: None,
        tvdb_id: None,
        imdb_id: None,
        overview: None,
        runtime: None,
        content_rating: None,
        rating: None,
        status: None,
        genres: None,
        poster_url: None,
        backdrop_url: None,
        thumbnail_url: None,
        metadata_source: None,
        added_at: "2026-01-02T03:04:05Z".to_string(),
        updated_at: "2026-01-02T03:04:05Z".to_string(),
    }
}

fn file(size: i64) -> MediaFileRow {
    MediaFileRow {
        id: "file-1".to_string(),
        media_item_id: Some("item-1".to_string()),
        episode_id: None,
        path: "/media/a.mkv".to_string(),
        size: Some(size),
        resolution: Some("2160p".to_string()),
        codec: Some("HEVC (Main 10)".to_string()),
        audio_codec: Some("TrueHD 7.1".to_string()),
        hdr_format: Some("Dolby Vision".to_string()),
        bitrate: Some(48_000_000),
        duration_seconds: Some(7200.0),
        container: Some("matroska,webm".to_string()),
        width: Some(3840),
        height: Some(2160),
        subtitle_tracks: Some(
            r#"[{"track_id":"2","language":"eng","title":"English","format":"subrip","embedded":true}]"#
                .to_string(),
        ),
        mtime: "2026-01-01T00:00:00Z".to_string(),
        scanned_at: "2026-01-02T00:00:00Z".to_string(),
    }
}

fn episode(season: i64, number: i64) -> EpisodeRow {
    EpisodeRow {
        id: format!("ep-{season}-{number}"),
        show_id: "item-1".to_string(),
        season_number: season,
        episode_number: number,
        title: None,
        overview: None,
        air_date: None,
        runtime: None,
        thumbnail_url: None,
        added_at: "2026-01-02T03:04:05Z".to_string(),
        updated_at: "2026-01-02T03:04:05Z".to_string(),
    }
}

#[test]
fn a_multi_gigabyte_size_survives_mapping() {
    let mapped = media_file_from(&file(8_000_000_000), &[]);

    assert_eq!(mapped.size, Some(8_000_000_000));
}

#[test]
fn embedded_subtitle_tracks_are_decoded() {
    let mapped = media_file_from(&file(1), &[]);
    let tracks = mapped.subtitles.expect("tracks");

    assert_eq!(tracks.len(), 1);
    let track = tracks[0].as_ref().expect("track");
    assert_eq!(track.language, "eng");
    assert!(track.embedded);
}

#[test]
fn malformed_subtitle_json_becomes_an_empty_list_not_a_panic() {
    let mut row = file(1);
    row.subtitle_tracks = Some("{not json".to_string());

    let mapped = media_file_from(&row, &[]);

    assert_eq!(mapped.subtitles.map(|t| t.len()), Some(0));
}

#[test]
fn playback_fields_are_relative_urls_keyed_on_the_file_id() {
    let mapped = media_file_from(&file(1), &[]);

    assert_eq!(mapped.direct_play_supported, Some(true));
    assert_eq!(
        mapped.stream_url.as_deref(),
        Some("/api/v1/stream/file/file-1")
    );
    assert_eq!(
        mapped.direct_play_url.as_deref(),
        Some("/api/v1/stream/file/file-1?strategy=DIRECT_PLAY")
    );
}

#[test]
fn a_movie_with_a_file_is_playable() {
    let mapped = movie_from(&item("movie", "The Matrix"), &[file(1)], &no_externals());

    assert!(mapped.is_playable);
    assert_eq!(mapped.title, "The Matrix");
    assert_eq!(mapped.year, Some(1999));
    assert_eq!(mapped.files.map(|f| f.len()), Some(1));
}

#[test]
fn a_movie_without_files_is_not_playable() {
    let mapped = movie_from(&item("movie", "The Matrix"), &[], &no_externals());

    assert!(!mapped.is_playable);
}

#[test]
fn capabilities_this_product_does_not_have_are_false() {
    let mapped = movie_from(&item("movie", "The Matrix"), &[file(1)], &no_externals());

    // There is no monitoring in Mydia Server. The field exists because the
    // contract has it, and it answers false rather than null.
    assert!(!mapped.monitored);
}

#[test]
fn a_show_counts_its_seasons_and_episodes() {
    let episodes = vec![
        (episode(1, 1), vec![file(1)]),
        (episode(1, 2), vec![file(1)]),
        (episode(2, 1), vec![file(1)]),
        (episode(0, 1), vec![file(1)]),
    ];

    let mapped = tv_show_from(&item("tv_show", "Show Name"), &episodes, &no_externals());

    // Season 0 is specials and does not count toward seasonCount, matching
    // how the player labels a show.
    assert_eq!(mapped.season_count, Some(2));
    assert_eq!(mapped.episode_count, Some(4));
    assert_eq!(mapped.seasons.map(|s| s.len()), Some(3));
}

#[test]
fn a_show_next_episode_is_its_lowest_numbered_one() {
    let episodes = vec![
        (episode(2, 1), vec![file(1)]),
        (episode(1, 2), vec![file(1)]),
        (episode(1, 1), vec![file(1)]),
    ];

    let mapped = tv_show_from(&item("tv_show", "Show Name"), &episodes, &no_externals());
    let next = mapped.next_episode.expect("next episode");

    assert_eq!((next.season_number, next.episode_number), (1, 1));
}

#[test]
fn season_node_ids_match_the_elixir_encoding() {
    assert_eq!(season_node_id("abc", 2), "season:abc:2");
}
