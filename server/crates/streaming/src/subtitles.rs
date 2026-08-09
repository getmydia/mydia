//! Subtitle extraction and format conversion.
//!
//! ffmpeg's subtitle muxers seek in their output, so these write a temporary
//! file and read it back rather than piping. The temporary file lands in the
//! process temp directory, never beside the source: Mydia Server is read-only
//! on the library.

use std::process::Stdio;

use crate::StreamingError;

/// Converts a subtitle file on disk into `format`.
pub async fn convert(source: &str, format: &str) -> Result<Vec<u8>, StreamingError> {
    run(&["-i", source], source, format).await
}

/// Pulls one subtitle stream out of a video and converts it.
///
/// `stream_index` is the *global* ffprobe stream index, which is what Slice
/// 2a stored as the track id (ffprobe.rs subtitle_tracks) and what
/// extractor.ex:250 maps with.
pub async fn extract_embedded(
    video: &str,
    stream_index: &str,
    format: &str,
) -> Result<Vec<u8>, StreamingError> {
    let map = format!("0:{stream_index}");
    run(&["-i", video, "-map", &map], video, format).await
}

async fn run(args: &[&str], source: &str, format: &str) -> Result<Vec<u8>, StreamingError> {
    if !std::path::Path::new(source).exists() {
        return Err(StreamingError::Missing {
            path: source.to_string(),
        });
    }

    let dir = tempfile::tempdir().map_err(|e| StreamingError::Ffmpeg {
        path: source.to_string(),
        detail: format!("could not create a scratch directory: {e}"),
    })?;

    let out = dir.path().join(format!("subtitle.{format}"));
    // The contract and URL query use "vtt"; ffmpeg's muxer name is "webvtt".
    // Passing -f vtt fails with "Requested output format 'vtt' is not known".
    // Elixir's extractor.ex:253 passes the query value through unchanged, so
    // embedded VTT extraction is broken there too.
    let ffmpeg_format = match format {
        "vtt" => "webvtt",
        other => other,
    };

    let output = tokio::process::Command::new("ffmpeg")
        .args(["-v", "error", "-y"])
        .args(args)
        .args(["-f", ffmpeg_format])
        .arg(&out)
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .await
        .map_err(|e| StreamingError::FfmpegStart {
            path: source.to_string(),
            detail: format!("could not start ffmpeg: {e}. Is it installed?"),
        })?;

    if !output.status.success() {
        // Rule 3: carry the stderr tail, not a bare failure.
        let stderr = String::from_utf8_lossy(&output.stderr);
        // Last five lines, still in the order ffmpeg emitted them. Taking from
        // the reversed iterator without reversing back would report the tail
        // newest first, which reads backwards when ffmpeg emits a multi-line
        // failure. The remux drainer does the same thing.
        let tail: String = stderr
            .lines()
            .rev()
            .take(5)
            .collect::<Vec<_>>()
            .into_iter()
            .rev()
            .collect::<Vec<_>>()
            .join(" | ");

        return Err(StreamingError::Ffmpeg {
            path: source.to_string(),
            detail: tail,
        });
    }

    tokio::fs::read(&out)
        .await
        .map_err(|e| StreamingError::Ffmpeg {
            path: source.to_string(),
            detail: format!("ffmpeg reported success but wrote nothing readable: {e}"),
        })
}
