//! Streaming session mutations — port of
//! `StreamingResolver.start_streaming_session/3` and
//! `end_streaming_session/3`.
//!
//! U11 stubs the HLS supervisor itself (lands in U19). The mutations
//! still establish the correct surface for the Flutter player:
//!
//! - `startStreamingSession(fileId, strategy, maxBitrate)` returns
//!   `{ sessionId, duration }`. `sessionId` is a freshly-generated
//!   UUID until U19 wires the real `Mydia.Streaming.HlsSession`;
//!   `duration` comes from `media_files.metadata.duration` when
//!   present, otherwise `None`.
//! - `endStreamingSession(sessionId)` returns `true` unconditionally —
//!   Phoenix's `Mydia.Streaming.HlsSessionRegistry` returns `true`
//!   even for already-terminated sessions, and we match that.
//!
//! The shape is pinned because it's load-bearing for the Flutter
//! player (see MEMORY note: "sessionId + duration, NOT hlsUrl").

use async_graphql::{Context, Object, ID};
use uuid::Uuid;

use crate::context::GraphqlAppState;
use crate::repos::media;
use crate::types::{StreamingSessionResult, StreamingStrategy};

#[derive(Default)]
pub struct StreamingMutations;

#[Object]
impl StreamingMutations {
    /// Start an HLS streaming session for a media file.
    async fn start_streaming_session(
        &self,
        ctx: &Context<'_>,
        file_id: ID,
        strategy: StreamingStrategy,
        max_bitrate: Option<i32>,
    ) -> async_graphql::Result<StreamingSessionResult> {
        ensure_authenticated(ctx)?;
        let state = ctx.data::<GraphqlAppState>()?;
        let file = media::get_media_file(&state.db, file_id.as_str())
            .await?
            .ok_or_else(|| async_graphql::Error::new("Media file not found"))?;

        // Stub: U19 calls into HlsSessionSupervisor.start_session and
        // returns a real session id. Until then, generate one so the
        // shape is correct and the parity replay harness can redact
        // it as ephemeral.
        let session_id = Uuid::new_v4().to_string();
        let _ = strategy.as_session_mode();
        let _ = max_bitrate;

        let duration = file
            .metadata
            .as_deref()
            .and_then(|s| serde_json::from_str::<serde_json::Value>(s).ok())
            .and_then(|m| m.get("duration").and_then(serde_json::Value::as_f64));

        Ok(StreamingSessionResult {
            session_id,
            duration,
        })
    }

    /// End an HLS streaming session. Returns `true` even for unknown
    /// session IDs (matches Phoenix's terminate-session behavior).
    async fn end_streaming_session(
        &self,
        ctx: &Context<'_>,
        session_id: String,
    ) -> async_graphql::Result<bool> {
        ensure_authenticated(ctx)?;
        // U19 looks up the session and stops it. Stub here returns
        // `true` so the client receives a successful response.
        let _ = session_id;
        Ok(true)
    }
}

fn ensure_authenticated(ctx: &Context<'_>) -> async_graphql::Result<()> {
    let request_ctx = ctx.data_opt::<crate::context::GraphqlRequestContext>();
    let is_authed = request_ctx.is_some_and(|r| r.current_user.is_some());
    if is_authed {
        Ok(())
    } else {
        Err(async_graphql::Error::new("Authentication required"))
    }
}
