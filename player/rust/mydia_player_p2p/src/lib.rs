mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use mydia_p2p_core::{Host, Event, MydiaRequest, MydiaResponse, PairingRequest, GraphQLRequest, HlsRequest, HlsRequester, HostConfig, PeerConnectionType};
use flutter_rust_bridge::frb;
use crate::frb_generated::StreamSink;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, EnvFilter};

#[frb(init)]
pub fn init_app() {
    // Default utilities - e.g. logging
    flutter_rust_bridge::setup_default_user_utils();

    // Initialize Android logging for log:: macros
    #[cfg(target_os = "android")]
    android_logger::init_once(
        android_logger::Config::default()
            .with_max_level(log::LevelFilter::Debug)
            .with_filter(android_logger::FilterBuilder::new()
                .parse("info,mydia=debug,iroh=info,noq=warn,noq_proto=warn,yamux=warn,netlink_proto=warn")
                .build())
            .with_tag("mydia_p2p"),
    );

    // Initialize tracing for mydia_p2p_core and iroh (which use tracing:: macros)
    // This must be done BEFORE Host::new() is called to capture iroh's startup logs
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new("info,mydia_p2p_core=debug,iroh=info,noq=warn,rustls=warn"));

    #[cfg(target_os = "android")]
    {
        // On Android, use tracing-android to forward tracing events to logcat
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_android::layer("mydia_p2p").unwrap())
            .try_init();
    }

    #[cfg(not(target_os = "android"))]
    {
        // On other platforms, use standard fmt subscriber
        let _ = tracing_subscriber::registry()
            .with(filter)
            .with(tracing_subscriber::fmt::layer())
            .try_init();
    }

    log::info!("mydia_player_p2p initialized");
}

pub struct P2pHost {
    inner: Host,
    hls_requester: HlsRequester,
}

pub struct FlutterPairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

pub struct FlutterPairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
    pub direct_urls: Vec<String>,
}

/// Connection type for a peer (relay vs direct) for display in Flutter UI
#[frb(non_opaque)]
pub enum FlutterConnectionType {
    /// Direct peer-to-peer connection
    Direct,
    /// Connection via relay server
    Relay,
    /// Using both relay and direct paths
    Mixed,
    /// No active connection
    None,
}

impl From<PeerConnectionType> for FlutterConnectionType {
    fn from(ct: PeerConnectionType) -> Self {
        match ct {
            PeerConnectionType::Direct => FlutterConnectionType::Direct,
            PeerConnectionType::Relay => FlutterConnectionType::Relay,
            PeerConnectionType::Mixed => FlutterConnectionType::Mixed,
            PeerConnectionType::None => FlutterConnectionType::None,
        }
    }
}

/// Network statistics for display in the UI
pub struct FlutterNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
    /// The relay URL currently in use (extracted from endpoint address)
    pub relay_url: Option<String>,
    /// Connection type for the connected peer (relay vs direct)
    pub peer_connection_type: FlutterConnectionType,
}

/// GraphQL request to send over P2P
pub struct FlutterGraphQLRequest {
    pub query: String,
    pub variables: Option<String>,
    pub operation_name: Option<String>,
    pub auth_token: Option<String>,
}

/// GraphQL response received over P2P
pub struct FlutterGraphQLResponse {
    pub data: Option<String>,
    pub errors: Option<String>,
}

/// HLS request to send over P2P
pub struct FlutterHlsRequest {
    pub session_id: String,
    pub path: String,
    pub range_start: Option<u64>,
    pub range_end: Option<u64>,
    pub auth_token: Option<String>,
}

/// HLS response header received over P2P
pub struct FlutterHlsResponseHeader {
    pub status: u16,
    pub content_type: String,
    pub content_length: u64,
    pub content_range: Option<String>,
    pub cache_control: Option<String>,
}

/// HLS stream event (header or chunk)
#[frb(non_opaque)]
pub enum FlutterHlsStreamEvent {
    Header(FlutterHlsResponseHeader),
    Chunk(Vec<u8>),
    End,
    Error(String),
}

/// HLS stream complete response (non-streaming version)
pub struct FlutterHlsResponse {
    pub header: FlutterHlsResponseHeader,
    pub data: Vec<u8>,
}

impl P2pHost {
    /// Initialize a new P2P host with optional custom relay URL.
    #[frb(sync)]
    pub fn init(relay_url: Option<String>) -> (Self, String) {
        log::info!("P2pHost::init() called with relay_url: {:?}", relay_url);
        let config = HostConfig {
            relay_url,
            bind_port: None,
            keypair_path: None,
        };
        let (host, node_id) = Host::new(config);
        let hls_requester = host.hls_requester();
        log::info!("P2pHost created with node_id: {}", node_id);
        (P2pHost { inner: host, hls_requester }, node_id)
    }

