//! Real-time library-scanner progress channel.
//!
//! Phoenix publishes scan lifecycle on the `library_scanner` `PubSub`
//! topic with these message shapes (see
//! `lib/mydia/jobs/library_scanner.ex:200+` and the mirrors in
//! `mydia-rs-library`'s [`Scanner`] + `mydia-rs-jobs`'s
//! `library_scanner` worker):
//!
//! - `scan_started`     — `{ library_path_id, type }`
//! - `scan_progress`    — `{ library_path_id, stage, current, total }` (worker)
//! - `progress`         — `{ scan_id, path, files_found }` (scanner walker)
//! - `scan_completed`   — `{ library_path_id, type, new_files, modified_files, deleted_files }`
//! - `completed`        — `{ scan_id, path, files_found, errors }` (scanner walker)
//! - `scan_failed`      — `{ library_path_id, type?, error }`
//!
//! The page only cares about: which path is scanning, how far along
//! we are, and a terminal Completed/Failed flip. [`LibraryScanEvent`]
//! is the wire-friendly normalization the WebSocket server function
//! fans out — the JSON shape on the bus is intentionally tolerant
//! (every field `#[serde(default)]`) so an additive worker change
//! does not break the wire contract during the parallel window.
//!
//! ## Why a WebSocket
//!
//! Phoenix `LiveView`'s `phx-update="stream"` and `assign_async` give
//! you change-driven UI rerenders "for free." Dioxus 0.7 has no diff
//! protocol; you choose either typed `Websocket<In, Out, Enc>` or
//! Server-Sent Events. A WS is bidirectional (the page may
//! eventually send filter args back) and matches the GraphQL
//! subscription transport Phoenix uses elsewhere, so the cost of
//! plumbing it now once amortizes over the rest of Phase 4.

use dioxus::fullstack::ServerFnError;
use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
use dioxus::prelude::*;
use serde::{Deserialize, Serialize};

/// Normalized library-scanner event sent over the WebSocket to the UI.
///
/// `#[serde(tag = "event", rename_all = "snake_case")]` matches the
/// Phoenix worker's wire format (`scan_started` / `scan_progress` /
/// `scan_completed` / `scan_failed`) and the
/// [`mydia_rs_library::scanner::ScanProgressEvent`] tagged shape, so
/// the client can decode either source without bespoke conversion.
///
/// Unknown variants on the bus surface as decode errors at the WS
/// boundary, get logged, and dropped; the connection stays open — see
/// the server-side fan-out loop for the discipline. This keeps a
/// future additive event (e.g., `scan_warning`) from killing the
/// stream.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(tag = "event")]
pub enum LibraryScanEvent {
    /// Scan kicked off for a library path. `library_path_id` is the
    /// row ID; the worker emits this once per scan invocation.
    ///
    /// Tag aliases: `scan_started` from the Phoenix worker, `started`
    /// from `mydia_rs_library::scanner::ScanProgressEvent`. Outbound
    /// serialization uses `scan_started` so the page's WS frames stay
    /// readable as the Phoenix-side wire format.
    #[serde(rename = "scan_started", alias = "started")]
    Started {
        #[serde(default)]
        library_path_id: Option<String>,
        #[serde(default)]
        scan_id: Option<String>,
        #[serde(default, rename = "type")]
        kind: Option<String>,
        #[serde(default)]
        path: Option<String>,
    },

    /// Progress tick. The two source flavors disagree on field names —
    /// `current`/`total` from the worker batches, `files_found` from
    /// the scanner walker. We accept both and normalize: prefer
    /// `current`/`total` when present, fall back to `files_found`
    /// (with `total` unknown).
    #[serde(rename = "scan_progress", alias = "progress")]
    Progress {
        #[serde(default)]
        library_path_id: Option<String>,
        #[serde(default)]
        scan_id: Option<String>,
        #[serde(default)]
        stage: Option<String>,
        #[serde(default)]
        current: Option<u64>,
        #[serde(default)]
        total: Option<u64>,
        #[serde(default)]
        files_found: Option<u64>,
        #[serde(default)]
        path: Option<String>,
    },

