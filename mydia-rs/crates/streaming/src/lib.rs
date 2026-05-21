//! HLS streaming session state machine plus the `FFmpeg`
//! transcoder / remuxer / direct-play implementations. Rust port of
//! `lib/mydia/streaming/`.
//!
//! ## Shape
//!
//! Phoenix runs one `GenServer` per active session under a
//! `DynamicSupervisor`, with a `Registry` for fast lookup by
//! `(media_file_id, user_id)`. mydia-rs flattens that to a single
//! [`supervisor::Supervisor`] holding a `dashmap` of
//! [`session::SessionHandle`]s — each entry owns a `tokio::task::JoinHandle`
//! plus an `mpsc` command channel to the per-session task.
//!
//! ## Per-session pipeline
//!
//! 1. The caller asks [`candidates::resolve_strategy`] which streaming
//!    candidate fits the requested media file's container + codec mix.
//! 2. The supervisor spawns a [`session::Session`] task for the chosen
//!    strategy ([`transcoder`] for HLS transcode, [`remuxer`] for
//!    fragmented-MP4 stream-copy, [`direct_play`] for a no-op tracking
//!    session).
//! 3. The task runs `ffmpeg` via `tokio::process::Command` with
//!    `kill_on_drop(true)` so the child terminates on session cancel.
//! 4. Heartbeats from the player keep the session alive; an idle
//!    timeout (default 30 minutes) cancels the task and removes the
//!    on-disk segment directory.
//!
//! ## Boot-time discipline
//!
//! [`cleanup::boot_cleanup`] sweeps the temp dir on backend startup
//! and removes session directories whose **on-disk mtime** is older
//! than the 24-hour staleness threshold (mirrors
//! `lib/mydia/streaming/hls_cleanup.ex:16`). The threshold uses
//! filesystem mtime rather than `transcode_jobs` row presence so the
//! cleanup is safe during the parallel cutover window — if Phoenix
//! served a session whose row mydia-rs doesn't know about, we still
//! preserve the directory until it ages out naturally.
//!
//! ## Scope boundary
//!
//! - This crate produces the building blocks. Axum HLS endpoints land
//!   in U33 (REST API surface).
//! - apalis worker wiring lands in U17. Sessions here are addressable
//!   directly from the GraphQL resolvers in U11.

pub mod candidates;
pub mod cleanup;
pub mod codec;
pub mod direct_play;
pub mod error;
pub mod remuxer;
pub mod session;
pub mod supervisor;
pub mod transcoder;

#[cfg(test)]
pub(crate) mod test_support;

pub use candidates::{
    build_streaming_candidates, resolve_strategy, StreamingCandidate, StreamingStrategy,
};
pub use cleanup::{boot_cleanup, BootCleanupReport, STALE_THRESHOLD_HOURS};
pub use codec::{
    audio_codec_compatible, container_compatible, normalize_audio_codec, normalize_video_codec,
    streaming_mode_for, video_codec_compatible, StreamingMode,
};
pub use direct_play::{DirectPlayConfig, DirectPlaySession};
pub use error::StreamingError;
pub use remuxer::{RemuxOptions, Remuxer};
pub use session::{SessionConfig, SessionHandle, SessionInfo, SessionMode};
pub use supervisor::{Supervisor, SupervisorConfig};
pub use transcoder::{TranscoderOptions, TranscoderResult};
