//! ffprobe as a subprocess.
//!
//! The mapping functions below are ports of lib/mydia/library/file_analyzer.ex.
//! They must produce byte-identical strings, because the conformance suite
//! compares MediaFile.resolution, codec, audioCodec and hdrFormat between the
//! Elixir server and this one.

use std::path::Path;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::LibraryError;

/// Matches the Elixir default (file_analyzer.ex:59). Slow network mounts are
/// the reason this is generous.
const TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct SubtitleTrackFacts {
    pub track_id: String,
    pub language: String,
    pub title: String,
    pub format: String,
    pub embedded: bool,
}

#[derive(Debug, Clone, Default)]
pub struct FileFacts {
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    /// Dolby Vision profile (5, 7, 8, ...), when the DOVI record is present.
    pub dolby_vision_profile: Option<i64>,
    /// DV base-layer compatibility id: 1 = HDR10 base, 4 = HLG base, 0 = none.
    pub dolby_vision_bl_compat_id: Option<i64>,
    pub bitrate: Option<i64>,
    pub duration_seconds: Option<f64>,
    pub container: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub subtitle_tracks: Vec<SubtitleTrackFacts>,
}

/// Runs ffprobe and maps its JSON into the facts the player displays.
///
/// Blocking, and called from a blocking context inside the scan. Size is not
/// reported here: the walk already has it from stat, and re-stating would be
/// a second syscall for a number we hold.
pub fn probe(path: &Path) -> Result<FileFacts, LibraryError> {
    let output = run(path)?;

    let parsed: Value =
        serde_json::from_slice(&output).map_err(|e| LibraryError::FfprobeOutput {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;

    let empty = Vec::new();
    let streams = parsed
        .get("streams")
        .and_then(Value::as_array)
        .unwrap_or(&empty);

    let format = parsed.get("format");

    let video = streams.iter().find(|s| codec_type(s) == Some("video"));
    let audio = streams.iter().find(|s| codec_type(s) == Some("audio"));

    let width = video.and_then(|s| s.get("width")).and_then(Value::as_i64);
    let height = video.and_then(|s| s.get("height")).and_then(Value::as_i64);

    Ok(FileFacts {
        resolution: resolution_label(width, height),
        codec: video.and_then(video_codec),
        audio_codec: audio.and_then(audio_codec),
        hdr_format: video.and_then(hdr_format),
        dolby_vision_profile: video.and_then(dolby_vision_profile),
        dolby_vision_bl_compat_id: video.and_then(dolby_vision_bl_compat_id),
        bitrate: bitrate(video, format),
        duration_seconds: format
            .and_then(|f| f.get("duration"))
            .and_then(Value::as_str)
            .and_then(|d| d.parse::<f64>().ok()),
        container: format.and_then(container_name),
        width,
        height,
        subtitle_tracks: subtitle_tracks(streams),
    })
}

fn run(path: &Path) -> Result<Vec<u8>, LibraryError> {
    let mut child = std::process::Command::new("ffprobe")
        .args([
            "-v",
            "quiet",
            "-print_format",
            "json",
            "-show_format",
            "-show_streams",
        ])
        .arg(path)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .map_err(|e| LibraryError::Ffprobe {
            path: path.display().to_string(),
            detail: format!("could not start ffprobe: {e}. Is it installed?"),
        })?;

    let deadline = std::time::Instant::now() + TIMEOUT;

    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if std::time::Instant::now() >= deadline => {
                let _ = child.kill();

                return Err(LibraryError::Ffprobe {
                    path: path.display().to_string(),
                    detail: format!(
                        "ffprobe did not finish within {} seconds",
                        TIMEOUT.as_secs()
                    ),
                });
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
            Err(e) => {
                return Err(LibraryError::Ffprobe {
                    path: path.display().to_string(),
                    detail: e.to_string(),
                })
            }
        }
    }

    let output = child
        .wait_with_output()
        .map_err(|e| LibraryError::Ffprobe {
            path: path.display().to_string(),
            detail: e.to_string(),
        })?;

    if !output.status.success() || output.stdout.is_empty() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        let tail: String = stderr.lines().rev().take(3).collect::<Vec<_>>().join(" ");

        return Err(LibraryError::Ffprobe {
            path: path.display().to_string(),
            detail: if tail.is_empty() {
                "ffprobe produced no output".to_string()
            } else {
                tail
            },
        });
    }

    Ok(output.stdout)
}

