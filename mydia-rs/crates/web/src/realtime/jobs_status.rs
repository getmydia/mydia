//! Real-time job-status channel.
//!
//! Phoenix counterpart: `MydiaWeb.JobsLive.Index` subscribes to the
//! Oban telemetry via `:telemetry.attach/4` and converts each event
//! into a `handle_info({:job_completed, _worker}, socket)` message.
//! mydia-rs flips the polarity: the apalis telemetry handler in
//! [`mydia_rs_jobs::broadcaster`] publishes on the
//! [`mydia_rs_pubsub::topics::JOBS_STATUS`] topic, and this module
//! exposes the WebSocket upgrade that re-emits the wire-friendly
//! [`JobStatusEvent`] to the page.
//!
//! Wire shape matches the broadcaster's `{kind, worker_id, payload}`
//! envelope verbatim. Unknown `kind` values surface as `Other` so an
//! additive apalis event doesn't tear the stream.

use dioxus::fullstack::ServerFnError;
use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Normalized jobs-status event the WS server function fans out to
/// each connected admin page.
///
/// Fields mirror the [`mydia_rs_jobs::broadcaster`] envelope. The
/// payload is left as raw JSON because each `kind` carries a
/// different shape and the UI only renders a handful of summary
/// strings — no value in flattening that into 7 enum variants.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct JobStatusEvent {
    /// Phoenix-style status keyword: `start`, `engage`, `stop`,
    /// `exit`, `idle`, `exception`, `custom`. Unknown values are
    /// passed through; the UI renders them via the
    /// [`crate::components::admin::status_pill_class`] mapping.
    pub kind: String,
    /// apalis worker name (`library_scanner`, `transcode`, ...).
    #[serde(default)]
    pub worker_id: String,
    /// Optional payload (task id, error message, ...). Raw so the UI
    /// can pluck fields by key without a typed schema.
    #[serde(default)]
    pub payload: serde_json::Value,
}

/// WebSocket server function — admin Jobs page connects here on mount.
///
/// The page treats each frame as a "something changed, redisplay"
/// signal rather than rendering the event verbatim. That matches the
/// Phoenix `LiveView` behaviour where `handle_info({:job_completed,
/// _}, _)` just calls `load_job_history(reset: true)`.
#[get("/api/realtime/jobs_status")]
pub async fn jobs_status_ws(
    ws: WebSocketOptions,
) -> Result<Websocket<(), JobStatusEvent, JsonEncoding>, ServerFnError> {
    server::upgrade(ws).await
}

#[cfg(feature = "server")]
mod server {
    use super::JobStatusEvent;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
    use mydia_rs_pubsub::{topics, Pubsub};
    use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};

    pub(super) async fn upgrade(
        ws: WebSocketOptions,
    ) -> Result<Websocket<(), JobStatusEvent, JsonEncoding>, ServerFnError> {
        let pubsub = pubsub_from_ctx().await?;
        Ok(ws.on_upgrade(move |mut socket| async move {
            let receiver = pubsub.subscribe(topics::JOBS_STATUS);
            tracing::info!("jobs status websocket connected");

            use futures::StreamExt as _;
            let mut stream = BroadcastStream::new(receiver);
            while let Some(msg) = stream.next().await {
                match msg {
                    Ok(event) => {
                        let normalized: JobStatusEvent =
                            match serde_json::from_value(event.payload.clone()) {
                                Ok(v) => v,
                                Err(err) => {
                                    tracing::warn!(
                                        %err,
                                        raw = %event.payload,
                                        "jobs status WS dropped untyped event"
                                    );
                                    continue;
                                }
                            };
                        if socket.send(normalized).await.is_err() {
                            tracing::debug!("jobs status WS peer gone, closing");
                            break;
                        }
                    }
                    Err(BroadcastStreamRecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "jobs status WS lagged");
                    }
                }
            }
            tracing::debug!("jobs status WS task ended");
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
    fn decodes_broadcaster_envelope() {
        let raw = serde_json::json!({
            "kind": "start",
            "worker_id": "library_scanner",
            "payload": {},
        });
        let parsed: JobStatusEvent = serde_json::from_value(raw).expect("decode");
        assert_eq!(parsed.kind, "start");
        assert_eq!(parsed.worker_id, "library_scanner");
    }

    #[test]
    fn decodes_engage_with_task_id() {
        let raw = serde_json::json!({
            "kind": "engage",
            "worker_id": "transcode",
            "payload": { "task_id": "abc-uuid" },
        });
        let parsed: JobStatusEvent = serde_json::from_value(raw).expect("decode");
        assert_eq!(parsed.kind, "engage");
        assert_eq!(parsed.payload["task_id"], "abc-uuid");
    }
}
