//! Active-sessions registry. Tokio/dashmap replacement for
//! `Mydia.Streaming.HlsSessionSupervisor` (a `DynamicSupervisor` +
//! `Registry` pair).
//!
//! The supervisor holds a `dashmap` keyed by `(media_file_id,
//! user_id)` — matching Phoenix's registry key — so two parallel
//! requests for the same file from the same user share a session
//! (idempotency). A second key by `session_id` provides O(1) lookup
//! by the player's session id.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use dashmap::DashMap;
use mydia_rs_db::types::UuidText;
use mydia_rs_models::MediaFile;
use mydia_rs_pubsub::Pubsub;
use tracing::{info, warn};
use uuid::Uuid;

use crate::candidates::{resolve_strategy, StreamingStrategy};
use crate::error::StreamingError;
use crate::remuxer::{start_remux, RemuxOptions};
use crate::session::{spawn as spawn_session, SessionConfig, SessionHandle, SessionMode};
use crate::transcoder::{start_transcode, TranscoderOptions};

/// Tunable knobs for the supervisor. Most callers stick with [`Self::default`].
#[derive(Debug, Clone)]
pub struct SupervisorConfig {
    /// Root temp directory for session segment dirs. Matches Phoenix's
    /// `/tmp/mydia-hls` default.
    pub temp_base_dir: PathBuf,
    /// Idle timeout applied to every spawned session unless overridden.
    pub idle_timeout: Duration,
    /// How often the per-session loop checks for idle. Production
    /// defaults to 30 seconds; tests usually shrink this.
    pub idle_check_interval: Duration,
    /// Path to the `ffmpeg` binary.
    pub ffmpeg_path: PathBuf,
}

impl Default for SupervisorConfig {
    fn default() -> Self {
        Self {
            temp_base_dir: PathBuf::from("/tmp/mydia-hls"),
            idle_timeout: crate::session::DEFAULT_IDLE_TIMEOUT,
            idle_check_interval: crate::session::DEFAULT_IDLE_CHECK_INTERVAL,
            ffmpeg_path: PathBuf::from("ffmpeg"),
        }
    }
}

/// Composite key matching Phoenix's `Registry` shape.
#[derive(Debug, Clone, Copy, Hash, PartialEq, Eq)]
struct RegistryKey {
    media_file_id: UuidText,
    user_id: UuidText,
}

/// The supervisor itself. Cheap to clone; internal state is shared
/// via `Arc<DashMap<...>>`.
#[derive(Clone)]
pub struct Supervisor {
    config: Arc<SupervisorConfig>,
    pubsub: Pubsub,
    by_key: Arc<DashMap<RegistryKey, SessionHandle>>,
    by_id: Arc<DashMap<Uuid, SessionHandle>>,
}

impl Supervisor {
    /// Build a new supervisor anchored at the given configuration.
    pub fn new(config: SupervisorConfig, pubsub: Pubsub) -> Self {
        Self {
            config: Arc::new(config),
            pubsub,
            by_key: Arc::new(DashMap::new()),
            by_id: Arc::new(DashMap::new()),
        }
    }

    /// Number of currently active sessions. Read by metrics callers.
    pub fn active_count(&self) -> usize {
        self.by_id.len()
    }

    /// Look up a session by its player-facing id.
    pub fn get(&self, session_id: Uuid) -> Option<SessionHandle> {
        self.by_id.get(&session_id).map(|entry| entry.clone())
    }

