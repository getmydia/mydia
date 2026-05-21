//! `FFmpeg` HLS transcoder. Port of
//! `lib/mydia/streaming/ffmpeg_hls_transcoder.ex`.
//!
//! Spawns `ffmpeg` via `tokio::process::Command` with `kill_on_drop(true)`
//! so the child process terminates the moment the [`Transcoder`] future
//! is dropped — matching the U16 file-analyzer pattern. The transcode
//! emits a live HLS playlist (`index.m3u8`) plus numbered `.ts`
//! segments into the configured output directory.
//!
//! Phoenix's `GenServer.handle_info({port, {:data, _}})` lines that
//! parse the `-progress pipe:1` `ffmpeg` output do not have an
//! analog here yet — progress reporting lives in U17's
//! transcode-job worker.
//! This crate's job is to launch the process, wait for the first
//! playlist, and clean up on cancel.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use mydia_rs_models::MediaFile;
use tokio::process::{Child, Command};
use tokio::time::sleep;
use tracing::{debug, info, warn};

use crate::codec::{audio_codec_compatible, video_codec_compatible};
use crate::error::StreamingError;

/// Options controlling the `ffmpeg` invocation.
#[derive(Debug, Clone)]
pub struct TranscoderOptions {
    /// Input video path. Must be readable from inside the process.
    pub input_path: PathBuf,
    /// Output directory for `index.m3u8` and the `.ts` segments.
    pub output_dir: PathBuf,
    /// Optional bitrate cap in kbps. When set, forces a re-encode and
    /// uses ABR rate control matching the Phoenix `max_bitrate` path.
    pub max_bitrate_kbps: Option<u32>,
    /// Target output width in pixels (default `1280`).
    pub width: u32,
    /// Target output height in pixels (default `720`).
    pub height: u32,
    /// CRF used when not bitrate-capped (default `23`).
    pub crf: u8,
    /// `ffmpeg` preset (default `medium`).
    pub preset: String,
    /// Maximum time to wait for the first playlist to appear on disk
    /// before declaring the transcode stuck. Default 30 seconds.
    pub ready_timeout: Duration,
    /// Path to the `ffmpeg` binary. Defaults to `"ffmpeg"` so the
    /// shell `$PATH` is consulted.
    pub ffmpeg_path: PathBuf,
}

impl TranscoderOptions {
    /// Build a default options bundle anchored at the given input /
    /// output paths.
    pub fn new(input_path: impl Into<PathBuf>, output_dir: impl Into<PathBuf>) -> Self {
        Self {
            input_path: input_path.into(),
            output_dir: output_dir.into(),
            max_bitrate_kbps: None,
            width: 1280,
            height: 720,
            crf: 23,
            preset: "medium".to_string(),
            ready_timeout: Duration::from_secs(30),
            ffmpeg_path: PathBuf::from("ffmpeg"),
        }
    }
}

/// Result of launching and monitoring an `ffmpeg` transcode. Carries
/// the child handle so the supervisor can wait on it (or drop it to
/// cancel).
pub struct TranscoderResult {
    /// `tokio::process::Child` for the running `ffmpeg`. Dropping
    /// this struct kills the child via `kill_on_drop(true)`.
    pub child: Child,
    /// Path to the live HLS playlist `ffmpeg` is writing.
    pub playlist_path: PathBuf,
}

/// Spawn `ffmpeg`, wait for the first playlist file, and return the
/// running child plus the playlist path.
///
/// This is the only public entry point. The supervisor in
/// [`crate::supervisor`] owns the returned `Child` and is responsible
/// for awaiting `child.wait()` (or letting it drop) to release the
/// process.
pub async fn start_transcode(
    options: &TranscoderOptions,
    media_file: Option<&MediaFile>,
) -> Result<TranscoderResult, StreamingError> {
    ensure_output_dir(&options.output_dir).await?;

    let playlist_path = options.output_dir.join("index.m3u8");
    let args = build_args(options, media_file, &playlist_path);
    debug!(args = ?args, "spawning ffmpeg for HLS transcode");

    let child = Command::new(&options.ffmpeg_path)
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
        playlist = %playlist_path.display(),
        "ffmpeg transcode started"
    );

    wait_for_playlist(&playlist_path, options.ready_timeout).await?;

    Ok(TranscoderResult {
        child,
        playlist_path,
    })
}