fn codec_type(stream: &Value) -> Option<&str> {
    stream.get("codec_type").and_then(Value::as_str)
}

/// Port of file_analyzer.ex:318-387.
pub fn resolution_label(width: Option<i64>, height: Option<i64>) -> Option<String> {
    let height = height?;
    let effective = effective_height(width, height);

    let label = match effective {
        h if h >= 2000 => {
            if width.unwrap_or(0) >= 3800 {
                "4K".to_string()
            } else {
                "2160p".to_string()
            }
        }
        h if h >= 1400 => "1440p".to_string(),
        h if h >= 1000 => "1080p".to_string(),
        h if h >= 700 => "720p".to_string(),
        h if h >= 450 => "480p".to_string(),
        h if h >= 300 => "360p".to_string(),
        h => format!("{h}p"),
    };

    Some(label)
}

const STANDARD_HEIGHTS: &[i64] = &[2160, 1440, 1080, 720, 480, 360];
const HEIGHT_TOLERANCE: i64 = 24;

/// Cropped scope encodes keep the source width (1920x800) while trimming the
/// stored height. The encoded width is a fallback only when the stored height
/// is not already near a standard tier and the frame is landscape
/// (file_analyzer.ex:359-373's `width > height` guard), which leaves true
/// ultrawide sources such as 2560x1080 at their real tier and never
/// misreads a portrait video from its width.
fn effective_height(width: Option<i64>, height: i64) -> i64 {
    let Some(width) = width else {
        return height;
    };

    if width <= 0 || height <= 0 {
        return height;
    }

    let near_standard = STANDARD_HEIGHTS
        .iter()
        .any(|standard| (height - standard).abs() <= HEIGHT_TOLERANCE);

    if near_standard || width <= height {
        return height;
    }

    match width {
        w if w >= 3800 => 2160,
        w if w >= 2500 => 1440,
        w if w >= 1900 => 1080,
        w if w >= 1200 => 720,
        _ => height,
    }
}

/// Port of file_analyzer.ex's extract_video_codec (lines 389-441).
fn video_codec(stream: &Value) -> Option<String> {
    let name = stream.get("codec_name").and_then(Value::as_str)?;
    let profile = stream.get("profile").and_then(Value::as_str);
    let long_name = stream.get("codec_long_name").and_then(Value::as_str);

    let label = match name {
        "h264" => match profile {
            Some(profile) => format!("H.264 ({profile})"),
            None => "H.264".to_string(),
        },
        "hevc" => match profile {
            Some(profile) => format!("HEVC ({profile})"),
            None => "HEVC".to_string(),
        },
        "av1" => "AV1".to_string(),
        "vp9" => "VP9".to_string(),
        "vp8" => "VP8".to_string(),
        "mpeg2video" => "MPEG-2".to_string(),
        "mpeg4" => "MPEG-4".to_string(),
        "xvid" => "XviD".to_string(),
        "divx" => "DivX".to_string(),
        other => match long_name {
            Some(long) if !long.is_empty() => {
                long.split('/').next().unwrap_or(long).trim().to_string()
            }
            _ => other.to_uppercase(),
        },
    };

    Some(label)
}

