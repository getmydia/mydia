//! Port of lib/mydia/library/file_ranking.ex.
//!
//! Used wherever a caller names a movie or an episode rather than a specific
//! file. Ranking is deliberately device-blind: it always prefers the highest
//! quality file, because the server cannot know what the requesting client
//! can handle. A client that cares sends an explicit file id, which skips
//! this entirely.

use mydia_db::media_files::MediaFileRow;

/// Keys are lowercased; values are vertical pixels. file_ranking.ex:23-40.
const NAMED: &[(&str, u32)] = &[
    ("8k", 4320),
    ("4320p", 4320),
    ("4k", 2160),
    ("uhd", 2160),
    ("2160p", 2160),
    ("2k", 1440),
    ("qhd", 1440),
    ("1440p", 1440),
    ("fhd", 1080),
    ("1080p", 1080),
    ("hd", 720),
    ("720p", 720),
    ("576p", 576),
    ("540p", 540),
    ("sd", 480),
    ("480p", 480),
    ("360p", 360),
];

/// Returns 0 for None and for anything unparseable, which sorts those files
/// last. file_ranking.ex:58-66.
pub fn resolution_pixels(resolution: Option<&str>) -> u32 {
    let Some(resolution) = resolution else {
        return 0;
    };
    let key = resolution.trim().to_lowercase();

    if let Some((_, pixels)) = NAMED.iter().find(|(name, _)| *name == key) {
        return *pixels;
    }

    parse_trailing_number(&key)
}

/// Port of the `(\d+)[pi]?$` fallback (file_ranking.ex:46). Deliberately
/// unanchored at the start, so "1920x1080" answers 1080.
fn parse_trailing_number(key: &str) -> u32 {
    let digits: String = key
        .trim_end_matches(['p', 'i'])
        .chars()
        .rev()
        .take_while(char::is_ascii_digit)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect();

    digits.parse().unwrap_or(0)
}

/// The highest-quality file, or None when `files` is empty. Callers use the
/// None to detect "this item has no playable files".
///
/// Resolution descending, then bitrate descending, then id descending.
/// file_ranking.ex:78-95.
pub fn best(files: &[MediaFileRow]) -> Option<&MediaFileRow> {
    files.iter().max_by(|a, b| {
        let key = |f: &MediaFileRow| {
            (
                resolution_pixels(f.resolution.as_deref()),
                f.bitrate.unwrap_or(0),
                f.id.clone(),
            )
        };
        key(a).cmp(&key(b))
    })
}

#[cfg(test)]
mod tests {
    use super::{best, resolution_pixels};
    use mydia_db::media_files::MediaFileRow;

    fn row(id: &str, resolution: Option<&str>, bitrate: Option<i64>) -> MediaFileRow {
        MediaFileRow {
            id: id.to_string(),
            media_item_id: Some("item-1".to_string()),
            episode_id: None,
            path: format!("/media/{id}.mkv"),
            size: None,
            resolution: resolution.map(str::to_string),
            codec: None,
            audio_codec: None,
            hdr_format: None,
            bitrate,
            duration_seconds: None,
            container: None,
            width: None,
            height: None,
            subtitle_tracks: None,
            mtime: "2026-01-01T00:00:00Z".to_string(),
            scanned_at: "2026-01-01T00:00:00Z".to_string(),
        }
    }

    #[test]
    fn named_resolutions_map_to_pixel_heights() {
        assert_eq!(resolution_pixels(Some("4K")), 2160);
        assert_eq!(resolution_pixels(Some("2160p")), 2160);
        assert_eq!(resolution_pixels(Some("uhd")), 2160);
        assert_eq!(resolution_pixels(Some("1080p")), 1080);
        assert_eq!(resolution_pixels(Some("hd")), 720);
        assert_eq!(resolution_pixels(Some("8K")), 4320);
    }

    #[test]
    fn odd_spellings_fall_back_to_a_trailing_number() {
        // file_ranking.ex:46. Unanchored at the start on purpose.
        assert_eq!(resolution_pixels(Some("1920x1080")), 1080);
        assert_eq!(resolution_pixels(Some("1080i")), 1080);
        assert_eq!(resolution_pixels(Some("576p")), 576);
    }

    #[test]
    fn an_unknown_or_missing_resolution_sorts_last() {
        // An unanalyzed file is the least safe thing to pick blindly.
        assert_eq!(resolution_pixels(None), 0);
        assert_eq!(resolution_pixels(Some("who knows")), 0);
    }

    #[test]
    fn the_best_file_is_the_highest_resolution() {
        let files = vec![row("a", Some("720p"), None), row("b", Some("1080p"), None)];
        assert_eq!(best(&files).unwrap().id, "b");
    }

    #[test]
    fn bitrate_breaks_a_resolution_tie() {
        let files = vec![
            row("a", Some("1080p"), Some(4_000_000)),
            row("b", Some("1080p"), Some(9_000_000)),
        ];
        assert_eq!(best(&files).unwrap().id, "b");
    }

    #[test]
    fn the_id_breaks_a_total_tie_so_the_answer_is_stable() {
        // file_ranking.ex:86-88: id descending, an arbitrary but stable
        // tiebreak. Same set, same answer, whatever order the rows arrived in.
        let forwards = vec![
            row("a", Some("1080p"), Some(1)),
            row("b", Some("1080p"), Some(1)),
        ];
        let backwards = vec![
            row("b", Some("1080p"), Some(1)),
            row("a", Some("1080p"), Some(1)),
        ];
        assert_eq!(best(&forwards).unwrap().id, "b");
        assert_eq!(best(&backwards).unwrap().id, "b");
    }

    #[test]
    fn an_empty_set_has_no_best_file() {
        assert!(best(&[]).is_none());
    }
}
