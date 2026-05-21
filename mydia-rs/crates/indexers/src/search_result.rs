//! Normalized search-result struct.
//!
//! Port of `lib/mydia/indexers/search_result.ex` plus the
//! `Mydia.Indexers.Structs.{QualityInfo, SearchResultMetadata, RankedResult, ScoreBreakdown}`
//! companions. Every adapter normalizes its responses into [`SearchResult`].

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Download protocol discriminant for a result. `:torrent` and `:nzb`
/// in Elixir.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DownloadProtocol {
    Torrent,
    Nzb,
}

/// Parsed quality information lifted out of a release title.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct QualityInfo {
    pub resolution: Option<String>,
    pub source: Option<String>,
    pub codec: Option<String>,
    pub audio: Option<String>,
    #[serde(default)]
    pub hdr: bool,
    pub hdr_format: Option<String>,
    #[serde(default)]
    pub proper: bool,
    #[serde(default)]
    pub repack: bool,
}

impl QualityInfo {
    /// Returns true when every field is unset (apart from boolean flags).
    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.resolution.is_none()
            && self.source.is_none()
            && self.codec.is_none()
            && self.audio.is_none()
    }

    /// Render a compact human label — `"1080p BluRay x264 DTS"`.
    #[must_use]
    pub fn format(&self) -> String {
        let mut parts: Vec<String> = Vec::new();
        if let Some(r) = &self.resolution {
            parts.push(r.clone());
        }
        if let Some(s) = &self.source {
            parts.push(s.clone());
        }
        if let Some(c) = &self.codec {
            parts.push(c.clone());
        }
        if let Some(a) = &self.audio {
            parts.push(a.clone());
        }
        if self.hdr {
            if let Some(fmt) = &self.hdr_format {
                parts.push(fmt.clone());
            } else {
                parts.push("HDR".into());
            }
        }
        if self.proper {
            parts.push("PROPER".into());
        }
        if self.repack {
            parts.push("REPACK".into());
        }
        parts.join(" ")
    }
}

/// Extra metadata typically attached to season-pack results.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchResultMetadata {
    #[serde(default)]
    pub season_pack: bool,
    pub season_number: Option<i32>,
    pub episode_count: Option<i32>,
    #[serde(default)]
    pub episode_ids: Vec<String>,
}

impl SearchResultMetadata {
    #[must_use]
    pub fn season_pack(season_number: i32, episode_count: i32, episode_ids: Vec<String>) -> Self {
        Self {
            season_pack: true,
            season_number: Some(season_number),
            episode_count: Some(episode_count),
            episode_ids,
        }
    }
}

/// Normalized search result. All adapters return this shape.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SearchResult {
    pub title: String,
    pub size: u64,
    pub seeders: Option<u32>,
    pub leechers: Option<u32>,
    pub download_url: String,
    pub info_url: Option<String>,
    pub indexer: String,
    pub category: Option<i32>,
    pub published_at: Option<DateTime<Utc>>,
    pub quality: Option<QualityInfo>,
    pub metadata: Option<SearchResultMetadata>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub download_protocol: Option<DownloadProtocol>,
    pub usenet_date: Option<DateTime<Utc>>,
    pub nzb_completion: Option<f64>,
    pub nzb_grabs: Option<u32>,
    pub guid: Option<String>,
}

impl SearchResult {
    /// Healthy seeder→leecher ratio normalized to `[0.0, 1.0]`.
    #[must_use]
    pub fn health_score(&self) -> f64 {
        let Some(seeders) = self.seeders else {
            return 0.0;
        };
        let leechers = self.leechers.unwrap_or(0);
        let total = seeders + leechers;
        if total == 0 {
            return 0.0;
        }
        if seeders == 0 {
            return 0.1;
        }
        let denom = f64::from(seeders) + f64::from(leechers);
        (f64::from(seeders) / denom + f64::from(seeders) / 100.0).min(1.0)
    }

    /// Render the size as a human-friendly string (`"1.0 GB"`).
    #[must_use]
    pub fn format_size(&self) -> String {
        format_bytes(self.size)
    }

    /// Concise quality description, falls back to `"Unknown"`.
    #[must_use]
    pub fn quality_description(&self) -> String {
        match &self.quality {
            None => "Unknown".into(),
            Some(q) => {
                let formatted = q.format();
                if formatted.is_empty() {
                    "Unknown".into()
                } else {
                    formatted
                }
            }
        }
    }
}

