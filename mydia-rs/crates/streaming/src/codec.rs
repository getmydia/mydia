//! Codec compatibility rules. Port of `lib/mydia/streaming/compatibility.ex`
//! and `lib/mydia/streaming/codec.ex`.
//!
//! Two layers:
//!
//! - **Normalization** ([`normalize_video_codec`] / [`normalize_audio_codec`])
//!   reduces a free-form codec string from `ffprobe` or a filename
//!   ("H.264 (High)", "x265", "AAC (LC)") to a canonical short form
//!   ("h264", "hevc", "aac").
//! - **Compatibility** ([`streaming_mode_for`]) classifies a media file
//!   as direct-play, remux-eligible, or transcode-required based on
//!   the container + normalized codecs.
//!
//! The container / codec lists below are deliberately copied verbatim
//! from the Phoenix sources so the parity-replay harness in U13 can
//! diff Rust vs. Elixir outputs without hand-translation drift.

use mydia_rs_models::MediaFile;
use regex::Regex;
use serde::{Deserialize, Serialize};

/// Coarse classification of a media file vs. the modern-browser baseline.
///
/// Matches the `:direct_play | :needs_remux | :needs_transcoding` atom
/// set from `Mydia.Streaming.Compatibility`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StreamingMode {
    /// Browser handles the container + codecs natively. No `ffmpeg`
    /// needed; serve the file directly.
    DirectPlay,
    /// Codecs are browser-friendly but the container isn't. Stream-copy
    /// to fragmented MP4 via `ffmpeg` (see [`crate::remuxer`]).
    NeedsRemux,
    /// At least one codec is incompatible. Full HLS transcode via
    /// `ffmpeg` (see [`crate::transcoder`]).
    NeedsTranscoding,
}

/// Containers browsers play directly via `<video>`.
const DIRECT_PLAY_CONTAINERS: &[&str] = &["mp4", "webm", "m4v"];

/// Containers that hold browser-friendly codecs but need a stream-copy
/// remux to fragmented MP4 before they play.
const REMUXABLE_CONTAINERS: &[&str] = &[
    "mkv", "matroska", "avi", "mov", "ts", "mpegts", "m2ts", "mts", "wmv", "flv",
];

/// Normalize a video codec string to its canonical short form. Returns
/// `None` for an empty / `None` input.
#[must_use]
pub fn normalize_video_codec(codec: Option<&str>) -> Option<String> {
    let codec = codec?.trim();
    if codec.is_empty() {
        return None;
    }
    Some(canonicalize(codec, video_codec_patterns()))
}

/// Normalize an audio codec string to its canonical short form. Returns
/// `None` for an empty / `None` input.
#[must_use]
pub fn normalize_audio_codec(codec: Option<&str>) -> Option<String> {
    let codec = codec?.trim();
    if codec.is_empty() {
        return None;
    }
    Some(canonicalize(codec, audio_codec_patterns()))
}

/// True if `codec` (after normalization) renders in modern browsers
/// without re-encoding.
#[must_use]
pub fn video_codec_compatible(codec: Option<&str>) -> bool {
    matches!(
        normalize_video_codec(codec).as_deref(),
        Some("h264" | "vp9" | "av1")
    )
}

/// True if `codec` (after normalization) is a browser-friendly audio
/// codec — or if there is no audio track at all.
#[must_use]
pub fn audio_codec_compatible(codec: Option<&str>) -> bool {
    match normalize_audio_codec(codec).as_deref() {
        None => true, // video-only files are fine
        Some(c) => matches!(c, "aac" | "mp3" | "opus" | "vorbis" | "flac"),
    }
}

/// True if the browser can play `container` natively.
#[must_use]
pub fn container_compatible(container: Option<&str>) -> bool {
    container.is_some_and(|c| {
        let lc = c.trim().to_ascii_lowercase();
        DIRECT_PLAY_CONTAINERS.contains(&lc.as_str())
    })
}

/// True if `container` can be stream-copied to fragmented MP4. Used
/// when codecs are already browser-friendly but the wrapping format
/// isn't (`mkv`, `avi`, ...).
#[must_use]
pub fn container_remuxable(container: Option<&str>) -> bool {
    container.is_some_and(|c| {
        let lc = c.trim().to_ascii_lowercase();
        REMUXABLE_CONTAINERS.contains(&lc.as_str())
    })
}

