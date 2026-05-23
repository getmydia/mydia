//! Real-time transcode-progress channel.
//!
//! Phoenix counterpart: `MydiaWeb.TranscodesLive.Index` subscribes to
//! `Phoenix.PubSub.subscribe(Mydia.PubSub, "transcodes")` and reloads
//! the table on every `{:job_updated, _id}` message. The mydia-rs
//! transcoder publishes the same envelope on the
//! [`mydia_rs_pubsub::topics::TRANSCODES`] topic; this module
//! re-emits each frame to the page as a [`TranscodeEvent`].

use dioxus::fullstack::ServerFnError;
use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Normalized transcode lifecycle event. Phoenix publishes one of:
///
/// - `job_updated` (generic ping after status/progress writes)
/// - `job_started` / `job_completed` / `job_failed` (lifecycle)
///
/// The Rust transcoder uses the same wire format. Each variant
/// carries the `transcode_job_id`; the page re-fetches the row on
/// every event rather than diffing incrementally, mirroring
/// Phoenix's `load_jobs/1` reload.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "event")]
pub enum TranscodeEvent {
    #[serde(rename = "job_started", alias = "started")]
    Started {
        #[serde(default)]
        job_id: Option<String>,
    },
    #[serde(rename = "job_updated", alias = "updated", alias = "progress")]
    Updated {
        #[serde(default)]
        job_id: Option<String>,
        #[serde(default)]
        progress: Option<f64>,
        #[serde(default)]
        status: Option<String>,
    },
    #[serde(rename = "job_completed", alias = "completed")]
    Completed {
        #[serde(default)]
        job_id: Option<String>,
    },
    #[serde(rename = "job_failed", alias = "failed")]
    Failed {
        #[serde(default)]
        job_id: Option<String>,
        #[serde(default)]
        error: Option<String>,
    },
}

impl TranscodeEvent {
    /// Job id this event belongs to, if the wire payload included one.
    #[must_use]
    pub fn job_id(&self) -> Option<&str> {
        match self {
            Self::Started { job_id }
            | Self::Updated { job_id, .. }
            | Self::Completed { job_id }
            | Self::Failed { job_id, .. } => job_id.as_deref(),
        }
    }
}

#[get("/api/realtime/transcodes")]
pub async fn transcodes_ws(
    ws: WebSocketOptions,
) -> Result<Websocket<(), TranscodeEvent, JsonEncoding>, ServerFnError> {
    server::upgrade(ws).await
}

#[cfg(feature = "server")]
mod server {
    use super::TranscodeEvent;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
    use mydia_rs_pubsub::{topics, Pubsub};
    use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};

    pub(super) async fn upgrade(
        ws: WebSocketOptions,
    ) -> Result<Websocket<(), TranscodeEvent, JsonEncoding>, ServerFnError> {
        let pubsub = pubsub_from_ctx().await?;
        Ok(ws.on_upgrade(move |mut socket| async move {
            let receiver = pubsub.subscribe(topics::TRANSCODES);
            tracing::info!("transcodes websocket connected");

            use futures::StreamExt as _;
            let mut stream = BroadcastStream::new(receiver);
            while let Some(msg) = stream.next().await {
                match msg {
                    Ok(event) => {
                        let normalized: TranscodeEvent =
                            match serde_json::from_value(event.payload.clone()) {
                                Ok(v) => v,
                                Err(err) => {
                                    tracing::warn!(
                                        %err,
                                        raw = %event.payload,
                                        "transcodes WS dropped untyped event"
                                    );
                                    continue;
                                }
                            };
                        if socket.send(normalized).await.is_err() {
                            tracing::debug!("transcodes WS peer gone, closing");
                            break;
                        }
                    }
                    Err(BroadcastStreamRecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "transcodes WS lagged");
                    }
                }
            }
            tracing::debug!("transcodes WS task ended");
        }))
    }

    async fn pubsub_from_ctx() -> Result<Pubsub, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        let state: WebState = ctx.extension::<WebState>().ok_or_else(|| {
            ServerFnError::new(
                "WebState axum extension missing - wire WebState::layer() in build_router()"
                    .to_owned(),
            )
        })?;
        Ok(state.pubsub.clone())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_started_event() {
        let raw = serde_json::json!({
            "event": "job_started",
            "job_id": "abc-uuid",
        });
        let parsed: TranscodeEvent = serde_json::from_value(raw).expect("decode");
        assert!(matches!(parsed, TranscodeEvent::Started { .. }));
        assert_eq!(parsed.job_id(), Some("abc-uuid"));
    }

    #[test]
    fn decodes_progress_with_alias() {
        let raw = serde_json::json!({
            "event": "progress",
            "job_id": "xyz",
            "progress": 0.42_f64,
            "status": "transcoding",
        });
        let parsed: TranscodeEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            TranscodeEvent::Updated {
                progress, status, ..
            } => {
                assert!((progress.unwrap() - 0.42).abs() < 1e-9);
                assert_eq!(status.as_deref(), Some("transcoding"));
            }
            other => panic!("expected Updated, got {other:?}"),
        }
    }

    #[test]
    fn decodes_failed_with_error() {
        let raw = serde_json::json!({
            "event": "job_failed",
            "job_id": "xyz",
            "error": "ffmpeg crashed",
        });
        let parsed: TranscodeEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            TranscodeEvent::Failed { error, .. } => {
                assert_eq!(error.as_deref(), Some("ffmpeg crashed"));
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }
}
