//! Fragmented-MP4 stream-copy remuxer. Port of
//! `lib/mydia/streaming/ffmpeg_remuxer.ex`.
//!
//! Unlike the HLS transcoder, the remuxer never re-encodes — it
//! repackages the input streams into fragmented MP4 (`movflags` set to
//! `frag_keyframe+empty_moov+default_base_moof`) so the result starts
//! playing immediately and supports keyframe-granularity seeking.
//!
//! The remuxer writes to `ffmpeg`'s stdout (`pipe:1`) so the U33 axum
//! HLS controller can pipe it directly into a chunked HTTP response.
//! This crate only spawns the process and hands the [`Child`] back;
//! consumers stream the stdout themselves.

use std::path::PathBuf;
use std::process::Stdio;

use tokio::process::{Child, Command};
use tracing::{debug, info};

use crate::error::StreamingError;

/// Optional seek + duration for the remux. Both default to `None`.
#[derive(Debug, Clone, Default)]
pub struct RemuxOptions {
    /// Start position in seconds. When set, `ffmpeg` seeks the input
    /// to the closest keyframe (stream copy can't seek mid-GOP).
    pub seek_seconds: Option<f64>,
    /// Total duration. When provided, the `moov` atom carries the
    /// final duration so browsers don't show a growing scrub bar.
    pub duration_seconds: Option<f64>,
    /// Override the `ffmpeg` binary path.
    pub ffmpeg_path: Option<PathBuf>,
}

/// Handle to a running remux. The `Child`'s stdout carries the
/// fragmented MP4 stream — read it with `Child::stdout` and pipe to
/// the response body. Dropping the struct kills `ffmpeg`.
pub struct Remuxer {
    pub child: Child,
}

/// Spawn `ffmpeg` for a stream-copy fragmented MP4 remux.
pub fn start_remux(
    input_path: impl Into<PathBuf>,
    options: &RemuxOptions,
) -> Result<Remuxer, StreamingError> {
    let input_path = input_path.into();
    let ffmpeg_path = options
        .ffmpeg_path
        .clone()
        .unwrap_or_else(|| PathBuf::from("ffmpeg"));

    let args = build_args(&input_path, options);
    debug!(args = ?args, "spawning ffmpeg for fMP4 remux");

    let child = Command::new(&ffmpeg_path)
        .args(&args)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| match e.kind() {
            std::io::ErrorKind::NotFound => StreamingError::FfmpegNotFound,
            _ => StreamingError::Spawn(e),
        })?;

    info!(
        input = %input_path.display(),
        "ffmpeg remux started"
    );

    Ok(Remuxer { child })
}

fn build_args(input_path: &std::path::Path, opts: &RemuxOptions) -> Vec<String> {
    let mut args: Vec<String> = Vec::new();

    if let Some(seek) = opts.seek_seconds.filter(|s| *s > 0.0) {
        args.push("-ss".to_string());
        args.push(seek.to_string());
    }

    args.push("-i".to_string());
    args.push(input_path.to_string_lossy().into_owned());

    args.push("-c".to_string());
    args.push("copy".to_string());

    if let Some(duration) = opts.duration_seconds.filter(|d| *d > 0.0) {
        let effective = match opts.seek_seconds.filter(|s| *s > 0.0) {
            Some(seek) => (duration - seek).max(0.0),
            None => duration,
        };
        args.push("-t".to_string());
        args.push(effective.to_string());
    }

    args.extend(
        [
            "-movflags",
            "+frag_keyframe+empty_moov+default_base_moof",
            "-f",
            "mp4",
            "-loglevel",
            "error",
            "pipe:1",
        ]
        .iter()
        .map(ToString::to_string),
    );

    args
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::Path;

    #[test]
    fn args_include_movflags_for_fragmented_mp4() {
        let args = build_args(Path::new("/tmp/x.mkv"), &RemuxOptions::default());
        let joined = args.join(" ");
        assert!(joined.contains("-movflags +frag_keyframe+empty_moov+default_base_moof"));
        assert!(joined.contains("-c copy"));
        assert!(joined.ends_with("pipe:1"));
    }

    #[test]
    fn args_include_seek_when_set() {
        let opts = RemuxOptions {
            seek_seconds: Some(120.0),
            ..Default::default()
        };
        let args = build_args(Path::new("/tmp/x.mkv"), &opts);
        let joined = args.join(" ");
        assert!(joined.contains("-ss 120"));
    }

    #[test]
    fn args_subtract_seek_from_duration() {
        let opts = RemuxOptions {
            seek_seconds: Some(60.0),
            duration_seconds: Some(300.0),
            ..Default::default()
        };
        let args = build_args(Path::new("/tmp/x.mkv"), &opts);
        let idx = args.iter().position(|s| s == "-t").expect("-t arg present");
        assert_eq!(args[idx + 1], "240");
    }

    #[test]
    fn args_skip_seek_when_zero() {
        let opts = RemuxOptions {
            seek_seconds: Some(0.0),
            ..Default::default()
        };
        let args = build_args(Path::new("/tmp/x.mkv"), &opts);
        assert!(!args.iter().any(|s| s == "-ss"));
    }
}
