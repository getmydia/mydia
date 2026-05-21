//! Group matched media files hierarchically for the import workflow
//! UI — TV shows by series and season, movies in a flat list,
//! unmatched files separately.
//!
//! Port of `lib/mydia/library/file_grouper.ex`.

use serde::{Deserialize, Serialize};

use crate::release_parser::{MediaKind, ParsedFileInfo};
use crate::scanner::ScanFile;

/// Input row to [`FileGrouper::group`]. Each row pairs a scanned
/// file with its parser output and a provisional match (provider
/// id + media-item title) when one is known.
#[derive(Debug, Clone)]
pub struct MatchedFile {
    pub file: ScanFile,
    pub parsed: ParsedFileInfo,
    pub r#match: Option<MatchHint>,
}

/// Provisional metadata match for a file — provided by the
/// `MetadataMatcher` (out of scope for this unit) when the file
/// could be tied to a media item. Matches the fields the Phoenix
/// `%MatchResult{}` struct exposes that the grouper actually reads.
#[derive(Debug, Clone)]
pub struct MatchHint {
    pub title: String,
    pub provider_id: String,
    pub year: Option<i32>,
}

/// Episode entry inside a season group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupedEpisode {
    pub episode_number: i32,
    pub file: ScanFile,
    pub parsed: ParsedFileInfo,
    pub index: usize,
}

/// Season group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupedSeason {
    pub season_number: i32,
    pub episodes: Vec<GroupedEpisode>,
}

/// Series group.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupedSeries {
    pub title: String,
    pub provider_id: String,
    pub year: Option<i32>,
    pub seasons: Vec<GroupedSeason>,
}

/// Flat-list entry (movie, or ungrouped).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GroupedFile {
    pub file: ScanFile,
    pub parsed: ParsedFileInfo,
    pub r#match: Option<MatchHintSerializable>,
    pub index: usize,
}

/// Serializable form of [`MatchHint`] embedded in [`GroupedFile`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct MatchHintSerializable {
    pub title: String,
    pub provider_id: String,
    pub year: Option<i32>,
}

impl From<MatchHint> for MatchHintSerializable {
    fn from(h: MatchHint) -> Self {
        Self {
            title: h.title,
            provider_id: h.provider_id,
            year: h.year,
        }
    }
}

/// Whole-result summary.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct GroupedSummary {
    pub series: Vec<GroupedSeries>,
    pub movies: Vec<GroupedFile>,
    pub ungrouped: Vec<GroupedFile>,
}

/// Public facade.
#[derive(Debug, Default, Clone, Copy)]
pub struct FileGrouper;

impl FileGrouper {
    /// Group a list of matched files. The output is order-preserving:
    /// `index` on each emitted row carries the row's position in the
    /// input.
    #[must_use]
    pub fn group(matched: Vec<MatchedFile>) -> GroupedSummary {
        let mut summary = GroupedSummary::default();

        // Series accumulator: keyed by provider_id.
        let mut series_acc: Vec<GroupedSeries> = Vec::new();

        for (index, row) in matched.into_iter().enumerate() {
            match &row.r#match {
                Some(hint) if row.parsed.kind == MediaKind::TvShow => {
                    let hint_clone = hint.clone();
                    insert_episode(&mut series_acc, &hint_clone, row, index);
                }
                Some(hint) if row.parsed.kind == MediaKind::Movie => {
                    summary.movies.push(GroupedFile {
                        index,
                        r#match: Some(hint.clone().into()),
                        file: row.file,
                        parsed: row.parsed,
                    });
                }
                Some(hint) => {
                    // Unknown kind but matched — treat as ungrouped
                    // so the UI can prompt the operator to decide.
                    summary.ungrouped.push(GroupedFile {
                        index,
                        r#match: Some(hint.clone().into()),
                        file: row.file,
                        parsed: row.parsed,
                    });
                }
                None => {
                    summary.ungrouped.push(GroupedFile {
                        index,
                        r#match: None,
                        file: row.file,
                        parsed: row.parsed,
                    });
                }
            }
        }

