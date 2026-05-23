//! P2P server: Host wrapper + event loop + `spawn_blocking` discipline.
//!
//! This module owns the [`mydia_p2p_core::Host`] (which itself owns a
//! background OS-thread Tokio runtime) and translates inbound Host
//! events into dispatched requests via the [`crate::router::P2pRouter`]
//! trait.
//!
//! ## Lifecycle
//!
//! 1. [`Server::spawn`] constructs a [`mydia_p2p_core::Host`], records
//!    its node id, and starts an async task that drains the Host's
//!    event channel.
//! 2. The drain task consumes `Event` variants:
//!    - [`mydia_p2p_core::Event::Ready`] / `Connected` / `Disconnected`
//!      / `RelayConnected` update the [`ServerStatus`] cache.
//!    - [`mydia_p2p_core::Event::RequestReceived`] spawns a per-request
//!      task that calls into the router and sends the reply (via
//!      `spawn_blocking` around the Host's `send_response`).
//!    - [`mydia_p2p_core::Event::HlsStreamRequest`] spawns a per-request
//!      task that calls `P2pRouter::handle_hls_stream` and gives it an
//!      [`HlsStreamHandle`] for chunk delivery.
//!    - [`mydia_p2p_core::Event::Log`] forwards into `tracing`.
//! 3. [`ServerHandle::shutdown`] aborts the drain task and drops the
//!    Host. The Host's own iroh `Endpoint` is dropped synchronously
//!    from its thread (per the 1.0-rc-0 graceful-shutdown note in
//!    plan U19).
//!
//! ## Blocking-API discipline
//!
//! Every call into a blocking `Host` method (`get_node_addr`,
//! `get_network_stats`, `send_response`, `send_hls_header`,
//! `send_hls_chunk`, `finish_hls_stream`, `stream_file_range`,
//! `dial`) lives inside `tokio::task::spawn_blocking`. The blocking
//! method waits on `cmd_tx.blocking_send` + `rx.blocking_recv` which
//! would otherwise pin a tokio worker thread for the duration of the
//! Host's command round-trip.
//!
//! `Host::send_request` and `Host::send_hls_request` are already
//! async and return immediately when their oneshot reply completes;
//! we use them directly.

use std::sync::Arc;

use async_trait::async_trait;
use mydia_p2p_core::{Event, HlsResponseHeader, Host, HostConfig, NetworkStats};
use thiserror::Error;
use tokio::sync::RwLock;
use tokio::task::{spawn_blocking, JoinHandle};
use tracing::{debug, error, info, warn};

use crate::router::{
    self, HlsStreamHandle, HlsStreamHandleApi, P2pRouter, RoutedResponse, RouterContext,
};

/// Boot-time configuration for the p2p [`Server`]. Mirrors
/// `HostConfig` but lives here so the app crate doesn't need to
/// depend on `mydia_p2p_core` directly.
#[derive(Debug, Clone, Default)]
pub struct ServerConfig {
    pub relay_url: Option<String>,
    pub bind_port: Option<u16>,
    pub keypair_path: Option<String>,
}

impl ServerConfig {
    fn into_host_config(self) -> HostConfig {
        HostConfig {
            relay_url: self.relay_url,
            bind_port: self.bind_port,
            keypair_path: self.keypair_path,
        }
    }
}

/// Snapshot of the server's live state. Built by the drain loop from
/// `Event` updates and the Host's `get_network_stats` reply.
#[derive(Debug, Clone, Default)]
pub struct ServerStatus {
    pub node_id: String,
    pub node_addr: Option<String>,
    pub running: bool,
    pub connected_peers: usize,
    pub relay_connected: bool,
    pub relay_url: Option<String>,
    pub peer_connection_type: Option<String>,
}

#[derive(Debug, Error)]
pub enum ServerError {
    #[error("router rejected request: {0}")]
    Router(String),
    #[error("host call failed: {0}")]
    Host(String),
    #[error("server not running")]
    NotRunning,
}

