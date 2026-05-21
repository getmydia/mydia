//! Progressive-MP4 transcoder. Rust port of
//! `lib/mydia/downloads/ffmpeg_mp4_transcoder.ex`.
//!
//! This is a different transcoder from U19's HLS transcoder — it
//! produces a **single fragmented MP4** that's playable before the
//! download completes (the `+frag_keyframe+empty_moov+default_base_moof`
//! movflags do the heavy lifting), used by the downloads flow for
//! pre-import quality previews and instant streaming on slow disks.
//!
//! ## Process management
//!
//! Spawn via `tokio::process::Command` with `kill_on_drop(true)` so
//! the child terminates when the parent task is cancelled. Hard
//! `tokio::time::timeout` around the whole `child.wait()` call
//! enforces an upper bound on transcode duration. The `-progress
//! pipe:2` flag streams machine-parseable counters that the caller
//! can consume — for U20 we expose the progress lines as an
//! `mpsc::Receiver` so the U17 worker can fan them out to
//! `mydia_rs_pubsub::topics::TRANSCODES`.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::mpsc;
use tracing::{debug, info, warn};

use crate::error::DownloadError;

/// Resolution preset. Mirrors Phoenix's `:p1080 | :p720 | :p480`
/// atoms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Resolution {
    P1080,
    P720,
    P480,
}

impl Resolution {
    /// (width, height) pair used in the `-s WxH` flag.
    #[must_use]
    pub fn dimensions(self) -> (u32, u32) {
        match self {
            Resolution::P1080 => (1920, 1080),
            Resolution::P720 => (1280, 720),
            Resolution::P480 => (854, 480),
        }
    }
}

/// Options controlling one transcode invocation. Built once per job
/// in the U17 worker; cloned into the transcoder so the
/// builder/runner split mirrors the Phoenix shape.
#[derive(Debug, Clone)]
pub struct TranscodeOptions {
    pub input_path: PathBuf,
    pub output_path: PathBuf,
    pub resolution: Resolution,
    pub preset: String,
    pub crf: u8,
    pub max_duration: Duration,
    pub ffmpeg_path: PathBuf,
}

impl TranscodeOptions {
    /// Build options with sensible defaults. `preset` mirrors Phoenix's
    /// `"medium"` and `crf` matches Phoenix's `23`.
    #[must_use]
    pub fn new(input_path: impl Into<PathBuf>, output_path: impl Into<PathBuf>) -> Self {
        Self {
            input_path: input_path.into(),
            output_path: output_path.into(),
            resolution: Resolution::P720,
            preset: "medium".to_owned(),
            crf: 23,
            // Two hours is generous; the queue cron worker enforces
            // shorter ceilings per job class.
            max_duration: Duration::from_secs(60 * 60 * 2),
            ffmpeg_path: PathBuf::from("ffmpeg"),
        }
    }
}

/// Single transcode runner. Holds the configuration; `run` spawns
/// `ffmpeg` and awaits completion or cancellation.
#[derive(Debug, Clone)]
pub struct Transcoder {
    options: TranscodeOptions,
}

impl Transcoder {
    /// Wrap an options bundle.
    #[must_use]
    pub fn new(options: TranscodeOptions) -> Self {
        Self { options }
    }

    /// Inspect the configuration.
    #[must_use]
    pub fn options(&self) -> &TranscodeOptions {
        &self.options
    }

