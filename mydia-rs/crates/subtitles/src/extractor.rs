//! Embedded-subtitle extraction.
//!
//! Port of `lib/mydia/subtitles/extractor.ex`. Wraps `ffprobe` and
//! `ffmpeg` to list and extract embedded subtitle tracks. The Rust
//! port uses `tokio::process::Command`; the parent worker is expected
//! to live on a long-running runtime so we don't block.
//!
//! ## Cache layout (`extract_to_cache`)
//!
//! Phoenix's `extract_subtitle_track/3` writes to `System.tmp_dir!()`
//! and unlinks after sending, which means every player seek re-pays
//! the ffmpeg cost. The Rust port instead writes to a persistent
//! cache rooted at `WebState.generated_media_path` (the same
//! operator-configurable base used for thumbnail sprites + VTTs). The
//! caller passes a fully-resolved cache path; this module owns the
//! atomic-write (`.tmp` then rename) so concurrent extractions for
//! the same track don't tear.
//!
//! Naming is `<base>/subtitles/<media_file_id>/<track_id>.<ext>` —
//! scoped per media file so a `media_file` delete can nuke the
//! directory wholesale without touching siblings. The caller resolves
//! the full path so a future eviction policy can live alongside the
//! handler without touching the extractor.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tracing::warn;

use crate::error::SubtitleError;

/// Hard-timeout applied to the ffmpeg subtitle-extraction invocation.
/// Phoenix's `System.cmd("ffmpeg", ...)` runs unbounded; for the
/// player-facing REST endpoint we cap at 30s to keep a stuck ffmpeg
/// from pinning a request slot indefinitely. Subtitle extraction is
/// cheap (`-c:s copy` or text-format re-encode) so a healthy run is
/// well under a second.
const FFMPEG_TIMEOUT: Duration = Duration::from_secs(30);

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
/// Honors a 30s hard timeout and `kill_on_drop` so a stuck ffmpeg
/// doesn't outlive the awaiting future. Writes directly to
/// `output_path`; use [`extract_to_cache`] for the atomic-rename
/// variant used by the REST handler.
pub async fn extract_embedded_track(
    media_path: impl AsRef<Path>,
    track_id: i32,
    output_path: impl AsRef<Path>,
    format: &str,
) -> Result<PathBuf, SubtitleError> {
    let output = output_path.as_ref().to_path_buf();
    let codec = ffmpeg_codec_for(format);

    let mut child = Command::new("ffmpeg")
        .arg("-y")
        .arg("-i")
        .arg(media_path.as_ref())
        .arg("-map")
        .arg(format!("0:s:{track_id}"))
        .arg("-c:s")
        .arg(codec)
        .arg(&output)
        .kill_on_drop(true)
        .spawn()
        .map_err(|err| SubtitleError::network(format!("invoking ffmpeg: {err}")))?;

    let status = match tokio::time::timeout(FFMPEG_TIMEOUT, child.wait()).await {
        Ok(Ok(status)) => status,
        Ok(Err(err)) => {
            return Err(SubtitleError::network(format!("waiting on ffmpeg: {err}")));
        }
        Err(_) => {
            // `kill_on_drop(true)` will reap the process when `child`
            // drops at the end of the function.
            return Err(SubtitleError::network(format!(
                "ffmpeg timed out after {}s extracting subtitle track {track_id}",
                FFMPEG_TIMEOUT.as_secs()
            )));
        }
    };

    if !status.success() {
        return Err(SubtitleError::network(format!("ffmpeg exited {status}")));
    }
    Ok(output)
}