/// The running p2p server. Holds the Host + the drain task. Drop
/// stops the drain task and tears down the Host.
pub struct Server {
    handle: ServerHandle,
    drain_task: JoinHandle<()>,
}

/// Cheap-to-clone handle to a running server. Used by callers that
/// need to read status, dial peers, or push responses without holding
/// the full `Server` struct.
#[derive(Clone)]
pub struct ServerHandle {
    inner: Arc<HandleInner>,
}

struct HandleInner {
    host: Arc<Host>,
    status: Arc<RwLock<ServerStatus>>,
    node_id: String,
}

impl Server {
    /// Boot the Host and spawn the event drain task.
    ///
    /// Returns the assembled [`Server`]. The caller keeps it for the
    /// duration of the process; dropping it stops the drain.
    pub fn spawn(config: ServerConfig, router: Arc<dyn P2pRouter>) -> Self {
        let (host, node_id) = Host::new(config.into_host_config());
        let host = Arc::new(host);

        let status = Arc::new(RwLock::new(ServerStatus {
            node_id: node_id.clone(),
            running: true,
            ..Default::default()
        }));

        let handle = ServerHandle {
            inner: Arc::new(HandleInner {
                host: host.clone(),
                status: status.clone(),
                node_id: node_id.clone(),
            }),
        };

        let drain_task = tokio::spawn(drain_events(host, status, router));

        Self { handle, drain_task }
    }

    /// Clone-able handle to the running server.
    pub fn handle(&self) -> ServerHandle {
        self.handle.clone()
    }

    /// Synchronously stop the drain task. The Host itself tears down
    /// when its `Arc` count reaches zero; the drain task holds the
    /// last reference, so aborting it triggers the Host's own
    /// graceful-shutdown path (the iroh Endpoint owns its close).
    pub async fn shutdown(self) {
        self.drain_task.abort();
        // Wait for the drain task to actually stop so any in-flight
        // request handlers get a chance to finish their reply (the
        // Host's `send_response` is the last thing they call). We
        // bound the wait so a runaway handler does not block the
        // process exit forever.
        let _ = tokio::time::timeout(std::time::Duration::from_secs(5), self.drain_task).await;
        info!("p2p server stopped");
    }
}

impl ServerHandle {
    pub fn node_id(&self) -> &str {
        &self.inner.node_id
    }

    /// Current status snapshot. Cheap (`RwLock` read).
    pub async fn status(&self) -> ServerStatus {
        self.inner.status.read().await.clone()
    }

    /// Get the Host's current `EndpointAddr` JSON, blocking-mode
    /// safe (wraps in `spawn_blocking`).
    pub async fn get_node_addr(&self) -> Result<String, ServerError> {
        let host = self.inner.host.clone();
        spawn_blocking(move || host.get_node_addr())
            .await
            .map_err(|err| ServerError::Host(err.to_string()))
    }

    /// Fetch network stats from the Host. Blocking-mode safe.
    pub async fn network_stats(&self) -> Result<NetworkStats, ServerError> {
        let host = self.inner.host.clone();
        spawn_blocking(move || host.get_network_stats())
            .await
            .map_err(|err| ServerError::Host(err.to_string()))
    }

    /// Dial a peer using its `EndpointAddr` JSON. Blocking-mode safe.
    pub async fn dial(&self, endpoint_addr_json: String) -> Result<(), ServerError> {
        let host = self.inner.host.clone();
        spawn_blocking(move || host.dial(endpoint_addr_json))
            .await
            .map_err(|err| ServerError::Host(err.to_string()))?
            .map_err(ServerError::Host)
    }
}