async fn ensure_output_dir(dir: &Path) -> Result<(), StreamingError> {
    tokio::fs::create_dir_all(dir)
        .await
        .map_err(|e| StreamingError::fs(dir.to_path_buf(), e))
}

/// Polls the playlist path on disk until it exists or `timeout`
/// elapses. The poll interval matches Phoenix's 100ms cadence in
/// `handle_info(:check_playlist_ready, ...)`.
async fn wait_for_playlist(path: &Path, timeout: Duration) -> Result<(), StreamingError> {
    let deadline = Instant::now() + timeout;
    loop {
        if tokio::fs::metadata(path).await.is_ok() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            warn!(
                playlist = %path.display(),
                "ffmpeg ready timeout — playlist never appeared"
            );
            return Err(StreamingError::FfmpegReadyTimeout {
                seconds: timeout.as_secs(),
            });
        }
        sleep(Duration::from_millis(100)).await;
    }
}

const AUDIO_BITRATE_KBPS: u32 = 128;

fn build_args(
    options: &TranscoderOptions,
    media_file: Option<&MediaFile>,
    playlist_path: &Path,
) -> Vec<String> {
    let segment_pattern = options.output_dir.join("segment_%03d.ts");
    let force_transcode = options.max_bitrate_kbps.is_some();

    let video_codec = pick_video_codec(media_file, force_transcode);
    let audio_codec = pick_audio_codec(media_file);

    let mut args: Vec<String> = vec![
        "-i".to_string(),
        options.input_path.to_string_lossy().into_owned(),
    ];

    if video_codec == "copy" {
        args.push("-c:v".to_string());
        args.push("copy".to_string());
    } else {
        args.extend(
            [
                "-c:v",
                &video_codec,
                "-preset",
                &options.preset,
                "-pix_fmt",
                "yuv420p",
                "-profile:v",
                "high",
                "-s",
            ]
            .iter()
            .map(ToString::to_string),
        );
        args.push(format!("{}x{}", options.width, options.height));
        args.extend(["-g", "60", "-bf", "0"].iter().map(ToString::to_string));

        if let Some(cap) = options.max_bitrate_kbps {
            let video_kbps = cap.saturating_sub(AUDIO_BITRATE_KBPS).max(100);
            args.extend(
                [
                    "-b:v",
                    &format!("{video_kbps}k"),
                    "-maxrate",
                    &format!("{video_kbps}k"),
                    "-bufsize",
                    &format!("{}k", video_kbps * 2),
                ]
                .iter()
                .map(ToString::to_string),
            );
        } else {
            args.push("-crf".to_string());
            args.push(options.crf.to_string());
        }
    }

    if audio_codec == "copy" {
        args.push("-c:a".to_string());
        args.push("copy".to_string());
    } else {
        args.extend(
            [
                "-c:a",
                &audio_codec,
                "-b:a",
                &format!("{AUDIO_BITRATE_KBPS}k"),
                "-ar",
                "48000",
                "-ac",
                "2",
            ]
            .iter()
            .map(ToString::to_string),
        );
    }

    // Live-style playlist: omit `-hls_playlist_type` so segments are
    // appended as they're produced. Players (hls.js, native Safari)
    // poll for updates until `#EXT-X-ENDLIST` is appended at end.
    args.extend(
        [
            "-f",
            "hls",
            "-hls_time",
            "4",
            "-hls_list_size",
            "0",
            "-hls_segment_filename",
        ]
        .iter()
        .map(ToString::to_string),
    );
    args.push(segment_pattern.to_string_lossy().into_owned());
    args.extend(
        ["-progress", "pipe:1", "-loglevel", "info"]
            .iter()
            .map(ToString::to_string),
    );
    args.push(playlist_path.to_string_lossy().into_owned());

    args
}

