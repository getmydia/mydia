//! ffprobe-driven media-file analyzer.
//!
//! Port of `lib/mydia/library/file_analyzer.ex`. Uses
//! `tokio::process::Command` with `kill_on_drop(true)` and a
//! `tokio::time::timeout(30s, ...)` wrapper so a cancelled probe (or
//! one that hangs on a slow filesystem) does not leak a zombie
//! process. Mirrors the hard-timeout pattern from the
//! `2026-05-16-001-feat-fast-library-import-plan.md` plan.
//!
//! Persistence — writing `analyzed_at`, `analysis_attempts`,
//! `last_analysis_error` onto the `media_files` row — is exposed
//! through [`FileAnalyzer::apply_to_media_file`] so U17's
//! `FileAnalysis` worker can call it after a successful or failed
//! probe.

use std::path::Path;
use std::process::Stdio;
use std::time::Duration;

use chrono::{DateTime, Utc};
use mydia_rs_db::types::DateTimeSecs;
use mydia_rs_models::MediaFile;
use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::error::LibraryError;

/// Default ffprobe timeout — Phoenix `:ffprobe_timeout_ms` config
/// defaults to 30s; we match.
pub const DEFAULT_FFPROBE_TIMEOUT_SECS: u64 = 30;

/// Outcome carried back to the worker so it can decide retry policy.
#[derive(Debug, Clone)]
pub enum AnalysisOutcome {
    /// `ffprobe` ran and we parsed the response. Persist the result
    /// onto the row.
    Success(FileAnalysis),
    /// `ffprobe` ran but failed; the row should be marked with
    /// `last_analysis_error` and `analysis_attempts` incremented.
    Failed(String),
}

/// Technical metadata extracted from a media file.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct FileAnalysis {
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub bitrate: Option<i64>,
    pub hdr_format: Option<String>,
    pub size: Option<i64>,
    pub duration_secs: Option<f64>,
    pub container: Option<String>,
}

/// Public facade.
#[derive(Debug, Clone, Copy)]
pub struct FileAnalyzer {
    timeout: Duration,
}

impl Default for FileAnalyzer {
    fn default() -> Self {
        Self::new(Duration::from_secs(DEFAULT_FFPROBE_TIMEOUT_SECS))
    }
}

impl FileAnalyzer {
    /// Build an analyzer with an explicit timeout.
    #[must_use]
    pub fn new(timeout: Duration) -> Self {
        Self { timeout }
    }