    /// Terminal — scan finished successfully.
    #[serde(rename = "scan_completed", alias = "completed")]
    Completed {
        #[serde(default)]
        library_path_id: Option<String>,
        #[serde(default)]
        scan_id: Option<String>,
        #[serde(default, rename = "type")]
        kind: Option<String>,
        #[serde(default)]
        new_files: Option<u64>,
        #[serde(default)]
        modified_files: Option<u64>,
        #[serde(default)]
        deleted_files: Option<u64>,
        #[serde(default)]
        files_found: Option<u64>,
        #[serde(default)]
        errors: Option<u64>,
    },

    /// Terminal — scan errored out. The `error` field is operator-
    /// facing; the page may show it inline rather than spawning a
    /// toast so the failure stays attached to the path it belongs to.
    #[serde(rename = "scan_failed", alias = "failed")]
    Failed {
        #[serde(default)]
        library_path_id: Option<String>,
        #[serde(default)]
        scan_id: Option<String>,
        #[serde(default, rename = "type")]
        kind: Option<String>,
        #[serde(default)]
        error: Option<String>,
        #[serde(default)]
        reason: Option<String>,
    },
}

impl LibraryScanEvent {
    /// The library path this event belongs to, if any. Scanner-walker
    /// events carry only a `scan_id` and `path` — those won't have a
    /// `library_path_id` set until the worker boundary tags them.
    #[must_use]
    pub fn library_path_id(&self) -> Option<&str> {
        match self {
            Self::Started {
                library_path_id, ..
            }
            | Self::Progress {
                library_path_id, ..
            }
            | Self::Completed {
                library_path_id, ..
            }
            | Self::Failed {
                library_path_id, ..
            } => library_path_id.as_deref(),
        }
    }

    /// True when this event ends a scan (Completed or Failed).
    #[must_use]
    pub const fn is_terminal(&self) -> bool {
        matches!(self, Self::Completed { .. } | Self::Failed { .. })
    }
}

// ---------- WebSocket server function at module top level ----------

/// Server function handling the scan-progress WebSocket upgrade.
///
/// Dioxus convention: `#[get("/path")]` returning
/// `Result<Websocket<In, Out, Enc>, ServerFnError>`. The
/// `WebSocketOptions` extractor handles the upgrade; `.on_upgrade`
/// gives us a [`dioxus::fullstack::TypedWebsocket`] handle we drive
/// from a background task.
///
/// **In = `()`**: the client doesn't send anything; the page
/// subscribes once and reads. **Out = `LibraryScanEvent`** with JSON
/// encoding so a captured frame is readable in dev tools and matches
/// the rest of mydia-rs's JSON-on-the-wire discipline.
#[get("/api/realtime/library_scanner")]
pub async fn library_scanner_ws(
    ws: WebSocketOptions,
) -> Result<Websocket<(), LibraryScanEvent, JsonEncoding>, ServerFnError> {
    server::upgrade(ws).await
}

#[cfg(feature = "server")]
mod server {
    //! Server-only WebSocket plumbing. Kept inside a submodule so the
    //! wasm build doesn't see any of these imports.

    use super::LibraryScanEvent;
    use crate::server_state::WebState;
    use dioxus::fullstack::FullstackContext;
    use dioxus::fullstack::ServerFnError;
    use dioxus::fullstack::{JsonEncoding, WebSocketOptions, Websocket};
    use mydia_rs_pubsub::{topics, Pubsub};
    use tokio_stream::wrappers::{errors::BroadcastStreamRecvError, BroadcastStream};

    pub(super) async fn upgrade(
        ws: WebSocketOptions,
    ) -> Result<Websocket<(), LibraryScanEvent, JsonEncoding>, ServerFnError> {
        let pubsub = pubsub_from_ctx().await?;
        Ok(ws.on_upgrade(move |mut socket| async move {
            let receiver = pubsub.subscribe(topics::LIBRARY_SCANNER);
            tracing::info!("library scanner websocket connected");

            use futures::StreamExt as _;
            let mut stream = BroadcastStream::new(receiver);
            while let Some(msg) = stream.next().await {
                match msg {
                    Ok(event) => {
                        let normalized: LibraryScanEvent =
                            match serde_json::from_value(event.payload.clone()) {
                                Ok(v) => v,
                                Err(err) => {
                                    tracing::warn!(
                                        %err,
                                        raw = %event.payload,
                                        "library scanner WS dropped untyped event"
                                    );
                                    continue;
                                }
                            };
                        if socket.send(normalized).await.is_err() {
                            tracing::debug!("library scanner WS peer gone, closing");
                            break;
                        }
                    }
                    Err(BroadcastStreamRecvError::Lagged(n)) => {
                        tracing::warn!(skipped = n, "library scanner WS lagged");
                    }
                }
            }
            tracing::debug!("library scanner WS task ended");
        }))
    }

