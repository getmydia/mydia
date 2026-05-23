//! Port of `Mydia.Subtitles.Subtitle`
//! (`lib/mydia/subtitles/subtitle.ex`).
//!
//! Phoenix table: `subtitles` (see migration
//! `priv/repo/migrations/20251116022802_create_subtitle_tables.exs`).
//! Stores metadata about externally-acquired subtitle files —
//! operator-uploaded sidecars or provider-downloaded files served via
//! `/api/player/v1/subtitles/:type/:id/:track`. Embedded subtitle
//! streams are not represented here; they're discovered live via
//! `ffprobe` against the media file.

use mydia_rs_db::types::{DateTimeSecs, UuidText};
use serde::{Deserialize, Serialize};

/// Supported subtitle formats per the Phoenix `Subtitle.supported_formats/0`
/// validator. Mirrors the wire shape consumed by the player.
pub const SUPPORTED_FORMATS: &[&str] = &["srt", "ass", "vtt"];

#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct Subtitle {
    pub id: UuidText,
    pub media_file_id: UuidText,
    pub language: String,
    pub provider: String,
    pub subtitle_hash: String,
    pub file_path: String,
    pub sync_offset: i32,
    pub format: String,
    pub rating: Option<f64>,
    pub download_count: Option<i32>,
    pub hearing_impaired: bool,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}

impl Subtitle {
    /// Phoenix's `Subtitle.supported_formats/0` returns the list as
    /// `String.t()`. Surfacing it here keeps callers (REST handler
    /// content-type dispatch, future GraphQL validators) from
    /// re-encoding the list.
    pub fn supported_formats() -> &'static [&'static str] {
        SUPPORTED_FORMATS
    }
}