/// Port of file_analyzer.ex's extract_audio_codec (lines 443-522). The codec
/// label and the channel label are joined with a space, and a missing channel
/// count leaves the codec alone.
fn audio_codec(stream: &Value) -> Option<String> {
    let name = stream.get("codec_name").and_then(Value::as_str)?;
    let profile = stream.get("profile").and_then(Value::as_str);
    let channels = stream.get("channels").and_then(Value::as_i64);

    let codec = match name {
        "aac" => match profile {
            Some(profile) if profile != "LC" => format!("AAC {profile}"),
            _ => "AAC".to_string(),
        },
        "ac3" => "AC3".to_string(),
        "eac3" => "DD+".to_string(),
        "dts" => match profile {
            Some(profile) if profile.contains("MA") => "DTS-HD MA".to_string(),
            Some(profile) if profile.contains("HR") => "DTS-HD HR".to_string(),
            Some(profile) if profile.contains('X') => "DTS:X".to_string(),
            _ => "DTS".to_string(),
        },
        "truehd" => match profile {
            Some(profile) if profile.contains("Atmos") => "TrueHD Atmos".to_string(),
            _ => "TrueHD".to_string(),
        },
        "flac" => "FLAC".to_string(),
        "opus" => "Opus".to_string(),
        "vorbis" => "Vorbis".to_string(),
        "mp3" => "MP3".to_string(),
        "pcm_s16le" => "PCM".to_string(),
        other => other.to_uppercase(),
    };

    let channel_label = match channels {
        Some(1) => Some("Mono".to_string()),
        Some(2) => Some("Stereo".to_string()),
        Some(6) => Some("5.1".to_string()),
        Some(8) => Some("7.1".to_string()),
        Some(n) => Some(format!("{n}ch")),
        None => None,
    };

    Some(match channel_label {
        Some(channels) => format!("{codec} {channels}"),
        None => codec,
    })
}

/// Mirrors Mydia.Library.Hdr.display/1 (lib/mydia/library/hdr.ex). The
/// transfer function determines the base and nothing else does -- a case on
/// distinct values, never an `in`-style list, because that is what made the
/// old Elixir HLG branch unreachable. Dolby Vision overrides the base via the
/// DOVI record's compatibility id, but that override lives entirely in
/// `Hdr.dv_base/3` and feeds Elixir's internal `base` field, which this crate
/// does not compute or expose. `display/1` itself gates only on whether
/// `dv_profile` is present (`Hdr.dolby_vision?/1`), unconditionally, before
/// ever consulting a base -- so every Dolby Vision variant, including profile
/// 5 (whose IPTPQc2 base layer is not HDR10-decodable even though it signals
/// smpte2084), reports "Dolby Vision" here too.
///
/// The old bt2020-primaries-means-HDR rule is deleted, not ported: wide gamut
/// without a PQ or HLG transfer is SDR with a wide gamut.
fn hdr_format(stream: &Value) -> Option<String> {
    if dolby_vision_profile(stream).is_some() {
        return Some("Dolby Vision".to_string());
    }

    match stream.get("color_transfer").and_then(Value::as_str) {
        // HDR10+ is per-frame SEI and never appears in stream-level ffprobe
        // output, so it is invisible here. The Elixir analyzer runs a second
        // frame-level probe to promote this to "HDR10+"; this crate does not
        // scan, so it reports "HDR10", which degrades correctly since HDR10+
        // is a superset of HDR10.
        Some("smpte2084") => Some("HDR10".to_string()),
        Some("arib-std-b67") => Some("HLG".to_string()),
        _ => None,
    }
}

/// A DOVI record is identified by the presence of `dv_profile`, not by
/// matching `side_data_type`'s string (which varies across ffmpeg builds),
/// mirroring `Hdr`'s private `dovi_record/1`.
fn dovi_record(stream: &Value) -> Option<&Value> {
    stream
        .get("side_data_list")
        .and_then(Value::as_array)?
        .iter()
        .find(|d| d.get("dv_profile").is_some())
}

fn dolby_vision_profile(stream: &Value) -> Option<i64> {
    dovi_record(stream)?
        .get("dv_profile")
        .and_then(Value::as_i64)
}

fn dolby_vision_bl_compat_id(stream: &Value) -> Option<i64> {
    dovi_record(stream)?
        .get("dv_bl_signal_compatibility_id")
        .and_then(Value::as_i64)
}

fn bitrate(video: Option<&Value>, format: Option<&Value>) -> Option<i64> {
    let read = |value: Option<&Value>| {
        value.and_then(|v| v.get("bit_rate")).and_then(|b| match b {
            Value::String(s) => s.parse::<i64>().ok(),
            Value::Number(n) => n.as_i64(),
            _ => None,
        })
    };

    read(video).or_else(|| read(format))
}