    /// Analyze a media file. Returns the parsed result, or a
    /// [`LibraryError`] describing why the probe failed.
    pub async fn analyze(&self, path: impl AsRef<Path>) -> Result<FileAnalysis, LibraryError> {
        let path = path.as_ref();

        let metadata = tokio::fs::metadata(path)
            .await
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => LibraryError::NotFound(path.display().to_string()),
                std::io::ErrorKind::PermissionDenied => {
                    LibraryError::PermissionDenied(path.display().to_string())
                }
                _ => LibraryError::Io {
                    path: path.display().to_string(),
                    source: e,
                },
            })?;

        let size = i64::try_from(metadata.len()).ok();

        let ffprobe_bin = which_ffprobe().ok_or(LibraryError::FfprobeNotFound)?;

        let mut cmd = Command::new(ffprobe_bin);
        cmd.arg("-v")
            .arg("quiet")
            .arg("-print_format")
            .arg("json")
            .arg("-show_format")
            .arg("-show_streams")
            .arg(path.as_os_str())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);

        let timeout_secs = self.timeout.as_secs();
        let exec = cmd.output();

        let output = match tokio::time::timeout(self.timeout, exec).await {
            Ok(Ok(o)) => o,
            Ok(Err(e)) => {
                return Err(LibraryError::Io {
                    path: path.display().to_string(),
                    source: e,
                });
            }
            Err(_elapsed) => {
                return Err(LibraryError::FfprobeTimeout {
                    seconds: timeout_secs,
                });
            }
        };

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).trim().to_owned();
            return Err(LibraryError::FfprobeFailed(stderr));
        }

        let payload: FfprobeJson = serde_json::from_slice(&output.stdout)?;
        let mut analysis = payload.into_file_analysis();
        analysis.size = size;
        Ok(analysis)
    }

    /// Apply the result of an analyze call to a [`MediaFile`] row.
    /// Mutates the row in place — the caller is responsible for
    /// persisting it back to the database.
    ///
    /// `attempt_at` defaults to "now" — the parameter exists so
    /// tests can pin time.
    pub fn apply_to_media_file(
        outcome: &AnalysisOutcome,
        row: &mut MediaFile,
        attempt_at: Option<DateTime<Utc>>,
    ) {
        let now = attempt_at.unwrap_or_else(Utc::now);
        row.analysis_attempts = row.analysis_attempts.saturating_add(1);
        match outcome {
            AnalysisOutcome::Success(analysis) => {
                row.analyzed_at = Some(DateTimeSecs(now));
                row.last_analysis_error = None;
                if analysis.resolution.is_some() {
                    row.resolution.clone_from(&analysis.resolution);
                }
                if analysis.codec.is_some() {
                    row.codec.clone_from(&analysis.codec);
                }
                if analysis.audio_codec.is_some() {
                    row.audio_codec.clone_from(&analysis.audio_codec);
                }
                if analysis.hdr_format.is_some() {
                    row.hdr_format.clone_from(&analysis.hdr_format);
                }
                if analysis.bitrate.is_some() {
                    row.bitrate = analysis.bitrate;
                }
                if analysis.size.is_some() {
                    row.size = analysis.size;
                }
            }
            AnalysisOutcome::Failed(msg) => {
                row.last_analysis_error = Some(msg.clone());
            }
        }
    }
}

