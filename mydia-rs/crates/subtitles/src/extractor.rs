//! Embedded-subtitle extraction.
//!
//! Port of `lib/mydia/subtitles/extractor.ex`. Wraps `ffprobe` and
//! `ffmpeg` to list and extract embedded subtitle tracks. The Rust
//! port uses `tokio::process::Command`; the parent worker is expected
//! to live on a long-running runtime so we don't block.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::warn;

use crate::error::SubtitleError;

/// Track descriptor returned by [`list_embedded_tracks`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct EmbeddedTrack {
    pub track_id: i32,
    pub language: Option<String>,
    pub title: Option<String>,
    /// Stream codec name from `ffprobe` (`subrip`, `ass`, `mov_text`, …).
    pub format: String,
}

/// Run `ffprobe -of json -show_streams` and return the subtitle streams.
pub async fn list_embedded_tracks(
    media_path: impl AsRef<Path>,
) -> Result<Vec<EmbeddedTrack>, SubtitleError> {
    let path = media_path.as_ref();
    if !path.exists() {
        return Ok(Vec::new());
    }
    let output = Command::new("ffprobe")
        .arg("-v")
        .arg("error")
        .arg("-select_streams")
        .arg("s")
        .arg("-show_streams")
        .arg("-of")
        .arg("json")
        .arg(path)
        .output()
        .await
        .map_err(|err| SubtitleError::network(format!("invoking ffprobe: {err}")))?;

    if !output.status.success() {
        return Err(SubtitleError::network(format!(
            "ffprobe exited {}",
            output.status
        )));
    }

    let parsed: FfprobeOutput = serde_json::from_slice(&output.stdout)
        .map_err(|err| SubtitleError::parse(format!("ffprobe JSON: {err}")))?;

    Ok(parsed
        .streams
        .into_iter()
        .map(|s| EmbeddedTrack {
            track_id: s.index,
            language: s.tags.as_ref().and_then(|t| t.language.clone()),
            title: s.tags.as_ref().and_then(|t| t.title.clone()),
            format: s.codec_name,
        })
        .collect())
}

/// Extract a single embedded track to disk via `ffmpeg`.
///
/// `format` is the output container (`srt`, `vtt`, `ass`); the caller
/// is responsible for choosing one supported by ffmpeg's `-c:s` codec.
pub async fn extract_embedded_track(
    media_path: impl AsRef<Path>,
    track_id: i32,
    output_path: impl AsRef<Path>,
    format: &str,
) -> Result<PathBuf, SubtitleError> {
    let output = output_path.as_ref().to_path_buf();
    let codec = match format {
        "srt" | "subrip" => "srt",
        "vtt" | "webvtt" => "webvtt",
        "ass" | "ssa" => "ass",
        other => {
            warn!(format = other, "unknown subtitle format, defaulting to srt");
            "srt"
        }
    };

    let status = Command::new("ffmpeg")
        .arg("-y")
        .arg("-i")
        .arg(media_path.as_ref())
        .arg("-map")
        .arg(format!("0:s:{track_id}"))
        .arg("-c:s")
        .arg(codec)
        .arg(&output)
        .status()
        .await
        .map_err(|err| SubtitleError::network(format!("invoking ffmpeg: {err}")))?;

    if !status.success() {
        return Err(SubtitleError::network(format!("ffmpeg exited {status}")));
    }
    Ok(output)
}

// -- ffprobe JSON wire shape ------------------------------------------

#[derive(Debug, Deserialize)]
struct FfprobeOutput {
    #[serde(default)]
    streams: Vec<FfprobeStream>,
}

#[derive(Debug, Deserialize)]
struct FfprobeStream {
    index: i32,
    #[serde(default)]
    codec_name: String,
    #[serde(default)]
    tags: Option<FfprobeTags>,
}

#[derive(Debug, Deserialize)]
struct FfprobeTags {
    language: Option<String>,
    title: Option<String>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffprobe_output_parses_with_optional_tags() {
        let raw = serde_json::json!({
            "streams": [
                { "index": 0, "codec_name": "subrip", "tags": { "language": "eng" }},
                { "index": 1, "codec_name": "ass" }
            ]
        });
        let parsed: FfprobeOutput = serde_json::from_value(raw).unwrap();
        assert_eq!(parsed.streams.len(), 2);
        assert_eq!(
            parsed.streams[0].tags.as_ref().unwrap().language.as_deref(),
            Some("eng")
        );
    }

    #[tokio::test]
    async fn missing_file_returns_empty_list() {
        let tracks = list_embedded_tracks("/nonexistent/file.mkv").await.unwrap();
        assert!(tracks.is_empty());
    }
}