/// Port of file_analyzer.ex's extract_container / normalize_container_name
/// (lines 282-314). ffprobe reports comma-separated aliases (for example
/// `"mov,mp4,m4a,3gp,3g2,mj2"`); the first one is the canonical name before
/// the alias table collapses containers that share a demuxer.
fn container_name(format: &Value) -> Option<String> {
    let format_name = format.get("format_name").and_then(Value::as_str)?;
    let first = format_name.split(',').next()?.trim().to_lowercase();

    let normalized = match first.as_str() {
        "matroska" => "mkv",
        "mov" | "m4v" | "m4a" | "3gp" | "3g2" | "mj2" => "mp4",
        "mpegts" | "mpeg" => "ts",
        other => other,
    };

    Some(normalized.to_string())
}

/// Port of extractor.ex:180-187. ffprobe reports codec names ("subrip"); the
/// contract's SubtitleTrack.format carries format names ("srt").
fn normalize_subtitle_format(codec_name: &str) -> String {
    match codec_name {
        "subrip" => "srt",
        "ass" => "ass",
        "ssa" => "ass",
        "webvtt" => "vtt",
        "mov_text" => "srt",
        "dvd_subtitle" => "vobsub",
        "hdmv_pgs_subtitle" => "pgs",
        other => other,
    }
    .to_string()
}

/// Port of extractor.ex:210-233. Used only as the title fallback for a track
/// that carries no title tag. Unlisted codes are upcased, which is what the
/// Elixir catch-all clause does.
fn language_name(code: &str) -> String {
    match code {
        "eng" | "en" => "English",
        "spa" | "es" => "Spanish",
        "fra" | "fr" => "French",
        "deu" | "de" => "German",
        "ita" | "it" => "Italian",
        "por" | "pt" => "Portuguese",
        "jpn" | "ja" => "Japanese",
        "kor" | "ko" => "Korean",
        "chi" | "zh" => "Chinese",
        "rus" | "ru" => "Russian",
        "ara" | "ar" => "Arabic",
        "und" => "Unknown",
        other => return other.to_uppercase(),
    }
    .to_string()
}

