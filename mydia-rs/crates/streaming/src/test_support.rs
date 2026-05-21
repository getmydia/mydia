//! Test fixtures shared by the unit tests across modules.

use chrono::Utc;
use mydia_rs_db::types::{DateTimeSecs, UuidText};
use mydia_rs_models::MediaFile;

/// A minimal [`MediaFile`] populated with neutral defaults. Individual
/// tests mutate the codec / container fields they care about.
pub fn media_file_fixture() -> MediaFile {
    MediaFile {
        id: UuidText::new_v4(),
        media_item_id: UuidText::new_v4(),
        episode_id: None,
        quality_profile_id: None,
        library_path_id: None,
        path: Some("/library/test.mkv".to_string()),
        relative_path: Some("test.mkv".to_string()),
        size: Some(1_000_000),
        resolution: Some("1080p".to_string()),
        codec: Some("h264".to_string()),
        hdr_format: None,
        audio_codec: Some("aac".to_string()),
        bitrate: Some(5_000_000),
        verified_at: None,
        analyzed_at: Some(DateTimeSecs(Utc::now())),
        analysis_attempts: 1,
        last_analysis_error: None,
        metadata: None,
        cover_blob: None,
        sprite_blob: None,
        vtt_blob: None,
        preview_blob: None,
        phash: None,
        generated_at: None,
        trashed_at: None,
        inserted_at: DateTimeSecs(Utc::now()),
        updated_at: DateTimeSecs(Utc::now()),
    }
}
