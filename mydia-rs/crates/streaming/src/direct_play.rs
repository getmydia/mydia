//! Direct-play session tracking. Port of
//! `lib/mydia/streaming/direct_play_session.ex`.
//!
//! When the player picks the `DIRECT_PLAY` strategy, there is no
//! `ffmpeg` work to do — the browser fetches the original file by URL.
//! The backend still wants a session row so the unified "active
//! transcodes / streams" queue shows the playback in progress and so
//! the idle-timeout machinery can free up resources tied to the user.
//!
//! [`DirectPlaySession`] is a value-type description of that session;
//! the actual lifecycle (spawn, heartbeat, expiry) lives in
//! [`crate::session::Session`] which treats direct-play as one of the
//! three modes alongside transcode and remux.

use mydia_rs_db::types::UuidText;
use serde::{Deserialize, Serialize};
use uuid::Uuid;

/// Static parameters for a direct-play session. The supervisor passes
/// this into [`crate::session::SessionConfig`] when a candidate
/// resolves to `DIRECT_PLAY`.
#[derive(Debug, Clone)]
pub struct DirectPlayConfig {
    pub media_file_id: UuidText,
    pub user_id: UuidText,
}

/// Snapshot of an active direct-play session. Carries no I/O state —
/// the only resource the session holds is the `transcode_jobs` DB row
/// the supervisor writes on start and removes on terminate.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DirectPlaySession {
    pub session_id: Uuid,
    pub media_file_id: UuidText,
    pub user_id: UuidText,
}

impl DirectPlaySession {
    /// Build a new direct-play session record. The session id is a
    /// fresh UUID matching Phoenix's `Ecto.UUID.generate/0` site.
    #[must_use]
    pub fn new(config: &DirectPlayConfig) -> Self {
        Self {
            session_id: Uuid::new_v4(),
            media_file_id: config.media_file_id,
            user_id: config.user_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn new_session_has_unique_id() {
        let cfg = DirectPlayConfig {
            media_file_id: UuidText::new_v4(),
            user_id: UuidText::new_v4(),
        };
        let a = DirectPlaySession::new(&cfg);
        let b = DirectPlaySession::new(&cfg);
        assert_ne!(a.session_id, b.session_id);
        assert_eq!(a.media_file_id, b.media_file_id);
    }
}