/// Classify a media file's playback strategy. The result drives
/// candidate selection in [`crate::candidates::resolve_strategy`].
#[must_use]
pub fn streaming_mode_for(media_file: &MediaFile) -> StreamingMode {
    let container = media_file_container(media_file);
    let video_codec = media_file.codec.as_deref();
    let audio_codec = media_file.audio_codec.as_deref();

    if container_compatible(container.as_deref())
        && video_codec_compatible(video_codec)
        && audio_codec_compatible(audio_codec)
    {
        return StreamingMode::DirectPlay;
    }

    if container_remuxable(container.as_deref())
        && video_codec_compatible(video_codec)
        && audio_codec_compatible(audio_codec)
    {
        return StreamingMode::NeedsRemux;
    }

    StreamingMode::NeedsTranscoding
}

/// Best-effort container extraction. Tries `metadata.container` first,
/// then `metadata.format_name`, then the file extension. Mirrors
/// `Mydia.Streaming.Compatibility.get_container_format/1`.
#[must_use]
pub fn media_file_container(media_file: &MediaFile) -> Option<String> {
    if let Some(metadata) = media_file.metadata.as_ref() {
        let payload = &metadata.0;
        if let Some(container) = payload.get("container").and_then(|v| v.as_str()) {
            if !container.is_empty() {
                return Some(container.to_string());
            }
        }
        if let Some(format) = payload.get("format_name").and_then(|v| v.as_str()) {
            if let Some(first) = format.split(',').next() {
                let first = first.trim();
                if !first.is_empty() {
                    return Some(first.to_string());
                }
            }
        }
    }

    media_file
        .path
        .as_deref()
        .or(media_file.relative_path.as_deref())
        .and_then(|p| {
            std::path::Path::new(p)
                .extension()
                .and_then(|e| e.to_str())
                .map(str::to_ascii_lowercase)
        })
}

// --- internal pattern matching -----------------------------------------------

fn canonicalize(input: &str, patterns: &[(Regex, &'static str)]) -> String {
    for (pattern, canonical) in patterns {
        if pattern.is_match(input) {
            return (*canonical).to_string();
        }
    }
    input.to_ascii_lowercase()
}

// `LazyLock` would be cleaner but pedantic-clippy on MSRV 1.78 nags
// about it; building per-call is acceptable because the codec match
// path is not on the hot streaming loop.
fn video_codec_patterns() -> &'static [(Regex, &'static str)] {
    use std::sync::OnceLock;
    static PATTERNS: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        vec![
            (
                Regex::new(r"(?i)\b(?:hevc|h\.?265|x\.?265)\b").unwrap(),
                "hevc",
            ),
            (
                Regex::new(r"(?i)\b(?:h\.?264|x\.?264|avc1?)\b").unwrap(),
                "h264",
            ),
            (Regex::new(r"(?i)\bvp0?9\b").unwrap(), "vp9"),
            (Regex::new(r"(?i)\bav0?1\b").unwrap(), "av1"),
            (
                Regex::new(r"(?i)\b(?:mpeg-?4|xvid|divx)\b").unwrap(),
                "mpeg4",
            ),
            (Regex::new(r"(?i)\bwmv[23]?\b").unwrap(), "wmv3"),
            (Regex::new(r"(?i)\bvp0?8\b").unwrap(), "vp8"),
            (Regex::new(r"(?i)\bmpeg-?2\b").unwrap(), "mpeg2"),
            (Regex::new(r"(?i)\bvc-?1\b").unwrap(), "vc1"),
            (Regex::new(r"(?i)\btheora\b").unwrap(), "theora"),
        ]
    })
}