/// Drain Host events into the router. One task per process; running
/// for the lifetime of the [`Server`].
async fn drain_events(
    host: Arc<Host>,
    status: Arc<RwLock<ServerStatus>>,
    router: Arc<dyn P2pRouter>,
) {
    // Take ownership of the event channel via the Mutex on Host. The
    // Host hands out an `Arc<Mutex<mpsc::Receiver>>` so multiple
    // observers can poll the channel, but in practice only the
    // drain task pulls events.
    let event_rx = host.event_rx.clone();

    loop {
        // `lock().await` is a tokio Mutex (not std), so this awaits
        // without blocking the worker.
        let mut rx = event_rx.lock().await;
        let Some(event) = rx.recv().await else {
            // The Host has shut down; drop out.
            info!("p2p host event channel closed; drain loop exiting");
            let mut s = status.write().await;
            s.running = false;
            break;
        };
        // Drop the rx lock before processing so the next event can
        // arrive even while we spawn the handler.
        drop(rx);

        handle_event(&host, &status, &router, event).await;
    }
}

async fn handle_event(
    host: &Arc<Host>,
    status: &Arc<RwLock<ServerStatus>>,
    router: &Arc<dyn P2pRouter>,
    event: Event,
) {
    match event {
        Event::Ready { node_addr } => {
            info!(node_addr = %node_addr, "p2p host ready");
            let mut s = status.write().await;
            s.node_addr = Some(node_addr);
        }
        Event::RelayConnected => {
            info!("p2p relay connected");
            let mut s = status.write().await;
            s.relay_connected = true;
        }
        Event::Connected {
            peer_id,
            connection_type,
        } => {
            info!(peer = %peer_id, ?connection_type, "p2p peer connected");
            let mut s = status.write().await;
            s.connected_peers = s.connected_peers.saturating_add(1);
            s.peer_connection_type = Some(connection_type.as_str().to_string());
        }
        Event::ConnectionTypeChanged {
            peer_id,
            connection_type,
        } => {
            debug!(peer = %peer_id, ?connection_type, "p2p connection type changed");
            let mut s = status.write().await;
            s.peer_connection_type = Some(connection_type.as_str().to_string());
        }
        Event::Disconnected(peer_id) => {
            info!(peer = %peer_id, "p2p peer disconnected");
            let mut s = status.write().await;
            s.connected_peers = s.connected_peers.saturating_sub(1);
            if s.connected_peers == 0 {
                s.peer_connection_type = None;
            }
        }
        Event::RequestReceived {
            peer,
            request,
            request_id,
        } => {
            // One task per request so a slow handler doesn't block
            // the drain loop. The router + host are Arc, so cloning
            // is O(1).
            let router = router.clone();
            let host = host.clone();
            let peer_connection_type = status.read().await.peer_connection_type.clone();
            tokio::spawn(async move {
                let ctx = RouterContext {
                    peer_connection_type,
                };
                let response = match router::route(&router, request, ctx).await {
                    Ok(RoutedResponse::Reply(resp)) => resp,
                    Ok(RoutedResponse::Streamed) => {
                        // Shouldn't happen for RequestReceived events.
                        warn!(peer = %peer, "router returned Streamed for non-HLS request");
                        return;
                    }
                    Err(err) => {
                        warn!(peer = %peer, error = %err, "router error");
                        mydia_p2p_core::MydiaResponse::Error(err.to_string())
                    }
                };
                // send_response is blocking. wrap in spawn_blocking.
                let send = spawn_blocking(move || host.send_response(request_id, response)).await;
                if let Err(err) = send {
                    error!(error = %err, "spawn_blocking for send_response failed");
                } else if let Ok(Err(reason)) = send {
                    warn!(error = %reason, "send_response returned error");
                }
            });
        }
        Event::HlsStreamRequest {
            peer,
            request,
            stream_id,
        } => {
            let router = router.clone();
            let host = host.clone();
            let peer_connection_type = status.read().await.peer_connection_type.clone();
            tokio::spawn(async move {
                let ctx = RouterContext {
                    peer_connection_type,
                };
                let handle = HlsStreamHandle::new(Arc::new(HostHlsStream {
                    host: host.clone(),
                    stream_id: stream_id.clone(),
                }));
                if let Err(err) = router
                    .handle_hls_stream(request, stream_id.clone(), handle, ctx)
                    .await
                {
                    warn!(peer = %peer, error = %err, stream = %stream_id, "router HLS error");
                    // Best-effort: send a 500 header + empty body so
                    // the client doesn't hang. Wrapped in
                    // spawn_blocking because the Host calls are
                    // blocking.
                    let host_clone = host.clone();
                    let stream_id_clone = stream_id.clone();
                    let _ = spawn_blocking(move || {
                        let header = HlsResponseHeader {
                            status: 500,
                            content_type: "text/plain".to_string(),
                            content_length: 0,
                            content_range: None,
                            cache_control: None,
                        };
                        let _ = host_clone.send_hls_header(stream_id_clone.clone(), header);
                        let _ = host_clone.finish_hls_stream(stream_id_clone);
                    })
                    .await;
                }
            });
        }
        Event::Log {
            level,
            target,
            message,
        } => {
            // Forward iroh's tracing through our subscriber. Use
            // module-level macros so the message respects the
            // RUST_LOG filter the operator set.
            forward_log(level, &target, &message);
        }
    }
}