fn pick_video_codec(media_file: Option<&MediaFile>, force_transcode: bool) -> String {
    if force_transcode {
        return "libx264".to_string();
    }
    match media_file {
        Some(mf) if video_codec_compatible(mf.codec.as_deref()) => "copy".to_string(),
        _ => "libx264".to_string(),
    }
}

fn pick_audio_codec(media_file: Option<&MediaFile>) -> String {
    match media_file {
        Some(mf) if audio_codec_compatible(mf.audio_codec.as_deref()) => {
            // No audio track at all → re-encode to AAC anyway so the
            // HLS output still has an audio rendition. Mirrors
            // Phoenix's `should_copy_audio?(nil) -> false`.
            if mf.audio_codec.is_none() {
                "aac".to_string()
            } else {
                "copy".to_string()
            }
        }
        _ => "aac".to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::media_file_fixture;

    #[test]
    fn args_use_copy_for_h264_aac() {
        let opts = TranscoderOptions::new("/tmp/in.mkv", "/tmp/out");
        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = Some("aac".into());
        let args = build_args(&opts, Some(&media), &PathBuf::from("/tmp/out/index.m3u8"));
        let joined = args.join(" ");
        assert!(joined.contains("-c:v copy"));
        assert!(joined.contains("-c:a copy"));
    }

    #[test]
    fn args_transcode_for_hevc() {
        let opts = TranscoderOptions::new("/tmp/in.mkv", "/tmp/out");
        let mut media = media_file_fixture();
        media.codec = Some("hevc".into());
        media.audio_codec = Some("aac".into());
        let args = build_args(&opts, Some(&media), &PathBuf::from("/tmp/out/index.m3u8"));
        let joined = args.join(" ");
        assert!(joined.contains("-c:v libx264"));
        assert!(joined.contains("-c:a copy"));
    }

    #[test]
    fn args_force_transcode_when_bitrate_capped() {
        let mut opts = TranscoderOptions::new("/tmp/in.mkv", "/tmp/out");
        opts.max_bitrate_kbps = Some(2_000);
        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        let args = build_args(&opts, Some(&media), &PathBuf::from("/tmp/out/index.m3u8"));
        let joined = args.join(" ");
        assert!(joined.contains("-c:v libx264"));
        // Audio bitrate budget subtracted from cap = 2000 - 128 = 1872
        assert!(joined.contains("-b:v 1872k"));
        assert!(joined.contains("-maxrate 1872k"));
    }

    #[test]
    fn args_use_aac_for_no_audio_track() {
        let opts = TranscoderOptions::new("/tmp/in.mkv", "/tmp/out");
        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = None;
        let args = build_args(&opts, Some(&media), &PathBuf::from("/tmp/out/index.m3u8"));
        let joined = args.join(" ");
        assert!(joined.contains("-c:a aac"));
    }

    #[tokio::test]
    async fn ready_timeout_when_playlist_never_appears() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("never-appears.m3u8");
        let result = wait_for_playlist(&path, Duration::from_millis(200)).await;
        assert!(matches!(
            result,
            Err(StreamingError::FfmpegReadyTimeout { .. })
        ));
    }

    #[tokio::test]
    async fn ready_returns_when_playlist_exists() {
        let tmp = tempfile::tempdir().unwrap();
        let path = tmp.path().join("now.m3u8");
        tokio::fs::write(&path, "#EXTM3U\n").await.unwrap();
        let result = wait_for_playlist(&path, Duration::from_secs(1)).await;
        assert!(result.is_ok());
    }
}