/// Extract an embedded subtitle track to a cache path, with an atomic
/// `.tmp` -> rename so concurrent requests don't tear the file. The
/// caller resolves `cache_path` (typically via [`cache_path_for`]) so
/// the cache key strategy stays in one place; this fn just owns the
/// disk discipline.
///
/// Steps:
/// 1. If `cache_path` already exists, return it (fast cache-hit path).
/// 2. Otherwise create the parent directory and run ffmpeg against
///    `<cache_path>.tmp`.
/// 3. Rename `.tmp` to `cache_path` (atomic on POSIX same-filesystem).
///    Concurrent callers either find the file in step 1 or each write
///    independent `.tmp` files that swap themselves into place;
///    last-writer wins, which is fine for deterministic ffmpeg output.
pub async fn extract_to_cache(
    media_path: impl AsRef<Path>,
    track_id: i32,
    cache_path: impl AsRef<Path>,
    format: &str,
) -> Result<PathBuf, SubtitleError> {
    let cache_path = cache_path.as_ref().to_path_buf();
    if tokio::fs::metadata(&cache_path).await.is_ok() {
        return Ok(cache_path);
    }

    if let Some(parent) = cache_path.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(|err| {
            SubtitleError::network(format!(
                "creating subtitle cache dir {}: {err}",
                parent.display()
            ))
        })?;
    }

    let tmp_path = with_tmp_suffix(&cache_path);
    // Best-effort cleanup of any stale .tmp left by a prior failed run.
    let _ = tokio::fs::remove_file(&tmp_path).await;

    extract_embedded_track(media_path, track_id, &tmp_path, format).await?;

    // Renaming into place is atomic on POSIX same-filesystem; if a
    // concurrent caller already populated `cache_path`, this rename
    // overwrites it with an identical byte stream.
    tokio::fs::rename(&tmp_path, &cache_path)
        .await
        .map_err(|err| {
            // Failed rename means the .tmp is still on disk; remove it
            // so the next caller starts fresh.
            let tmp = tmp_path.clone();
            tokio::spawn(async move {
                let _ = tokio::fs::remove_file(&tmp).await;
            });
            SubtitleError::network(format!(
                "renaming subtitle cache file {} -> {}: {err}",
                tmp_path.display(),
                cache_path.display()
            ))
        })?;

    Ok(cache_path)
}

/// Resolve a deterministic cache path for an embedded track extraction.
/// Layout: `<base>/subtitles/<media_file_id>/<track_id>.<ext>`. The
/// caller (the REST handler) holds `WebState.generated_media_path` and
/// passes it here so the extractor stays config-free.
pub fn cache_path_for(base: &Path, media_file_id: &str, track_id: i32, format: &str) -> PathBuf {
    let ext = output_extension_for(format);
    base.join("subtitles")
        .join(media_file_id)
        .join(format!("{track_id}.{ext}"))
}

/// Normalize an ffprobe codec name to the format string the player
/// uses (`srt`, `vtt`, `ass`, `pgs`, …). Mirrors
/// `Mydia.Subtitles.Extractor.normalize_subtitle_format/1`.
#[must_use]
pub fn normalize_subtitle_format(codec: &str) -> &'static str {
    match codec {
        "subrip" | "srt" | "mov_text" => "srt",
        "ass" | "ssa" => "ass",
        "webvtt" | "vtt" => "vtt",
        "dvd_subtitle" => "vobsub",
        "hdmv_pgs_subtitle" => "pgs",
        _ => "unknown",
    }
}

/// File extension to use on disk for a given subtitle format. Keeps
/// the cache name self-describing so an operator inspecting
/// `priv/generated/subtitles/` sees `.srt` / `.vtt` / `.ass` files.
#[must_use]
pub fn output_extension_for(format: &str) -> &'static str {
    match format {
        "vtt" | "webvtt" => "vtt",
        "ass" | "ssa" => "ass",
        // Default to srt for unknown formats — matches ffmpeg's
        // fallback in `ffmpeg_codec_for`.
        _ => "srt",
    }
}

/// Content-Type for the subtitle file format. Used by the REST
/// handler when serving the cached file. Mirrors
/// `MydiaWeb.Api.Player.V1.SubtitleController.get_subtitle_mime_type/1`.
#[must_use]
pub fn content_type_for(format: &str) -> &'static str {
    match format {
        "vtt" | "webvtt" => "text/vtt; charset=utf-8",
        // Phoenix returns `text/plain` for srt/ass; mirror exactly so
        // the player sees the same content-type whether it hits the
        // Phoenix or the Rust backend.
        _ => "text/plain; charset=utf-8",
    }
}

