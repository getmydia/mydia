//! Port of `Mydia.Library.MediaFile` (`lib/mydia/library/media_file.ex`).
//!
//! Phoenix table: `media_files`. `metadata` is the
//! `Mydia.Library.FileMetadataType` custom Ecto JSON-text type,
//! ported as [`JsonMap<serde_json::Value>`] until the typed
//! `FileMetadata` struct lands.
//!
//! The columns `analyzed_at`, `analysis_attempts`, and
//! `last_analysis_error` come from the fast-library-import work; the
//! `trashed_at` soft-delete column from the May 2026 migration; and
//! `relative_path` + `library_path_id` from the Phase 1 path-storage
//! refactor. All present here so models stay current with the latest
//! schema.

use mydia_rs_db::types::{DateTimeSecs, JsonMap, UuidText};
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, sqlx::FromRow, Serialize, Deserialize)]
pub struct MediaFile {
    pub id: UuidText,
    pub media_item_id: UuidText,
    pub episode_id: Option<UuidText>,
    pub quality_profile_id: Option<UuidText>,
    pub library_path_id: Option<UuidText>,
    pub path: Option<String>,
    pub relative_path: Option<String>,
    pub size: Option<i64>,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub hdr_format: Option<String>,
    pub audio_codec: Option<String>,
    pub bitrate: Option<i64>,
    pub verified_at: Option<DateTimeSecs>,
    pub analyzed_at: Option<DateTimeSecs>,
    pub analysis_attempts: i32,
    pub last_analysis_error: Option<String>,
    pub metadata: Option<JsonMap<serde_json::Value>>,
    pub cover_blob: Option<String>,
    pub sprite_blob: Option<String>,
    pub vtt_blob: Option<String>,
    pub preview_blob: Option<String>,
    pub phash: Option<String>,
    pub generated_at: Option<DateTimeSecs>,
    pub trashed_at: Option<DateTimeSecs>,
    pub inserted_at: DateTimeSecs,
    pub updated_at: DateTimeSecs,
}
