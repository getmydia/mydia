//! Shared structs for subtitle providers.
//!
//! Ports `lib/mydia/subtitles/provider/{search_result.ex,quota_info.ex}`
//! plus the small subtitle struct in `lib/mydia/subtitles/subtitle.ex`.

use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};

/// Provider kind (`:relay` or `:opensubtitles` on the Elixir side).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ProviderKind {
    Relay,
    OpenSubtitles,
}

/// One subtitle search result.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleSearchResult {
    pub file_id: String,
    pub language: String,
    pub format: String,
    pub subtitle_hash: String,
    pub file_name: Option<String>,
    pub rating: Option<f64>,
    pub download_count: Option<u32>,
    #[serde(default)]
    pub hearing_impaired: bool,
    #[serde(default)]
    pub moviehash_match: bool,
}

impl SubtitleSearchResult {
    /// Construct from a free-form JSON map (matches the Elixir
    /// `SearchResult.from_map/1`).
    #[must_use]
    pub fn from_value(v: &serde_json::Value) -> Self {
        Self {
            file_id: pluck_string(v, "file_id"),
            language: pluck_string(v, "language"),
            format: pluck_string(v, "format"),
            subtitle_hash: pluck_string(v, "subtitle_hash"),
            file_name: v
                .get("file_name")
                .and_then(serde_json::Value::as_str)
                .map(str::to_string),
            rating: v.get("rating").and_then(serde_json::Value::as_f64),
            download_count: v
                .get("download_count")
                .and_then(serde_json::Value::as_u64)
                .map(|v| v as u32),
            hearing_impaired: v
                .get("hearing_impaired")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
            moviehash_match: v
                .get("moviehash_match")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false),
        }
    }
}

fn pluck_string(v: &serde_json::Value, key: &str) -> String {
    match v.get(key) {
        Some(serde_json::Value::String(s)) => s.clone(),
        Some(serde_json::Value::Number(n)) => n.to_string(),
        _ => String::new(),
    }
}

/// Quota model for a provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum QuotaType {
    Unlimited,
    Limited,
}

/// Current quota state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct QuotaInfo {
    pub r#type: QuotaType,
    pub provider_type: ProviderKind,
    pub remaining: Option<u32>,
    pub total: Option<u32>,
    pub reset_at: Option<DateTime<Utc>>,
    #[serde(default)]
    pub vip: bool,
}

impl QuotaInfo {
    /// Relay-style unlimited quota.
    #[must_use]
    pub fn unlimited(provider: ProviderKind) -> Self {
        Self {
            r#type: QuotaType::Unlimited,
            provider_type: provider,
            remaining: None,
            total: None,
            reset_at: None,
            vip: false,
        }
    }

    /// Limited quota (OpenSubtitles free / VIP).
    #[must_use]
    pub fn limited(
        provider: ProviderKind,
        remaining: u32,
        total: u32,
        reset_at: Option<DateTime<Utc>>,
        vip: bool,
    ) -> Self {
        Self {
            r#type: QuotaType::Limited,
            provider_type: provider,
            remaining: Some(remaining),
            total: Some(total),
            reset_at,
            vip,
        }
    }

    /// True when remaining hits zero on a limited quota.
    #[must_use]
    pub fn is_exhausted(&self) -> bool {
        matches!(self.r#type, QuotaType::Limited) && self.remaining == Some(0)
    }

    /// True for limited quotas with less than 10% remaining.
    #[must_use]
    pub fn is_low(&self) -> bool {
        let (QuotaType::Limited, Some(remaining), Some(total)) =
            (self.r#type, self.remaining, self.total)
        else {
            return false;
        };
        if total == 0 {
            return false;
        }
        (f64::from(remaining) / f64::from(total)) < 0.1
    }

    /// Quota usage as a `0..100` percentage.
    #[must_use]
    pub fn usage_percent(&self) -> Option<f64> {
        let (QuotaType::Limited, Some(remaining), Some(total)) =
            (self.r#type, self.remaining, self.total)
        else {
            return None;
        };
        if total == 0 {
            return None;
        }
        let pct = (f64::from(total - remaining) / f64::from(total)) * 100.0;
        Some((pct * 10.0).round() / 10.0)
    }
}

/// Search criteria used by every provider. Mirrors the Elixir
/// `search_params/0` map type.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct SearchParams {
    pub languages: String,
    pub file_hash: Option<String>,
    pub file_size: Option<u64>,
    pub imdb_id: Option<String>,
    pub tmdb_id: Option<String>,
    pub media_type: Option<String>,
    pub season_number: Option<i32>,
    pub episode_number: Option<i32>,
    pub query: Option<String>,
}

/// Slimmed-down `Subtitle` record. The schema definition is owned by
/// `crates/db` (U5); we just type the fields workers + resolvers read.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleRecord {
    pub id: String,
    pub media_file_id: String,
    pub language: String,
    pub format: String,
    pub provider: ProviderKind,
    pub source_id: Option<String>,
    pub hash: Option<String>,
    pub file_size: Option<u64>,
    pub inserted_at: DateTime<Utc>,
    pub updated_at: DateTime<Utc>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn quota_unlimited_never_exhausted() {
        let q = QuotaInfo::unlimited(ProviderKind::Relay);
        assert!(!q.is_exhausted());
        assert!(!q.is_low());
        assert_eq!(q.usage_percent(), None);
    }

    #[test]
    fn quota_limited_is_low_below_ten_percent() {
        let q = QuotaInfo::limited(ProviderKind::OpenSubtitles, 5, 200, None, false);
        assert!(q.is_low());
        assert!(!q.is_exhausted());
    }

    #[test]
    fn quota_usage_percent_rounds_to_one_decimal() {
        let q = QuotaInfo::limited(ProviderKind::OpenSubtitles, 150, 200, None, false);
        assert_eq!(q.usage_percent(), Some(25.0));
    }

    #[test]
    fn search_result_from_value_handles_missing_optional_fields() {
        let v = serde_json::json!({
            "file_id": 42,
            "language": "en",
            "format": "srt",
            "subtitle_hash": "abc",
        });
        let r = SubtitleSearchResult::from_value(&v);
        assert_eq!(r.file_id, "42");
        assert_eq!(r.language, "en");
        assert!(!r.hearing_impaired);
        assert!(!r.moviehash_match);
    }
}