fn ffmpeg_codec_for(format: &str) -> &'static str {
    match format {
        "srt" | "subrip" => "srt",
        "vtt" | "webvtt" => "webvtt",
        "ass" | "ssa" => "ass",
        other => {
            warn!(format = other, "unknown subtitle format, defaulting to srt");
            "srt"
        }
    }
}

fn with_tmp_suffix(path: &Path) -> PathBuf {
    let mut buf = path.as_os_str().to_owned();
    buf.push(".tmp");
    PathBuf::from(buf)
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

    #[test]
    fn cache_path_layout_is_per_media_file() {
        let base = PathBuf::from("/var/lib/mydia/generated");
        let path = cache_path_for(&base, "abc-123", 0, "srt");
        assert_eq!(
            path,
            PathBuf::from("/var/lib/mydia/generated/subtitles/abc-123/0.srt")
        );
    }

    #[test]
    fn cache_path_picks_extension_from_format() {
        let base = PathBuf::from("/cache");
        assert_eq!(
            cache_path_for(&base, "m", 2, "vtt"),
            PathBuf::from("/cache/subtitles/m/2.vtt")
        );
        assert_eq!(
            cache_path_for(&base, "m", 2, "ass"),
            PathBuf::from("/cache/subtitles/m/2.ass")
        );
        assert_eq!(
            cache_path_for(&base, "m", 2, "ssa"),
            PathBuf::from("/cache/subtitles/m/2.ass")
        );
        // Unknown format falls back to srt to match the ffmpeg codec
        // fallback in `ffmpeg_codec_for`.
        assert_eq!(
            cache_path_for(&base, "m", 2, "weirdformat"),
            PathBuf::from("/cache/subtitles/m/2.srt")
        );
    }

    #[test]
    fn normalize_codec_names() {
        assert_eq!(normalize_subtitle_format("subrip"), "srt");
        assert_eq!(normalize_subtitle_format("mov_text"), "srt");
        assert_eq!(normalize_subtitle_format("ass"), "ass");
        assert_eq!(normalize_subtitle_format("ssa"), "ass");
        assert_eq!(normalize_subtitle_format("webvtt"), "vtt");
        assert_eq!(normalize_subtitle_format("hdmv_pgs_subtitle"), "pgs");
        assert_eq!(normalize_subtitle_format("dvd_subtitle"), "vobsub");
        assert_eq!(normalize_subtitle_format("garbage"), "unknown");
    }

    #[test]
    fn content_type_for_known_formats() {
        assert_eq!(content_type_for("vtt"), "text/vtt; charset=utf-8");
        assert_eq!(content_type_for("webvtt"), "text/vtt; charset=utf-8");
        assert_eq!(content_type_for("srt"), "text/plain; charset=utf-8");
        assert_eq!(content_type_for("ass"), "text/plain; charset=utf-8");
        assert_eq!(content_type_for("unknown"), "text/plain; charset=utf-8");
    }

    #[tokio::test]
    async fn extract_to_cache_returns_existing_file_without_invoking_ffmpeg() {
        // Pre-populate a cache path; the extractor's fast path should
        // return it without shelling out — important because the test
        // env may not have ffmpeg, and we don't want this to be flaky.
        let tmp = tempfile::tempdir().expect("tempdir");
        let base = tmp.path();
        let cache_path = cache_path_for(base, "media-1", 0, "srt");
        tokio::fs::create_dir_all(cache_path.parent().unwrap())
            .await
            .expect("mkdir");
        tokio::fs::write(&cache_path, b"WEBVTT\n")
            .await
            .expect("seed cache");

        let result = extract_to_cache("/nonexistent.mkv", 0, &cache_path, "srt")
            .await
            .expect("cache hit returns path");
        assert_eq!(result, cache_path);

        let body = tokio::fs::read(&result).await.expect("read");
        assert_eq!(body, b"WEBVTT\n");
    }

    #[test]
    fn tmp_suffix_appends_to_full_filename() {
        // Important: it appends `.tmp` rather than swapping the extension
        // so the temp file is never picked up by a directory scan
        // looking for `.srt` / `.vtt` / `.ass`.
        assert_eq!(
            with_tmp_suffix(Path::new("/cache/m/0.srt")),
            PathBuf::from("/cache/m/0.srt.tmp")
        );
    }
}
