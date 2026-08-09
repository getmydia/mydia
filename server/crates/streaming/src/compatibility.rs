//! Port of lib/mydia/streaming/compatibility.ex.
//!
//! The model asks whether a *browser* could play a given container plus
//! codecs. Mydia Server's only client today is the native player, which can
//! play far more than that, but the candidate list this drives is compared
//! against the Elixir server field by field, so the answers have to match.
//!
//! Deliberately does not use any shared codec normalizer: compatibility.ex
//! does its own substring matching and a normalizer would change answers at
//! the edges.

use std::path::Path;

/// What has to happen before the bytes are playable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Mode {
    DirectPlay,
    NeedsRemux,
    NeedsTranscoding,
}

/// Port of check_compatibility/1 (compatibility.ex:43-58).
pub fn check(
    container: Option<&str>,
    video_codec: Option<&str>,
    audio_codec: Option<&str>,
) -> Mode {
    let video_ok = compatible_video(video_codec);
    let audio_ok = audio_compatible_or_absent(audio_codec);

    if compatible_container(container) && video_ok && audio_ok {
        Mode::DirectPlay
    } else if remuxable_container(container) && video_ok && audio_ok {
        Mode::NeedsRemux
    } else {
        Mode::NeedsTranscoding
    }
}

/// Port of get_container_format/1 (compatibility.ex:174-201).
///
/// The first two Elixir branches (metadata container, then the first segment
/// of format_name) both collapse into the stored `container` column, which
/// Slice 2a already normalizes the same way Elixir does
/// (ffprobe.rs:363-375 against file_analyzer.ex:305-314). What is left is the
/// extension fallback.
///
/// When a path is present but has no extension, Elixir returns "" (Path.extname
/// then trim/downcase), not "unknown". "unknown" is only for a nil absolute
/// path, which this API does not model.
pub fn container_format(container: Option<&str>, path: &str) -> String {
    if let Some(container) = container {
        return container.to_string();
    }

    Path::new(path)
        .extension()
        .and_then(|ext| ext.to_str())
        .map(|ext| ext.to_lowercase())
        .unwrap_or_default()
}

/// compatibility.ex:83-94.
fn compatible_container(container: Option<&str>) -> bool {
    matches!(
        container.map(str::to_lowercase).as_deref(),
        Some("mp4") | Some("webm") | Some("m4v")
    )
}

/// compatibility.ex:98-115.
fn remuxable_container(container: Option<&str>) -> bool {
    matches!(
        container.map(str::to_lowercase).as_deref(),
        Some("mkv")
            | Some("matroska")
            | Some("avi")
            | Some("mov")
            | Some("ts")
            | Some("mpegts")
            | Some("m2ts")
            | Some("mts")
            | Some("wmv")
            | Some("flv")
    )
}

/// compatibility.ex:118-148. HEVC is rejected by the catch-all; Elixir has an
/// explicit arm for it that returns the same answer.
fn compatible_video(codec: Option<&str>) -> bool {
    let Some(codec) = codec else { return false };
    let c = codec.to_lowercase();

    c.contains("h264")
        || c.contains("h.264")
        || c == "avc"
        || c == "avc1"
        || c.contains("vp9")
        || c == "vp09"
        || c.contains("av1")
        || c == "av01"
}

/// compatibility.ex:79-80.
fn audio_compatible_or_absent(codec: Option<&str>) -> bool {
    let Some(codec) = codec else { return true };
    let c = codec.to_lowercase();

    c.contains("aac") || c.contains("mp3") || c.contains("opus") || c.contains("vorbis")
}

#[cfg(test)]
mod tests {
    use super::{check, container_format, Mode};

    #[test]
    fn an_mp4_with_h264_and_aac_plays_directly() {
        assert_eq!(
            check(Some("mp4"), Some("H.264 (High)"), Some("AAC")),
            Mode::DirectPlay
        );
    }

    #[test]
    fn an_mkv_with_compatible_codecs_needs_a_remux() {
        // The codecs are fine; only the container is not.
        assert_eq!(
            check(Some("mkv"), Some("H.264 (High)"), Some("AAC")),
            Mode::NeedsRemux
        );
    }

    #[test]
    fn hevc_needs_transcoding_whatever_the_container() {
        assert_eq!(
            check(Some("mkv"), Some("HEVC (Main 10)"), Some("AAC")),
            Mode::NeedsTranscoding
        );
        assert_eq!(
            check(Some("mp4"), Some("HEVC (Main)"), Some("AAC")),
            Mode::NeedsTranscoding
        );
    }

    #[test]
    fn incompatible_audio_alone_forces_transcoding() {
        assert_eq!(
            check(Some("mkv"), Some("H.264 (High)"), Some("DTS-HD MA")),
            Mode::NeedsTranscoding
        );
    }

    #[test]
    fn a_video_with_no_audio_track_is_judged_on_its_video_alone() {
        // compatibility.ex:79 treats a nil audio codec as compatible.
        assert_eq!(
            check(Some("mp4"), Some("H.264 (High)"), None),
            Mode::DirectPlay
        );
        assert_eq!(
            check(Some("mkv"), Some("H.264 (High)"), None),
            Mode::NeedsRemux
        );
    }

    #[test]
    fn an_unknown_container_transcodes_rather_than_guessing() {
        assert_eq!(
            check(None, Some("H.264 (High)"), Some("AAC")),
            Mode::NeedsTranscoding
        );
        assert_eq!(
            check(Some("ogv"), Some("H.264 (High)"), Some("AAC")),
            Mode::NeedsTranscoding
        );
    }

    #[test]
    fn the_container_falls_back_to_the_file_extension() {
        // compatibility.ex:188-199. A file scanned before ffprobe recorded a
        // container still has a path. With a path but no extension, Elixir
        // returns "" (not "unknown"; that is only for a nil absolute path).
        assert_eq!(container_format(None, "/media/Some Film (2019).MKV"), "mkv");
        assert_eq!(container_format(Some("mp4"), "/media/whatever.mkv"), "mp4");
        assert_eq!(container_format(None, "/media/no-extension"), "");
    }
}