fn subtitle_tracks(streams: &[Value]) -> Vec<SubtitleTrackFacts> {
    streams
        .iter()
        .filter(|s| codec_type(s) == Some("subtitle"))
        .map(|s| {
            let tags = s.get("tags");
            let tag = |name: &str| {
                tags.and_then(|t| t.get(name))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            };

            let index = s.get("index").and_then(Value::as_i64).unwrap_or(0);
            let language = tag("language").unwrap_or_else(|| "und".to_string());

            SubtitleTrackFacts {
                track_id: index.to_string(),
                title: tag("title").unwrap_or_else(|| language_name(&language)),
                language,
                format: normalize_subtitle_format(
                    s.get("codec_name")
                        .and_then(Value::as_str)
                        .unwrap_or("unknown"),
                ),
                embedded: true,
            }
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::{
        dolby_vision_bl_compat_id, dolby_vision_profile, hdr_format, probe, resolution_label,
    };
    use std::path::Path;
    use std::process::Command;

    /// Writes a short real video with ffmpeg. Returns None when ffmpeg is not
    /// on PATH, so the suite still runs on a machine without it.
    fn synthesize(dir: &Path, name: &str, size: &str, seconds: u32) -> Option<std::path::PathBuf> {
        let path = dir.join(name);

        let status = Command::new("ffmpeg")
            .args([
                "-v",
                "quiet",
                "-f",
                "lavfi",
                "-i",
                &format!("testsrc=size={size}:rate=24:duration={seconds}"),
                "-f",
                "lavfi",
                "-i",
                &format!("sine=frequency=440:duration={seconds}"),
                "-c:v",
                "libx264",
                "-c:a",
                "aac",
                "-pix_fmt",
                "yuv420p",
                "-y",
            ])
            .arg(&path)
            .status()
            .ok()?;

        status.success().then_some(path)
    }

    #[test]
    fn resolution_labels_match_the_elixir_analyzer() {
        assert_eq!(
            resolution_label(Some(3840), Some(2160)).as_deref(),
            Some("4K")
        );
        assert_eq!(
            resolution_label(Some(3000), Some(2160)).as_deref(),
            Some("2160p")
        );
        assert_eq!(
            resolution_label(Some(2560), Some(1440)).as_deref(),
            Some("1440p")
        );
        assert_eq!(
            resolution_label(Some(1920), Some(1080)).as_deref(),
            Some("1080p")
        );
        assert_eq!(
            resolution_label(Some(1280), Some(720)).as_deref(),
            Some("720p")
        );
        assert_eq!(
            resolution_label(Some(854), Some(480)).as_deref(),
            Some("480p")
        );
        assert_eq!(
            resolution_label(Some(640), Some(360)).as_deref(),
            Some("360p")
        );
        assert_eq!(resolution_label(None, None), None);
    }

    #[test]
    fn a_cropped_scope_encode_is_read_from_its_width() {
        // 1920x800 is a 1080p source with the black bars trimmed.
        assert_eq!(
            resolution_label(Some(1920), Some(800)).as_deref(),
            Some("1080p")
        );
        assert_eq!(
            resolution_label(Some(1280), Some(534)).as_deref(),
            Some("720p")
        );
    }

    #[test]
    fn a_true_ultrawide_source_keeps_its_own_tier() {
        // 2560x1080 really is 1080 tall, and 1080 is within 24 of a standard
        // tier, so the width fallback must not promote it to 1440p.
        assert_eq!(
            resolution_label(Some(2560), Some(1080)).as_deref(),
            Some("1080p")
        );
    }

    #[test]
    fn probing_a_real_file_reports_its_facts() {
        let dir = tempfile::tempdir().unwrap();

        let Some(path) = synthesize(dir.path(), "clip.mp4", "1280x720", 1) else {
            eprintln!("ffmpeg is not on PATH, skipping");
            return;
        };

        let facts = probe(&path).unwrap();

        assert_eq!(facts.resolution.as_deref(), Some("720p"));
        assert_eq!(facts.width, Some(1280));
        assert_eq!(facts.height, Some(720));
        // libx264's default profile is High, and Elixir emits the profile in
        // the label (file_analyzer.ex:396-398). Slice 2a asserted the
        // profile-less form and documented the divergence; this closes it.
        assert_eq!(facts.codec.as_deref(), Some("H.264 (High)"));
        assert!(facts
            .audio_codec
            .as_deref()
            .unwrap_or("")
            .starts_with("AAC"));
        assert_eq!(facts.hdr_format, None);
        assert!(facts.duration_seconds.unwrap_or(0.0) > 0.5);
        assert!(facts.subtitle_tracks.is_empty());
    }

    #[test]
    fn subtitle_formats_are_normalized_the_way_elixir_normalizes_them() {
        // Port of extractor.ex:180-187. ffprobe reports codec names; the
        // contract carries format names.
        assert_eq!(super::normalize_subtitle_format("subrip"), "srt");
        assert_eq!(super::normalize_subtitle_format("ass"), "ass");
        assert_eq!(super::normalize_subtitle_format("ssa"), "ass");
        assert_eq!(super::normalize_subtitle_format("webvtt"), "vtt");
        assert_eq!(super::normalize_subtitle_format("mov_text"), "srt");
        assert_eq!(super::normalize_subtitle_format("dvd_subtitle"), "vobsub");
        assert_eq!(super::normalize_subtitle_format("hdmv_pgs_subtitle"), "pgs");
        assert_eq!(
            super::normalize_subtitle_format("weird_thing"),
            "weird_thing"
        );
    }

    #[test]
    fn an_untitled_track_falls_back_to_its_language_name() {
        // Port of extractor.ex:168-169 plus format_language_name at :210-233.
        // Elixir answers "English", not "eng".
        assert_eq!(super::language_name("eng"), "English");
        assert_eq!(super::language_name("en"), "English");
        assert_eq!(super::language_name("por"), "Portuguese");
        assert_eq!(super::language_name("und"), "Unknown");
        // Unknown codes are upcased, not passed through.
        assert_eq!(super::language_name("nld"), "NLD");
    }

    #[test]
    fn probing_a_file_that_is_not_media_is_an_error() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("broken.mkv");
        std::fs::write(&path, b"this is not a container").unwrap();

        assert!(probe(&path).is_err());
    }

    #[test]
    fn probing_a_missing_file_is_an_error() {
        let dir = tempfile::tempdir().unwrap();

        assert!(probe(&dir.path().join("absent.mkv")).is_err());
    }

    // Guards against the shared-branch bug that made Mydia.Library.Hdr's HLG
    // branch unreachable before this file and Elixir's file_analyzer.ex were
    // both fixed together: a `matches!(transfer, Some("smpte2084") |
    // Some("arib-std-b67")) => HDR10` construct (or an `in` list doing the
    // same thing) always wins on the smpte2084 arm first, so HLG can never be
    // reached. See the "Fix round" section of this task's report for the
    // observed mutation failure.
    #[test]
    fn hlg_is_not_reported_as_hdr10() {
        let stream = serde_json::json!({ "color_transfer": "arib-std-b67" });
        assert_eq!(hdr_format(&stream).as_deref(), Some("HLG"));
    }

    #[test]
    fn smpte2084_is_reported_as_hdr10() {
        let stream = serde_json::json!({ "color_transfer": "smpte2084" });
        assert_eq!(hdr_format(&stream).as_deref(), Some("HDR10"));
    }

    // Guards against the deleted bt2020-primaries-means-HDR rule. Wide gamut
    // without a PQ or HLG transfer is SDR with a wide gamut, not HDR.
    #[test]
    fn wide_gamut_without_pq_or_hlg_is_sdr() {
        let stream = serde_json::json!({
            "color_primaries": "bt2020",
            "color_space": "bt2020nc"
        });
        assert_eq!(hdr_format(&stream), None);
    }

    #[test]
    fn a_stream_with_no_hdr_signal_at_all_is_none() {
        let stream = serde_json::json!({});
        assert_eq!(hdr_format(&stream), None);
        assert_eq!(dolby_vision_profile(&stream), None);
        assert_eq!(dolby_vision_bl_compat_id(&stream), None);
    }

    #[test]
    fn dolby_vision_reports_profile_and_compat_id() {
        let stream = serde_json::json!({
            "color_transfer": "smpte2084",
            "side_data_list": [{
                "side_data_type": "DOVI configuration record",
                "dv_profile": 8,
                "dv_bl_signal_compatibility_id": 1
            }]
        });

        assert_eq!(hdr_format(&stream).as_deref(), Some("Dolby Vision"));
        assert_eq!(dolby_vision_profile(&stream), Some(8));
        assert_eq!(dolby_vision_bl_compat_id(&stream), Some(1));
    }

    // A DOVI record is identified by the presence of `dv_profile`, not by
    // matching `side_data_type`'s string, which varies across ffmpeg builds.
    // This is the same convention as Mydia.Library.Hdr's private
    // `dovi_record/1`.
    #[test]
    fn a_dovi_record_is_identified_by_dv_profile_presence_not_the_type_string() {
        let stream = serde_json::json!({
            "color_transfer": "smpte2084",
            "side_data_list": [{
                "side_data_type": "some ffmpeg build's unexpected label",
                "dv_profile": 8,
                "dv_bl_signal_compatibility_id": 1
            }]
        });

        assert_eq!(hdr_format(&stream).as_deref(), Some("Dolby Vision"));
    }

    // Profile 5 has no display-compatible base layer (it is IPTPQc2, not
    // HDR10-decodable) even though the stream signals smpte2084 and even when
    // a malformed/unusual bl_compat_id of 1 (normally HDR10-compatible) is
    // also present. `Hdr.display/1` in lib/mydia/library/hdr.ex gates
    // unconditionally on `dv_profile`'s presence -- never on the bl_compat_id
    // -derived `base` -- so this crate's `hdr_format` must too: it must not
    // let a transfer- or compat-id-based check run ahead of the DV-presence
    // check and mislabel this as "HDR10". See this task's report for the
    // mutation that was run against this test.
    #[test]
    fn profile_5_with_an_hdr10_compatible_id_still_displays_as_dolby_vision() {
        let stream = serde_json::json!({
            "color_transfer": "smpte2084",
            "side_data_list": [{
                "dv_profile": 5,
                "dv_bl_signal_compatibility_id": 1
            }]
        });

        assert_eq!(hdr_format(&stream).as_deref(), Some("Dolby Vision"));
        assert_eq!(dolby_vision_profile(&stream), Some(5));
        assert_eq!(dolby_vision_bl_compat_id(&stream), Some(1));
    }
}