/// Builder for a [`SearchResult`]. Mirrors the Elixir `SearchResult.new/1`
/// keyword API while leaving fields strongly typed.
#[derive(Debug, Default)]
pub struct SearchResultBuilder {
    pub title: Option<String>,
    pub size: Option<u64>,
    pub seeders: Option<u32>,
    pub leechers: Option<u32>,
    pub download_url: Option<String>,
    pub info_url: Option<String>,
    pub indexer: Option<String>,
    pub category: Option<i32>,
    pub published_at: Option<DateTime<Utc>>,
    pub quality: Option<QualityInfo>,
    pub metadata: Option<SearchResultMetadata>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub imdb_id: Option<String>,
    pub download_protocol: Option<DownloadProtocol>,
    pub usenet_date: Option<DateTime<Utc>>,
    pub nzb_completion: Option<f64>,
    pub nzb_grabs: Option<u32>,
    pub guid: Option<String>,
}

impl SearchResultBuilder {
    pub fn new() -> Self {
        Self::default()
    }

    /// Build, returning `None` if any of the enforced fields are missing
    /// (title, size, seeders, leechers, `download_url`, indexer in the
    /// Elixir source — we surface this as a `Result` so callers can route
    /// the error properly).
    pub fn build(self) -> Result<SearchResult, &'static str> {
        Ok(SearchResult {
            title: self.title.ok_or("title is required")?,
            size: self.size.ok_or("size is required")?,
            seeders: self.seeders,
            leechers: self.leechers,
            download_url: self.download_url.ok_or("download_url is required")?,
            info_url: self.info_url,
            indexer: self.indexer.ok_or("indexer is required")?,
            category: self.category,
            published_at: self.published_at,
            quality: self.quality,
            metadata: self.metadata,
            tmdb_id: self.tmdb_id,
            tvdb_id: self.tvdb_id,
            imdb_id: self.imdb_id,
            download_protocol: self.download_protocol,
            usenet_date: self.usenet_date,
            nzb_completion: self.nzb_completion,
            nzb_grabs: self.nzb_grabs,
            guid: self.guid,
        })
    }
}

fn format_bytes(bytes: u64) -> String {
    const KB: f64 = 1024.0;
    const MB: f64 = 1024.0 * 1024.0;
    const GB: f64 = 1024.0 * 1024.0 * 1024.0;
    let b = bytes as f64;
    if b < KB {
        format!("{bytes} B")
    } else if b < MB {
        format!("{:.1} KB", b / KB)
    } else if b < GB {
        format!("{:.1} MB", b / MB)
    } else {
        format!("{:.1} GB", b / GB)
    }
}

/// Score breakdown for a ranked result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ScoreBreakdown {
    pub quality: f64,
    pub seeders: f64,
    pub size: f64,
    pub age: f64,
    pub title_match: f64,
    pub tag_bonus: f64,
    pub total: f64,
}

/// A [`SearchResult`] decorated with its ranking score.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RankedResult {
    pub result: SearchResult,
    pub score: f64,
    pub breakdown: ScoreBreakdown,
}

#[cfg(test)]
mod tests {
    use super::*;

    fn result(seeders: Option<u32>, leechers: Option<u32>) -> SearchResult {
        SearchResultBuilder {
            title: Some("Ubuntu 22.04".into()),
            size: Some(1_073_741_824),
            seeders,
            leechers,
            download_url: Some("magnet:?xt=urn:btih:abc".into()),
            indexer: Some("Prowlarr".into()),
            ..SearchResultBuilder::new()
        }
        .build()
        .unwrap()
    }

    #[test]
    fn health_score_returns_zero_for_nil_seeders() {
        let r = result(None, None);
        assert!((r.health_score() - 0.0).abs() < f64::EPSILON);
    }

    #[test]
    fn health_score_caps_at_one() {
        let r = result(Some(10_000), Some(0));
        assert!((r.health_score() - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn format_size_renders_gigabytes() {
        let r = result(Some(10), Some(5));
        assert_eq!(r.format_size(), "1.0 GB");
    }

    #[test]
    fn quality_description_falls_back_to_unknown() {
        let r = result(Some(10), Some(5));
        assert_eq!(r.quality_description(), "Unknown");
    }

    #[test]
    fn quality_format_includes_all_set_parts() {
        let q = QualityInfo {
            resolution: Some("1080p".into()),
            source: Some("BluRay".into()),
            codec: Some("x264".into()),
            audio: Some("DTS".into()),
            hdr: true,
            hdr_format: Some("DV".into()),
            proper: true,
            repack: false,
        };
        assert_eq!(q.format(), "1080p BluRay x264 DTS DV PROPER");
    }

    #[test]
    fn season_pack_helper_sets_flag() {
        let m = SearchResultMetadata::season_pack(1, 10, vec!["a".into(), "b".into()]);
        assert!(m.season_pack);
        assert_eq!(m.season_number, Some(1));
        assert_eq!(m.episode_count, Some(10));
        assert_eq!(m.episode_ids.len(), 2);
    }
}