    async fn pubsub_from_ctx() -> Result<Pubsub, ServerFnError> {
        let ctx = FullstackContext::current()
            .ok_or_else(|| ServerFnError::new("no fullstack context".to_owned()))?;
        let state: WebState = ctx.extension::<WebState>().ok_or_else(|| {
            ServerFnError::new(
                "WebState axum extension missing — wire WebState::layer() in build_router()"
                    .to_owned(),
            )
        })?;
        Ok(state.pubsub.clone())
    }
}

// On the wasm target the macro substitutes the fn body with an HTTP
// upgrade fetch; the `server::upgrade(ws).await` call in the
// user-written body is placed inside `#[cfg(feature = "server")]` by
// the macro, so the wasm build never resolves the inner module.

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_phoenix_worker_scan_started() {
        let raw = serde_json::json!({
            "event": "scan_started",
            "library_path_id": "abc-uuid",
            "type": "movies",
        });
        let parsed: LibraryScanEvent = serde_json::from_value(raw).expect("decode");
        assert!(matches!(parsed, LibraryScanEvent::Started { .. }));
        assert_eq!(parsed.library_path_id(), Some("abc-uuid"));
        assert!(!parsed.is_terminal());
    }

    #[test]
    fn decodes_worker_progress_with_stage() {
        let raw = serde_json::json!({
            "event": "scan_progress",
            "library_path_id": "abc-uuid",
            "stage": "creating_files",
            "current": 42,
            "total": 100,
        });
        let parsed: LibraryScanEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            LibraryScanEvent::Progress {
                library_path_id,
                stage,
                current,
                total,
                ..
            } => {
                assert_eq!(library_path_id.as_deref(), Some("abc-uuid"));
                assert_eq!(stage.as_deref(), Some("creating_files"));
                assert_eq!(current, Some(42));
                assert_eq!(total, Some(100));
            }
            other => panic!("expected Progress, got {other:?}"),
        }
    }

    #[test]
    fn decodes_scanner_walker_progress() {
        let raw = serde_json::json!({
            "event": "progress",
            "scan_id": "ws-1",
            "path": "/movies",
            "files_found": 17,
        });
        let parsed: LibraryScanEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            LibraryScanEvent::Progress {
                scan_id,
                files_found,
                path,
                ..
            } => {
                assert_eq!(scan_id.as_deref(), Some("ws-1"));
                assert_eq!(files_found, Some(17));
                assert_eq!(path.as_deref(), Some("/movies"));
            }
            other => panic!("expected Progress, got {other:?}"),
        }
    }

    #[test]
    fn decodes_completed_terminal() {
        let raw = serde_json::json!({
            "event": "completed",
            "library_path_id": "abc-uuid",
            "files_found": 100,
            "errors": 0,
        });
        let parsed: LibraryScanEvent = serde_json::from_value(raw).expect("decode");
        assert!(parsed.is_terminal());
    }

    #[test]
    fn decodes_scan_failed() {
        let raw = serde_json::json!({
            "event": "scan_failed",
            "library_path_id": "abc-uuid",
            "error": "permission denied",
        });
        let parsed: LibraryScanEvent = serde_json::from_value(raw).expect("decode");
        match parsed {
            LibraryScanEvent::Failed {
                library_path_id,
                error,
                ..
            } => {
                assert_eq!(library_path_id.as_deref(), Some("abc-uuid"));
                assert_eq!(error.as_deref(), Some("permission denied"));
            }
            other => panic!("expected Failed, got {other:?}"),
        }
    }
}