fn audio_codec_patterns() -> &'static [(Regex, &'static str)] {
    use std::sync::OnceLock;
    static PATTERNS: OnceLock<Vec<(Regex, &'static str)>> = OnceLock::new();
    PATTERNS.get_or_init(|| {
        vec![
            (Regex::new(r"(?i)\b(?:truehd|mlp)\b").unwrap(), "truehd"),
            (
                Regex::new(r"(?i)\bdts[- ]?(?:hd|ma|x|hdma)\b").unwrap(),
                "dts-hd",
            ),
            (Regex::new(r"(?i)\bdts\b").unwrap(), "dts"),
            (Regex::new(r"(?i)\be-?ac-?3\b").unwrap(), "eac3"),
            (
                Regex::new(r"(?i)\b(?:ac-?3|dolby\s*digital|dd5?\.?1?)\b").unwrap(),
                "ac3",
            ),
            (Regex::new(r"(?i)\baac\b").unwrap(), "aac"),
            (Regex::new(r"(?i)\bmp3\b").unwrap(), "mp3"),
            (Regex::new(r"(?i)\bopus\b").unwrap(), "opus"),
            (Regex::new(r"(?i)\bvorbis\b").unwrap(), "vorbis"),
            (Regex::new(r"(?i)\bflac\b").unwrap(), "flac"),
            (Regex::new(r"(?i)\bpcm\b").unwrap(), "pcm"),
            (Regex::new(r"(?i)\balac\b").unwrap(), "alac"),
            (Regex::new(r"(?i)\bwma\b").unwrap(), "wma"),
        ]
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn normalize_h264_variants() {
        assert_eq!(
            normalize_video_codec(Some("H.264 (High)")).as_deref(),
            Some("h264")
        );
        assert_eq!(normalize_video_codec(Some("x264")).as_deref(), Some("h264"));
        assert_eq!(normalize_video_codec(Some("avc1")).as_deref(), Some("h264"));
        assert_eq!(normalize_video_codec(Some("avc")).as_deref(), Some("h264"));
    }

    #[test]
    fn normalize_hevc_variants() {
        assert_eq!(normalize_video_codec(Some("HEVC")).as_deref(), Some("hevc"));
        assert_eq!(
            normalize_video_codec(Some("h.265")).as_deref(),
            Some("hevc")
        );
        assert_eq!(normalize_video_codec(Some("x265")).as_deref(), Some("hevc"));
    }

    #[test]
    fn normalize_audio_variants() {
        assert_eq!(
            normalize_audio_codec(Some("AAC (LC)")).as_deref(),
            Some("aac")
        );
        assert_eq!(
            normalize_audio_codec(Some("DTS-HD MA")).as_deref(),
            Some("dts-hd")
        );
        assert_eq!(normalize_audio_codec(Some("ac3")).as_deref(), Some("ac3"));
        assert_eq!(
            normalize_audio_codec(Some("E-AC-3")).as_deref(),
            Some("eac3")
        );
    }

    #[test]
    fn empty_codec_inputs_return_none() {
        assert!(normalize_video_codec(None).is_none());
        assert!(normalize_video_codec(Some("")).is_none());
        assert!(normalize_audio_codec(Some("   ")).is_none());
    }

    #[test]
    fn video_codec_compat_table() {
        assert!(video_codec_compatible(Some("h264")));
        assert!(video_codec_compatible(Some("VP9")));
        assert!(video_codec_compatible(Some("av1")));
        assert!(!video_codec_compatible(Some("hevc")));
        assert!(!video_codec_compatible(Some("mpeg2")));
        assert!(!video_codec_compatible(None));
    }

    #[test]
    fn audio_codec_compat_table() {
        assert!(audio_codec_compatible(Some("aac")));
        assert!(audio_codec_compatible(Some("MP3")));
        assert!(audio_codec_compatible(Some("opus")));
        assert!(audio_codec_compatible(None)); // no audio is fine
        assert!(!audio_codec_compatible(Some("dts-hd")));
        assert!(!audio_codec_compatible(Some("truehd")));
        assert!(!audio_codec_compatible(Some("ac3")));
    }

    #[test]
    fn container_compat_table() {
        assert!(container_compatible(Some("mp4")));
        assert!(container_compatible(Some("WebM")));
        assert!(!container_compatible(Some("mkv")));
        assert!(!container_compatible(None));
        assert!(container_remuxable(Some("mkv")));
        assert!(container_remuxable(Some("avi")));
        assert!(!container_remuxable(Some("mp4")));
    }
}