    /// Spawn `ffmpeg` and return the handle plus a progress receiver.
    /// The caller is responsible for awaiting `wait` (or letting the
    /// handle drop, which kills the child via `kill_on_drop(true)`).
    pub async fn start(&self) -> Result<RunningTranscode, DownloadError> {
        ensure_parent_dir(&self.options.output_path).await?;

        let args = build_args(&self.options);
        debug!(args = ?args, "spawning progressive mp4 transcode");

        let mut child = Command::new(&self.options.ffmpeg_path)
            .args(&args)
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .stdin(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .map_err(|e| match e.kind() {
                std::io::ErrorKind::NotFound => DownloadError::FfmpegNotFound,
                _ => DownloadError::Internal(format!("ffmpeg spawn: {e}")),
            })?;

        info!(
            output = %self.options.output_path.display(),
            "ffmpeg progressive-mp4 transcode started"
        );

        let (tx, rx) = mpsc::channel(64);
        if let Some(stderr) = child.stderr.take() {
            tokio::spawn(parse_progress(stderr, tx.clone()));
        }
        if let Some(stdout) = child.stdout.take() {
            // FFmpeg writes `key=value` progress to whichever pipe
            // the `-progress` flag points to (pipe:2 = stderr by
            // default, but we keep stdout reader on standby for
            // operators who reroute it).
            tokio::spawn(forward_stdout(stdout));
        }
        Ok(RunningTranscode {
            child,
            progress_rx: rx,
            output_path: self.options.output_path.clone(),
            max_duration: self.options.max_duration,
        })
    }
}

/// Handle returned by [`Transcoder::start`]. Drop to cancel.
#[derive(Debug)]
pub struct RunningTranscode {
    child: Child,
    progress_rx: mpsc::Receiver<ProgressEvent>,
    output_path: PathBuf,
    max_duration: Duration,
}

impl RunningTranscode {
    /// Consume the handle and wait for `ffmpeg` to exit. Returns the
    /// path to the produced MP4 on success.
    pub async fn wait(mut self) -> Result<PathBuf, DownloadError> {
        let wait = self.child.wait();
        let status = tokio::time::timeout(self.max_duration, wait)
            .await
            .map_err(|_| {
                warn!(
                    output = %self.output_path.display(),
                    "ffmpeg progressive-mp4 transcode timed out"
                );
                DownloadError::FfmpegFailed {
                    status: -1,
                    stderr: "transcode exceeded max_duration".into(),
                }
            })?
            .map_err(|e| DownloadError::Internal(format!("ffmpeg wait: {e}")))?;
        if !status.success() {
            let code = status.code().unwrap_or(-1);
            return Err(DownloadError::FfmpegFailed {
                status: code,
                stderr: String::new(),
            });
        }
        Ok(self.output_path)
    }

    /// Stream progress events as `ffmpeg` reports them.
    pub fn progress(&mut self) -> &mut mpsc::Receiver<ProgressEvent> {
        &mut self.progress_rx
    }
}

/// One progress signal emitted by the parser.
#[derive(Debug, Clone, PartialEq)]
pub enum ProgressEvent {
    /// `Duration:` line — total media length in seconds (best-effort
    /// parse of `HH:MM:SS.ss`).
    Duration { seconds: f64 },
    /// `out_time_ms=` line — current encoded position in seconds.
    Position { seconds: f64 },
    /// Any other stderr line. Carried through so consumers can log
    /// without re-reading the pipe.
    Other(String),
}

async fn parse_progress(stderr: tokio::process::ChildStderr, tx: mpsc::Sender<ProgressEvent>) {
    let mut reader = BufReader::new(stderr).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        let event = if let Some(seconds) = parse_duration_line(&line) {
            ProgressEvent::Duration { seconds }
        } else if let Some(seconds) = parse_out_time(&line) {
            ProgressEvent::Position { seconds }
        } else {
            ProgressEvent::Other(line)
        };
        if tx.send(event).await.is_err() {
            // Consumer dropped — nothing left to forward.
            break;
        }
    }
}

async fn forward_stdout(stdout: tokio::process::ChildStdout) {
    let mut reader = BufReader::new(stdout).lines();
    while let Ok(Some(line)) = reader.next_line().await {
        debug!(stream = "stdout", "{line}");
    }
}

fn parse_duration_line(line: &str) -> Option<f64> {
    // FFmpeg writes `  Duration: 00:01:23.45, ...`
    let trimmed = line.trim_start();
    let rest = trimmed.strip_prefix("Duration: ")?;
    let timestamp = rest.split(',').next()?.trim();
    parse_hhmmss(timestamp)
}

