//! Port of lib/mydia/streaming/ffmpeg_remuxer.ex.
//!
//! Stream copy into fragmented MP4, which is near-instant because no frame is
//! ever re-encoded. The movflags are what make it streamable: `empty_moov`
//! writes the header before any data exists, `frag_keyframe` starts a fragment
//! at every keyframe so a client can seek, and `default_base_moof` keeps the
//! fragment headers small.

use std::pin::Pin;
use std::process::Stdio;
use std::task::{Context, Poll};

use bytes::Bytes;
use futures_util::Stream;
use tokio::process::{Child, Command};
use tokio_util::io::ReaderStream;

use crate::StreamingError;

/// The bytes of a remux, and the process producing them.
///
/// Dropping this kills the child. That is the whole reason it is a struct
/// rather than a bare stream: a viewer who closes the player mid-film must not
/// leave ffmpeg copying into a socket nobody is reading.
pub struct RemuxStream {
    child: Child,
    stdout: ReaderStream<tokio::process::ChildStdout>,
}

impl RemuxStream {
    /// The OS process id, while the child is still running.
    pub fn child_id(&self) -> Option<u32> {
        self.child.id()
    }
}

impl Stream for RemuxStream {
    type Item = Result<Bytes, std::io::Error>;

    fn poll_next(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<Option<Self::Item>> {
        let this = self.get_mut();
        Pin::new(&mut this.stdout).poll_next(cx)
    }
}

impl Drop for RemuxStream {
    fn drop(&mut self) {
        // start_kill rather than kill: Drop cannot await, and the child is
        // reaped by the runtime once the signal lands.
        if let Err(error) = self.child.start_kill() {
            tracing::warn!(%error, "could not signal the remux child");
        }
    }
}

/// Starts an ffmpeg stream copy into fragmented MP4 on stdout.
///
/// `duration` is passed through as `-t` when known, which makes ffmpeg write a
/// correct duration into the moov atom. Without it a client sees the runtime
/// grow as it plays.
pub fn start(path: &str, duration: Option<f64>) -> Result<RemuxStream, StreamingError> {
    if !std::path::Path::new(path).exists() {
        return Err(StreamingError::Missing {
            path: path.to_string(),
        });
    }

    let mut command = Command::new("ffmpeg");
    command.args(["-i", path, "-c", "copy"]);

    if let Some(duration) = duration.filter(|d| *d > 0.0) {
        command.args(["-t", &duration.to_string()]);
    }

    command.args([
        "-movflags",
        "+frag_keyframe+empty_moov+default_base_moof",
        "-f",
        "mp4",
        "-loglevel",
        "error",
        "pipe:1",
    ]);

    let mut child = command
        .stdout(Stdio::piped())
        // Piped rather than merged into stdout: the Elixir version merges the
        // two (ffmpeg_remuxer.ex:212), which is safe for a Port but would
        // corrupt the mp4 here. Piped rather than null because a bare "remux
        // failed" is the least actionable bug report in this class of
        // software, which is rule 3 of the parent design.
        .stderr(Stdio::piped())
        .stdin(Stdio::null())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| StreamingError::FfmpegStart {
            path: path.to_string(),
            detail: format!("could not start ffmpeg: {e}. Is it installed?"),
        })?;

    let stdout = child.stdout.take().ok_or_else(|| StreamingError::Ffmpeg {
        path: path.to_string(),
        detail: "ffmpeg produced no stdout pipe".to_string(),
    })?;

    // Drain stderr in the background. It has to be drained whatever happens:
    // a full pipe would block ffmpeg forever, which looks like a stall rather
    // than a failure. With -loglevel error a healthy remux writes nothing, so
    // anything arriving here is worth logging.
    if let Some(stderr) = child.stderr.take() {
        let source = path.to_string();

        tokio::spawn(async move {
            use tokio::io::{AsyncBufReadExt, BufReader};

            // A ring of the last few lines rather than the whole stream. A
            // remux runs for as long as the viewer watches, so a file that
            // makes ffmpeg complain once per frame would otherwise grow this
            // buffer without bound for the sake of five lines we actually log.
            const KEEP: usize = 5;

            let mut lines = BufReader::new(stderr).lines();
            let mut tail: std::collections::VecDeque<String> = std::collections::VecDeque::new();

            while let Ok(Some(line)) = lines.next_line().await {
                if tail.len() == KEEP {
                    tail.pop_front();
                }
                tail.push_back(line);
            }

            if !tail.is_empty() {
                let detail = tail.into_iter().collect::<Vec<_>>().join(" | ");
                tracing::error!(path = %source, %detail, "ffmpeg reported a remux problem");
            }
        });
    }

    Ok(RemuxStream {
        child,
        stdout: ReaderStream::new(stdout),
    })
}