/// Resolve the ffprobe binary on `PATH`. Returns the absolute path
/// when found.
fn which_ffprobe() -> Option<std::path::PathBuf> {
    let env_path = std::env::var_os("PATH")?;
    for dir in std::env::split_paths(&env_path) {
        let candidate = dir.join("ffprobe");
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

// -- ffprobe JSON shape -----------------------------------------------------

#[derive(Debug, Deserialize)]
struct FfprobeJson {
    #[serde(default)]
    streams: Vec<FfprobeStream>,
    #[serde(default)]
    format: Option<FfprobeFormat>,
}

#[derive(Debug, Deserialize)]
struct FfprobeStream {
    #[serde(default)]
    codec_type: Option<String>,
    #[serde(default)]
    codec_name: Option<String>,
    #[serde(default)]
    #[allow(dead_code)]
    width: Option<u32>,
    #[serde(default)]
    height: Option<u32>,
    #[serde(default)]
    color_transfer: Option<String>,
}

#[derive(Debug, Deserialize)]
struct FfprobeFormat {
    #[serde(default)]
    duration: Option<String>,
    #[serde(default)]
    bit_rate: Option<String>,
    #[serde(default)]
    format_name: Option<String>,
}

impl FfprobeJson {
    fn into_file_analysis(self) -> FileAnalysis {
        let mut analysis = FileAnalysis::default();
        for stream in self.streams {
            match stream.codec_type.as_deref() {
                Some("video") if analysis.codec.is_none() => {
                    analysis.codec = normalize_codec(stream.codec_name.as_deref());
                    analysis.resolution = stream.height.map(resolution_label);
                    analysis.hdr_format = hdr_from_transfer(stream.color_transfer.as_deref());
                }
                Some("audio") if analysis.audio_codec.is_none() => {
                    analysis.audio_codec = stream.codec_name.map(normalize_audio);
                }
                _ => {}
            }
        }

        if let Some(format) = self.format {
            if let Some(d) = format
                .duration
                .as_deref()
                .and_then(|s| s.parse::<f64>().ok())
            {
                analysis.duration_secs = Some(d);
            }
            if let Some(b) = format
                .bit_rate
                .as_deref()
                .and_then(|s| s.parse::<i64>().ok())
            {
                analysis.bitrate = Some(b);
            }
            if let Some(fmt) = format.format_name {
                analysis.container = Some(fmt);
            }
        }
        analysis
    }
}

fn normalize_codec(name: Option<&str>) -> Option<String> {
    let n = name?;
    let upper = n.to_uppercase();
    let mapped = match upper.as_str() {
        "H264" | "AVC" => "H.264",
        "HEVC" | "H265" => "H.265",
        "AV1" => "AV1",
        "VP9" => "VP9",
        other => return Some(other.to_owned()),
    };
    Some(mapped.to_owned())
}

fn normalize_audio(name: String) -> String {
    match name.to_lowercase().as_str() {
        "aac" => "AAC".into(),
        "ac3" => "AC3".into(),
        "eac3" => "EAC3".into(),
        "dts" => "DTS".into(),
        "truehd" => "TrueHD".into(),
        "flac" => "FLAC".into(),
        "opus" => "Opus".into(),
        "mp3" => "MP3".into(),
        _ => name,
    }
}

fn resolution_label(height: u32) -> String {
    match height {
        h if h >= 2160 => "2160p".into(),
        h if h >= 1440 => "1440p".into(),
        h if h >= 1080 => "1080p".into(),
        h if h >= 720 => "720p".into(),
        h if h >= 576 => "576p".into(),
        h if h >= 540 => "540p".into(),
        h if h >= 480 => "480p".into(),
        h => format!("{h}p"),
    }
}

fn hdr_from_transfer(transfer: Option<&str>) -> Option<String> {
    match transfer? {
        "smpte2084" => Some("HDR10".into()),
        "arib-std-b67" => Some("HLG".into()),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use mydia_rs_db::types::UuidText;

    #[test]
    fn apply_failure_sets_error_and_increments_attempts() {
        let mut row = test_row();
        let outcome = AnalysisOutcome::Failed("ffprobe failed".into());
        FileAnalyzer::apply_to_media_file(&outcome, &mut row, None);
        assert_eq!(row.analysis_attempts, 1);
        assert_eq!(row.last_analysis_error.as_deref(), Some("ffprobe failed"));
        assert!(row.analyzed_at.is_none());
    }

    #[test]
    fn apply_success_populates_quality_fields() {
        let mut row = test_row();
        let outcome = AnalysisOutcome::Success(FileAnalysis {
            resolution: Some("1080p".into()),
            codec: Some("H.264".into()),
            audio_codec: Some("AAC".into()),
            bitrate: Some(8_000_000),
            size: Some(2_147_483_648),
            ..FileAnalysis::default()
        });
        FileAnalyzer::apply_to_media_file(&outcome, &mut row, None);
        assert_eq!(row.analysis_attempts, 1);
        assert!(row.analyzed_at.is_some());
        assert_eq!(row.resolution.as_deref(), Some("1080p"));
        assert_eq!(row.codec.as_deref(), Some("H.264"));
        assert_eq!(row.audio_codec.as_deref(), Some("AAC"));
        assert_eq!(row.bitrate, Some(8_000_000));
    }

    #[tokio::test]
    async fn analyze_missing_file_returns_not_found() {
        let analyzer = FileAnalyzer::default();
        let err = analyzer.analyze("/nonexistent/file.mkv").await.unwrap_err();
        assert!(matches!(err, LibraryError::NotFound(_)));
    }

    fn test_row() -> MediaFile {
        let now = DateTimeSecs(Utc::now());
        MediaFile {
            id: UuidText(uuid::Uuid::new_v4()),
            media_item_id: UuidText(uuid::Uuid::new_v4()),
            episode_id: None,
            quality_profile_id: None,
            library_path_id: None,
            path: Some("/tmp/file.mkv".into()),
            relative_path: None,
            size: None,
            resolution: None,
            codec: None,
            hdr_format: None,
            audio_codec: None,
            bitrate: None,
            verified_at: None,
            analyzed_at: None,
            analysis_attempts: 0,
            last_analysis_error: None,
            metadata: None,
            cover_blob: None,
            sprite_blob: None,
            vtt_blob: None,
            preview_blob: None,
            phash: None,
            generated_at: None,
            trashed_at: None,
            inserted_at: now,
            updated_at: now,
        }
    }
}