    /// Start a session for `media_file`. If a session for the same
    /// `(media_file_id, user_id)` pair already exists, returns it
    /// unchanged — matching Phoenix's `Registry`-keyed idempotency.
    pub async fn start_session(
        &self,
        media_file: &MediaFile,
        user_id: UuidText,
    ) -> Result<SessionHandle, StreamingError> {
        let key = RegistryKey {
            media_file_id: media_file.id,
            user_id,
        };

        if let Some(existing) = self.by_key.get(&key) {
            info!(
                session = %existing.session_id,
                "returning existing session for (media_file, user) pair"
            );
            return Ok(existing.clone());
        }

        let strategy = resolve_strategy(media_file);
        let mode = strategy_to_mode(strategy);

        let session_id = Uuid::new_v4();
        let temp_dir = self.config.temp_base_dir.join(session_id.to_string());

        let mut cfg = SessionConfig::new(media_file.id, user_id, mode, temp_dir.clone());
        cfg.session_id = session_id;
        cfg.idle_timeout = self.config.idle_timeout;
        cfg.idle_check_interval = self.config.idle_check_interval;

        let input_path = media_file.path.clone().map(PathBuf::from).ok_or_else(|| {
            StreamingError::InputNotReadable {
                path: PathBuf::new(),
            }
        })?;
        let ffmpeg_path = self.config.ffmpeg_path.clone();

        // Capture a clone of the MediaFile so the runner closure
        // doesn't borrow.
        let media_clone = media_file.clone();
        let session_mode = mode;
        let session_temp_dir = temp_dir.clone();

        let handle = spawn_session(cfg, self.pubsub.clone(), move |ctx| async move {
            match session_mode {
                SessionMode::DirectPlay => {
                    // Direct-play: nothing to do. Mark ready
                    // immediately and exit so the session loop falls
                    // into pure idle-timeout watching.
                    ctx.mark_ready();
                    Ok(())
                }
                SessionMode::Transcode => {
                    let mut opts = TranscoderOptions::new(input_path, session_temp_dir);
                    opts.ffmpeg_path = ffmpeg_path;
                    let mut result = start_transcode(&opts, Some(&media_clone)).await?;
                    ctx.mark_ready();
                    // Drive ffmpeg to completion. The
                    // session task can cancel us by dropping the
                    // outer task; `kill_on_drop(true)` reaps the
                    // child.
                    let status = result.child.wait().await.map_err(StreamingError::Spawn)?;
                    if !status.success() {
                        let code = status.code().unwrap_or(-1);
                        return Err(StreamingError::FfmpegFailed {
                            status: code,
                            stderr: String::new(),
                        });
                    }
                    Ok(())
                }
                SessionMode::Remux => {
                    let opts = RemuxOptions {
                        ffmpeg_path: Some(ffmpeg_path),
                        ..Default::default()
                    };
                    let mut result = start_remux(input_path, &opts)?;
                    ctx.mark_ready();
                    let status = result.child.wait().await.map_err(StreamingError::Spawn)?;
                    if !status.success() {
                        let code = status.code().unwrap_or(-1);
                        return Err(StreamingError::FfmpegFailed {
                            status: code,
                            stderr: String::new(),
                        });
                    }
                    Ok(())
                }
            }
        })
        .await?;

        // Insert into both indices. The clone is cheap (Arc internally).
        self.by_key.insert(key, handle.clone());
        self.by_id.insert(handle.session_id, handle.clone());

        // Spawn a watcher task that removes the entries when the
        // session ends. The supervisor can also call `stop_session`
        // explicitly; this is the lazy cleanup path.
        let by_key = self.by_key.clone();
        let by_id = self.by_id.clone();
        let mut watcher = handle.watch();
        let key_for_watch = key;
        let id_for_watch = handle.session_id;
        tokio::spawn(async move {
            while watcher.changed().await.is_ok() {
                if watcher.borrow().ended {
                    by_key.remove(&key_for_watch);
                    by_id.remove(&id_for_watch);
                    break;
                }
            }
        });

        Ok(handle)
    }

    /// Explicitly stop a session by id. Idempotent.
    pub async fn stop_session(&self, session_id: Uuid, reason: &str) {
        let handle = self.by_id.remove(&session_id).map(|(_, h)| h);
        if let Some(handle) = handle {
            self.by_key.remove(&RegistryKey {
                media_file_id: handle.media_file_id,
                user_id: handle.user_id,
            });
            if let Err(err) = handle.stop(reason).await {
                warn!(error = %err, "session stop reported error");
            }
        }
    }
}

fn strategy_to_mode(strategy: StreamingStrategy) -> SessionMode {
    match strategy {
        StreamingStrategy::DirectPlay => SessionMode::DirectPlay,
        StreamingStrategy::Remux => SessionMode::Remux,
        StreamingStrategy::HlsCopy | StreamingStrategy::Transcode => SessionMode::Transcode,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::test_support::media_file_fixture;

    #[tokio::test]
    async fn direct_play_session_is_idempotent_per_user() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = SupervisorConfig {
            temp_base_dir: tmp.path().to_path_buf(),
            idle_check_interval: Duration::from_millis(20),
            idle_timeout: Duration::from_millis(200),
            ..Default::default()
        };
        let supervisor = Supervisor::new(cfg, Pubsub::new());

        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = Some("aac".into());
        media.path = Some("/tmp/example.mp4".into());

        let user = UuidText::new_v4();
        let a = supervisor.start_session(&media, user).await.unwrap();
        let b = supervisor.start_session(&media, user).await.unwrap();
        assert_eq!(
            a.session_id, b.session_id,
            "same (media, user) reuses session"
        );
        assert_eq!(supervisor.active_count(), 1);

        supervisor.stop_session(a.session_id, "test").await;
        assert_eq!(supervisor.active_count(), 0);
    }

    #[tokio::test]
    async fn different_users_get_separate_sessions() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = SupervisorConfig {
            temp_base_dir: tmp.path().to_path_buf(),
            idle_check_interval: Duration::from_millis(20),
            ..Default::default()
        };
        let supervisor = Supervisor::new(cfg, Pubsub::new());

        let mut media = media_file_fixture();
        media.codec = Some("h264".into());
        media.audio_codec = Some("aac".into());
        media.path = Some("/tmp/example.mp4".into());

        let a = supervisor
            .start_session(&media, UuidText::new_v4())
            .await
            .unwrap();
        let b = supervisor
            .start_session(&media, UuidText::new_v4())
            .await
            .unwrap();
        assert_ne!(a.session_id, b.session_id);
        assert_eq!(supervisor.active_count(), 2);

        supervisor.stop_session(a.session_id, "test").await;
        supervisor.stop_session(b.session_id, "test").await;
    }

    #[test]
    fn strategy_to_mode_mapping() {
        assert_eq!(
            strategy_to_mode(StreamingStrategy::DirectPlay),
            SessionMode::DirectPlay
        );
        assert_eq!(
            strategy_to_mode(StreamingStrategy::Remux),
            SessionMode::Remux
        );
        assert_eq!(
            strategy_to_mode(StreamingStrategy::HlsCopy),
            SessionMode::Transcode
        );
        assert_eq!(
            strategy_to_mode(StreamingStrategy::Transcode),
            SessionMode::Transcode
        );
    }
}
