//! Subtitle files sitting next to a video.
//!
//! The Elixir server has no equivalent: its external subtitles come only from
//! the provider downloader, so a .srt beside a movie is invisible to it. This
//! is a deliberate superset. Slice 4's conformance corpus must be seeded
//! without sidecars, or the suite will report a divergence that is intended.

use std::path::Path;

/// Extensions carried, matching what the release-name tokenizer already knows
/// about (release_parser/tokenizer.ex:119).
const SUBTITLE_EXTENSIONS: &[&str] = &["srt", "ass", "ssa", "sub", "vtt"];

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Sidecar {
    pub path: String,
    /// ISO 639 code read off the filename, or "und" when the name carries
    /// none. Matches the fallback ffprobe tracks use.
    pub language: String,
    pub format: String,
}

/// Finds the subtitle files belonging to `video_path`.
///
/// A sidecar belongs to a video when its name is the video's stem, optionally
/// followed by a language segment: `Film.srt`, `Film.eng.srt`.
pub fn discover(video_path: &Path) -> Vec<Sidecar> {
    let (Some(dir), Some(stem)) = (video_path.parent(), video_path.file_stem()) else {
        return Vec::new();
    };

    let stem = stem.to_string_lossy().to_string();

    let Ok(entries) = std::fs::read_dir(dir) else {
        return Vec::new();
    };

    entries
        .flatten()
        .filter_map(|entry| {
            let path = entry.path();
            let name = path.file_name()?.to_string_lossy().to_string();

            let rest = name.strip_prefix(&stem)?.strip_prefix('.')?;
            let (language, format) = split_language(rest)?;

            Some(Sidecar {
                path: path.to_string_lossy().to_string(),
                language,
                format,
            })
        })
        .collect()
}

/// Splits the tail of a sidecar name into (language, format).
///
/// "srt" -> ("und", "srt"); "eng.srt" -> ("eng", "srt"). Anything with a tail
/// that is not a known subtitle extension is not a subtitle.
fn split_language(rest: &str) -> Option<(String, String)> {
    let known = |ext: &str| SUBTITLE_EXTENSIONS.contains(&ext.to_lowercase().as_str());

    match rest.rsplit_once('.') {
        Some((language, ext)) if known(ext) && !language.contains('.') => {
            Some((language.to_lowercase(), normalize(ext)))
        }
        None if known(rest) => Some(("und".to_string(), normalize(rest))),
        _ => None,
    }
}

/// ssa and ass are the same format, and the embedded path already collapses
/// them (ffprobe.rs normalize_subtitle_format).
fn normalize(ext: &str) -> String {
    match ext.to_lowercase().as_str() {
        "ssa" => "ass".to_string(),
        other => other.to_string(),
    }
}