        // Sort seasons by number; episodes by number.
        for series in &mut series_acc {
            series.seasons.sort_by_key(|s| s.season_number);
            for season in &mut series.seasons {
                season.episodes.sort_by_key(|e| e.episode_number);
            }
        }

        summary.series = series_acc;
        summary
    }
}

fn insert_episode(
    series_acc: &mut Vec<GroupedSeries>,
    hint: &MatchHint,
    row: MatchedFile,
    index: usize,
) {
    let series_idx = if let Some(i) = series_acc
        .iter()
        .position(|s| s.provider_id == hint.provider_id)
    {
        i
    } else {
        series_acc.push(GroupedSeries {
            title: hint.title.clone(),
            provider_id: hint.provider_id.clone(),
            year: hint.year,
            seasons: Vec::new(),
        });
        series_acc.len() - 1
    };

    let season_number = row.parsed.season.unwrap_or(0);
    let series = &mut series_acc[series_idx];
    let season_pos = series
        .seasons
        .iter()
        .position(|s| s.season_number == season_number);
    let season_idx = if let Some(i) = season_pos {
        i
    } else {
        series.seasons.push(GroupedSeason {
            season_number,
            episodes: Vec::new(),
        });
        series.seasons.len() - 1
    };

    let episodes = row.parsed.episodes.clone().unwrap_or_default();
    let primary = episodes.first().copied().unwrap_or(0);
    series.seasons[season_idx].episodes.push(GroupedEpisode {
        episode_number: primary,
        file: row.file,
        parsed: row.parsed,
        index,
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn scan_file(path: &str) -> ScanFile {
        ScanFile {
            path: PathBuf::from(path),
            size: 100,
            modified_at: chrono::Utc::now(),
            filename: path.rsplit_once('/').map_or(path, |(_, b)| b).to_owned(),
            directory: PathBuf::from("/tmp"),
            extension: ".mkv".into(),
        }
    }

    #[test]
    fn groups_tv_series_by_provider_id() {
        let m1 = MatchedFile {
            file: scan_file("/tmp/Show.S01E01.mkv"),
            parsed: crate::release_parser::ReleaseParser::parse("Show.S01E01.mkv"),
            r#match: Some(MatchHint {
                title: "Show".into(),
                provider_id: "tvdb-1".into(),
                year: Some(2020),
            }),
        };
        let m2 = MatchedFile {
            file: scan_file("/tmp/Show.S01E02.mkv"),
            parsed: crate::release_parser::ReleaseParser::parse("Show.S01E02.mkv"),
            r#match: Some(MatchHint {
                title: "Show".into(),
                provider_id: "tvdb-1".into(),
                year: Some(2020),
            }),
        };
        let result = FileGrouper::group(vec![m1, m2]);
        assert_eq!(result.series.len(), 1);
        let series = &result.series[0];
        assert_eq!(series.seasons.len(), 1);
        assert_eq!(series.seasons[0].episodes.len(), 2);
    }

    #[test]
    fn movies_land_in_flat_list() {
        let m = MatchedFile {
            file: scan_file("/tmp/Movie.2020.1080p.mkv"),
            parsed: crate::release_parser::ReleaseParser::parse("Movie.2020.1080p.mkv"),
            r#match: Some(MatchHint {
                title: "Movie".into(),
                provider_id: "tmdb-1".into(),
                year: Some(2020),
            }),
        };
        let result = FileGrouper::group(vec![m]);
        assert_eq!(result.movies.len(), 1);
        assert_eq!(result.series.len(), 0);
    }

    #[test]
    fn unmatched_files_land_in_ungrouped() {
        let m = MatchedFile {
            file: scan_file("/tmp/randomfile.mkv"),
            parsed: crate::release_parser::ReleaseParser::parse("randomfile.mkv"),
            r#match: None,
        };
        let result = FileGrouper::group(vec![m]);
        assert_eq!(result.ungrouped.len(), 1);
    }
}
