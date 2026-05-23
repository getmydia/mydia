//! Real-time downloads channel.
//!
//! Phoenix counterpart: `MydiaWeb.DownloadsLive.Index` subscribes to
//! the `"downloads"` Phoenix.PubSub topic; producers in
//! `lib/mydia/downloads/*.ex` publish `{:download_updated, id}` and
//! related tuples.
//!
//! The Rust port flips polarity (publisher in `crates/downloads/`,
//! consumer here) but keeps the wire shape topic-string-compatible
//! with the Phoenix bus so the parallel window stays honest.
//!
//! Each frame is a `DownloadEvent`. The UI treats every frame as a
//! "redisplay" signal, mirroring Phoenix's `handle_info({:download_updated,
//! _}, _) -> {:noreply, load_downloads(socket)}`.

use dioxus::fullstack::ServerFnError;
use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// One frame on the downloads WebSocket. Mirrors the Phoenix pubsub
/// envelope shape (`event` + `id` + optional `progress` + optional
/// `status`). Unknown variants fall through to `Other` so an additive
/// producer-side event doesn't tear the stream.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum DownloadEvent {
    /// New download added to the queue.
    Started {
        id: String,
        #[serde(default)]
        title: Option<String>,
    },
    /// Progress / status change on an existing download. The Phoenix
    /// `:download_updated` message carries no payload — the `LiveView`
    /// re-reads the row from the DB. The Rust version includes the
    /// optional progress/status fields so a quiet client can update
    /// the row in place without a re-fetch.
    Updated {
        id: String,
        #[serde(default)]
        progress: Option<f64>,
        #[serde(default)]
        status: Option<String>,
    },
    /// Download completed (Phoenix: `:download_completed`).
    Completed { id: String },
    /// Download failed (Phoenix: `:download_failed`).
    Failed {
        id: String,
        #[serde(default)]
        error: Option<String>,
    },
    /// Catch-all so an unknown `event` value doesn't fail decode.
    #[serde(other)]
    Other,
}

impl DownloadEvent {
    /// Pull the download id off whichever variant the frame is. Returns
    /// `None` for `Other`.
    #[must_use]
    pub fn id(&self) -> Option<&str> {
        match self {
            Self::Started { id, .. }
            | Self::Updated { id, .. }
            | Self::Completed { id }
            | Self::Failed { id, .. } => Some(id),
            Self::Other => None,
        }
    }
}

#[get("/api/realtime/downloads")]
pub async fn downloads_ws(
    ws: WebSocketOptions,
) -> Result<Websocket<(), DownloadEvent, JsonEncoding>, ServerFnError> {
    server::upgrade(ws).await
}

#[cfg(feature = "server")]
mod server {
    use super::DownloadEvent;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
    use mydia_rs_pubsub::{topics, Pubsub};
    use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};

    pub(super) async fn upgrade(
        ws: WebSocketOptions,
    ) -> Result<Websocket<(), DownloadEvent, JsonEncoding>, ServerFnError> {
        let pubsub = pubsub_from_ctx().await?;
        Ok(ws.on_upgrade(move |mut socket| async move {
            let receiver = pubsub.subscribe(topics::DOWNLOADS);
            tracing::info!("downloads websocket connected");

            use futures::StreamExt as _;
            let mut stream = BroadcastStream::new(receiver);
            while let Some(msg) = stream.next().await {
                match msg {
                    Ok(event) => {
                        let normalized: DownloadEvent =
                            match serde_json::from_value(event.payload.clone()) {
                                Ok(v) => v,
                                Err(err) => {
                                    tracing::warn!(
                                        %err,
                                        raw = %event.payload,
                                        "downloads WS dropped untyped event"
                                    );
                                    continue;
                                }
                            };
                        if socket.send(normalized).await.is_err() {
                            tracing::debug!("downloads WS peer gone, closing");
                            break;
                        }
                    }
                    Err(BroadcastStreamRecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "downloads WS lagged");
                    }
                }
            }
            tracing::debug!("downloads WS task ended");
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
    fn started_event_round_trips() {
        let raw = serde_json::json!({"event": "started", "id": "d1", "title": "S01E01.mkv"});
        let parsed: DownloadEvent = serde_json::from_value(raw).expect("decode");
        assert!(matches!(parsed, DownloadEvent::Started { .. }));
        assert_eq!(parsed.id(), Some("d1"));
    }

    #[test]
    fn updated_event_carries_progress() {
        let raw = serde_json::json!({"event": "updated", "id": "d2", "progress": 0.5, "status": "downloading"});
        let parsed: DownloadEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            DownloadEvent::Updated {
                progress, status, ..
            } => {
                assert_eq!(progress, Some(0.5));
                assert_eq!(status.as_deref(), Some("downloading"));
            }
            _ => panic!("expected Updated"),
        }
    }

    #[test]
    fn unknown_event_decodes_as_other() {
        let raw = serde_json::json!({"event": "mystery", "id": "d3"});
        let parsed: DownloadEvent = serde_json::from_value(raw).expect("decode");
        assert!(matches!(parsed, DownloadEvent::Other));
        assert_eq!(parsed.id(), None);
    }
}