fn parse_out_time(line: &str) -> Option<f64> {
    // `out_time_ms=12345678` — FFmpeg progress key-value lines.
    let trimmed = line.trim();
    let value = trimmed.strip_prefix("out_time_ms=")?;
    let micros: u64 = value.parse().ok()?;
    Some(micros as f64 / 1_000_000.0)
}

fn parse_hhmmss(ts: &str) -> Option<f64> {
    let mut parts = ts.split(':');
    let hours: u64 = parts.next()?.parse().ok()?;
    let minutes: u64 = parts.next()?.parse().ok()?;
    let seconds: f64 = parts.next()?.parse().ok()?;
    Some(hours as f64 * 3600.0 + minutes as f64 * 60.0 + seconds)
}

async fn ensure_parent_dir(path: &Path) -> Result<(), DownloadError> {
    if let Some(parent) = path.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|e| DownloadError::fs(parent.to_path_buf(), e))?;
    }
    Ok(())
}

fn build_args(options: &TranscodeOptions) -> Vec<String> {
    let (width, height) = options.resolution.dimensions();
    vec![
        "-i".into(),
        options.input_path.to_string_lossy().into_owned(),
        // Video
        "-c:v".into(),
        "libx264".into(),
        "-preset".into(),
        options.preset.clone(),
        "-crf".into(),
        options.crf.to_string(),
        "-pix_fmt".into(),
        "yuv420p".into(),
        "-profile:v".into(),
        "high".into(),
        "-s".into(),
        format!("{width}x{height}"),
        // Audio
        "-c:a".into(),
        "aac".into(),
        "-b:a".into(),
        "128k".into(),
        "-ar".into(),
        "48000".into(),
        "-ac".into(),
        "2".into(),
        // Progressive MP4
        "-movflags".into(),
        "+frag_keyframe+empty_moov+default_base_moof".into(),
        "-progress".into(),
        "pipe:2".into(),
        "-f".into(),
        "mp4".into(),
        "-loglevel".into(),
        "info".into(),
        "-y".into(), // overwrite existing output
        options.output_path.to_string_lossy().into_owned(),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    #[test]
    fn resolution_dimensions_match_phoenix() {
        assert_eq!(Resolution::P1080.dimensions(), (1920, 1080));
        assert_eq!(Resolution::P720.dimensions(), (1280, 720));
        assert_eq!(Resolution::P480.dimensions(), (854, 480));
    }

    #[test]
    fn args_include_progressive_movflags() {
        let opts = TranscodeOptions::new("/in.mkv", "/out/file.mp4");
        let args = build_args(&opts);
        let joined = args.join(" ");
        assert!(joined.contains("+frag_keyframe+empty_moov+default_base_moof"));
        assert!(joined.contains("-c:v libx264"));
        assert!(joined.contains("-c:a aac"));
        assert!(joined.contains("-s 1280x720"));
    }

    #[test]
    fn duration_parser_round_trips_known_format() {
        assert!(
            parse_duration_line("  Duration: 00:00:30.00, start: 0.000000").unwrap() - 30.0 < 0.001
        );
        assert!(parse_duration_line("not a duration line").is_none());
    }

    #[test]
    fn out_time_parser_converts_microseconds() {
        let seconds = parse_out_time("out_time_ms=1500000").unwrap();
        assert!((seconds - 1.5).abs() < 0.0001);
        assert!(parse_out_time("frame=42").is_none());
    }

    #[tokio::test]
    async fn ffmpeg_missing_surfaces_as_not_found() {
        let opts = TranscodeOptions {
            ffmpeg_path: PathBuf::from("/nonexistent/ffmpeg-binary"),
            ..TranscodeOptions::new("/tmp/in.mkv", "/tmp/out.mp4")
        };
        let err = Transcoder::new(opts).start().await.unwrap_err();
        assert!(matches!(err, DownloadError::FfmpegNotFound), "got {err:?}");
    }
}