    /// Get this node's EndpointAddr as JSON for sharing.
    pub fn get_node_addr(&self) -> String {
        self.inner.get_node_addr()
    }

    /// Dial a peer using their EndpointAddr JSON.
    pub fn dial(&self, endpoint_addr_json: String) -> anyhow::Result<()> {
        log::info!("P2pHost::dial() called");
        match self.inner.dial(endpoint_addr_json) {
            Ok(_) => {
                log::info!("dial() succeeded");
                Ok(())
            }
            Err(e) => {
                log::error!("dial() failed: {}", e);
                Err(anyhow::anyhow!("dial failed: {}", e))
            }
        }
    }

    /// Start streaming events to Flutter.
    pub fn event_stream(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        log::info!("P2pHost::event_stream() called");
        let rx = self.inner.event_rx.clone();

        std::thread::spawn(move || {
            log::info!("event_stream thread started");
            let rt = match tokio::runtime::Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create Tokio runtime for event_stream: {}", e);
                    return;
                }
            };
            rt.block_on(async move {
                let mut rx = rx.lock().await;
                log::info!("event_stream listening for events");
                while let Some(event) = rx.recv().await {
                    let msg = match event {
                        Event::Connected { peer_id, connection_type } => format!("connected:{}:{}", peer_id, connection_type.as_str()),
                        Event::Disconnected(peer_id) => format!("disconnected:{}", peer_id),
                        Event::RelayConnected => "relay_connected".to_string(),
                        Event::Ready { node_addr } => format!("ready:{}", node_addr),
                        Event::RequestReceived { .. } => {
                            // Client doesn't handle incoming requests
                            continue;
                        }
                        Event::HlsStreamRequest { .. } => {
                            // Client doesn't handle incoming HLS requests
                            continue;
                        }
                        Event::ConnectionTypeChanged { peer_id, connection_type } => {
                            format!("connection_type_changed:{}:{}", peer_id, connection_type.as_str())
                        }
                        Event::Log { .. } => {
                            // Logs are handled separately via android_logger/tracing
                            continue;
                        }
                    };
                    log::debug!("event_stream received: {}", msg);
                    if sink.add(msg).is_err() {
                        log::warn!("event_stream sink closed, exiting");
                        break;
                    }
                }
                log::info!("event_stream loop ended");
            });
        });
        Ok(())
    }

    /// Send a pairing request to a specific peer.
    pub async fn send_pairing_request(&self, peer: String, req: FlutterPairingRequest) -> anyhow::Result<FlutterPairingResponse> {
        log::info!("P2pHost::send_pairing_request() called for peer: {}, claim_code: {}",
            peer, req.claim_code);
        let core_req = PairingRequest {
            claim_code: req.claim_code,
            device_name: req.device_name,
            device_type: req.device_type,
            device_os: req.device_os,
        };

        match self.inner.send_request(peer.clone(), MydiaRequest::Pairing(core_req)).await {
            Ok(MydiaResponse::Pairing(res)) => {
                log::info!("send_pairing_request() succeeded: success={}", res.success);
                Ok(FlutterPairingResponse {
                    success: res.success,
                    media_token: res.media_token,
                    access_token: res.access_token,
                    device_token: res.device_token,
                    error: res.error,
                    direct_urls: res.direct_urls,
                })
            }
            Ok(MydiaResponse::Error(e)) => {
                log::error!("send_pairing_request() server error: {}", e);
                Err(anyhow::anyhow!("Server error: {}", e))
            }
            Ok(other) => {
                log::error!("send_pairing_request() unexpected response type: {:?}", other);
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_pairing_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_pairing_request failed: {}", e))
            }
        }
    }

    /// Send a GraphQL request to a specific peer.
    pub async fn send_graphql_request(&self, peer: String, req: FlutterGraphQLRequest) -> anyhow::Result<FlutterGraphQLResponse> {
        log::info!("P2pHost::send_graphql_request() called for peer: {}", peer);
        let core_req = GraphQLRequest {
            query: req.query,
            variables: req.variables,
            operation_name: req.operation_name,
            auth_token: req.auth_token,
        };

        match self.inner.send_request(peer.clone(), MydiaRequest::GraphQL(core_req)).await {
            Ok(MydiaResponse::GraphQL(res)) => {
                log::info!("send_graphql_request() succeeded");
                Ok(FlutterGraphQLResponse {
                    data: res.data,
                    errors: res.errors,
                })
            }
            Ok(MydiaResponse::Error(e)) => {
                log::error!("send_graphql_request() server error: {}", e);
                Err(anyhow::anyhow!("Server error: {}", e))
            }
            Ok(other) => {
                log::error!("send_graphql_request() unexpected response type: {:?}", other);
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_graphql_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_graphql_request failed: {}", e))
            }
        }
    }

    /// Get network statistics.
    pub fn get_network_stats(&self) -> FlutterNetworkStats {
        let stats = self.inner.get_network_stats();
        log::info!("Network stats: connected_peers={}, relay_connected={}, relay_url={:?}, peer_conn_type={:?}",
            stats.connected_peers, stats.relay_connected, stats.relay_url, stats.peer_connection_type);
        FlutterNetworkStats {
            connected_peers: stats.connected_peers,
            relay_connected: stats.relay_connected,
            relay_url: stats.relay_url,
            peer_connection_type: stats.peer_connection_type.into(),
        }
    }

    /// Send an HLS request to a specific peer and stream the response.
    ///
    /// Sends Header, Chunk, and End events via a StreamSink. The stream is
    /// cancelled automatically when the Dart subscription is dropped (sink.add
    /// returns an error).
    pub fn send_hls_request_streaming(
        &self,
        peer: String,
        req: FlutterHlsRequest,
        sink: StreamSink<FlutterHlsStreamEvent>,
    ) -> anyhow::Result<()> {
        log::info!(
            "P2pHost::send_hls_request_streaming() called for peer: {}, session: {}, path: {}",
            peer, req.session_id, req.path
        );

        let core_req = HlsRequest {
            session_id: req.session_id,
            path: req.path,
            range_start: req.range_start,
            range_end: req.range_end,
            auth_token: req.auth_token,
        };

        let requester = self.hls_requester.clone();

        std::thread::spawn(move || {
            let rt = match tokio::runtime::Runtime::new() {
                Ok(rt) => rt,
                Err(e) => {
                    log::error!("Failed to create Tokio runtime for streaming HLS: {}", e);
                    let _ = sink.add(FlutterHlsStreamEvent::Error(format!("Runtime error: {}", e)));
                    return;
                }
            };

            rt.block_on(async move {
                match requester.send_hls_request(peer.clone(), core_req).await {
                    Ok(stream_response) => {
                        // Send header event
                        let header = FlutterHlsResponseHeader {
                            status: stream_response.header.status,
                            content_type: stream_response.header.content_type,
                            content_length: stream_response.header.content_length,
                            content_range: stream_response.header.content_range,
                            cache_control: stream_response.header.cache_control,
                        };
                        if sink.add(FlutterHlsStreamEvent::Header(header)).is_err() {
                            log::debug!("HLS stream sink closed on header");
                            return;
                        }

                        // Stream chunks
                        let mut chunk_rx = stream_response.chunk_rx;
                        while let Some(chunk) = chunk_rx.recv().await {
                            if sink.add(FlutterHlsStreamEvent::Chunk(chunk)).is_err() {
                                log::debug!("HLS stream sink closed, stopping chunk read");
                                return;
                            }
                        }

                        // Signal end
                        let _ = sink.add(FlutterHlsStreamEvent::End);
                    }
                    Err(e) => {
                        log::error!("HLS streaming request failed for peer {}: {}", peer, e);
                        let _ = sink.add(FlutterHlsStreamEvent::Error(format!("HLS request failed: {}", e)));
                    }
                }
            });
        });

        Ok(())
    }

    /// Send an HLS request to a specific peer and collect the complete response.
    ///
    /// This is a non-streaming version that collects all chunks into a single buffer.
    /// For large files, consider using the local proxy service instead.
    pub async fn send_hls_request(&self, peer: String, req: FlutterHlsRequest) -> anyhow::Result<FlutterHlsResponse> {
        log::info!("P2pHost::send_hls_request() called for peer: {}, session: {}, path: {}",
            peer, req.session_id, req.path);

        let core_req = HlsRequest {
            session_id: req.session_id,
            path: req.path,
            range_start: req.range_start,
            range_end: req.range_end,
            auth_token: req.auth_token,
        };

        // Call the Host's send_hls_request method
        match self.inner.send_hls_request(peer.clone(), core_req).await {
            Ok(stream_response) => {
                let flutter_header = FlutterHlsResponseHeader {
                    status: stream_response.header.status,
                    content_type: stream_response.header.content_type,
                    content_length: stream_response.header.content_length,
                    content_range: stream_response.header.content_range,
                    cache_control: stream_response.header.cache_control,
                };

                // Collect all chunks into a single buffer
                let mut data = Vec::with_capacity(stream_response.header.content_length as usize);
                let mut chunk_rx = stream_response.chunk_rx;
                while let Some(chunk) = chunk_rx.recv().await {
                    data.extend_from_slice(&chunk);
                }

                log::info!("HLS request completed for peer: {}, received {} bytes", peer, data.len());
                Ok(FlutterHlsResponse {
                    header: flutter_header,
                    data,
                })
            }
            Err(e) => {
                log::error!("send_hls_request failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("HLS request failed: {}", e))
            }
        }
    }

}