fn forward_log(level: mydia_p2p_core::LogLevel, target: &str, message: &str) {
    match level {
        mydia_p2p_core::LogLevel::Trace => {
            tracing::trace!(target: "iroh", source = target, %message);
        }
        mydia_p2p_core::LogLevel::Debug => {
            tracing::debug!(target: "iroh", source = target, %message);
        }
        mydia_p2p_core::LogLevel::Info => {
            tracing::info!(target: "iroh", source = target, %message);
        }
        mydia_p2p_core::LogLevel::Warn => {
            tracing::warn!(target: "iroh", source = target, %message);
        }
        mydia_p2p_core::LogLevel::Error => {
            tracing::error!(target: "iroh", source = target, %message);
        }
    }
}

/// Implementation of [`HlsStreamHandleApi`] backed by a real
/// `mydia_p2p_core::Host`. All methods wrap the corresponding
/// blocking Host call in `tokio::task::spawn_blocking`.
struct HostHlsStream {
    host: Arc<Host>,
    stream_id: String,
}

#[async_trait]
impl HlsStreamHandleApi for HostHlsStream {
    async fn send_header(&self, header: HlsResponseHeader) -> Result<(), String> {
        let host = self.host.clone();
        let stream_id = self.stream_id.clone();
        spawn_blocking(move || host.send_hls_header(stream_id, header))
            .await
            .map_err(|err| err.to_string())?
    }

    async fn send_chunk(&self, data: Vec<u8>) -> Result<(), String> {
        let host = self.host.clone();
        let stream_id = self.stream_id.clone();
        spawn_blocking(move || host.send_hls_chunk(stream_id, data))
            .await
            .map_err(|err| err.to_string())?
    }

    async fn finish(&self) -> Result<(), String> {
        let host = self.host.clone();
        let stream_id = self.stream_id.clone();
        spawn_blocking(move || host.finish_hls_stream(stream_id))
            .await
            .map_err(|err| err.to_string())?
    }

    async fn stream_file_range(
        &self,
        file_path: String,
        offset: u64,
        length: u64,
    ) -> Result<(), String> {
        let host = self.host.clone();
        let stream_id = self.stream_id.clone();
        spawn_blocking(move || host.stream_file_range(stream_id, file_path, offset, length))
            .await
            .map_err(|err| err.to_string())?
    }
}

/// Defaults derived from the Phoenix `lib/mydia/p2p/server.ex:48` shape.
impl ServerConfig {
    pub fn from_environment_defaults() -> Self {
        Self {
            relay_url: std::env::var("IROH_RELAY_URL").ok(),
            bind_port: std::env::var("MYDIA_P2P_BIND_PORT")
                .ok()
                .and_then(|s| s.parse().ok()),
            keypair_path: std::env::var("MYDIA_P2P_KEYPAIR_PATH").ok(),
        }
    }
}
