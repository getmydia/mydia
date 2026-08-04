//! NIF bindings for mydia_p2p_core (iroh-based)
//!
//! Provides Erlang/Elixir interop for the p2p networking functionality.

use mydia_p2p_core::{
    Event, GraphQLResponse, HlsResponseHeader, Host, HostConfig, LogLevel, MydiaRequest,
    MydiaResponse, PairingResponse,
};
use rustler::{
    Binary, Encoder, Env, LocalPid, NifStruct, NifTaggedEnum, OwnedEnv, ResourceArc, Term,
};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::thread;

mod atoms {
    rustler::atoms! {
        ok,
    }
}

// Resource to hold the Host state
struct HostResource {
    host: Host,
}

#[rustler::resource_impl]
impl rustler::Resource for HostResource {}

/// Start the p2p host with configuration.
/// relay_url: Custom relay URL for NAT traversal (uses default relays if None).
/// bind_port: UDP port for direct connections (0 or None for random port).
/// keypair_path: Path to store/load the node's keypair for persistent identity.
/// Returns (resource, node_id_string).
#[rustler::nif]
fn start_host<'a>(
    env: Env<'a>,
    relay_url: Option<String>,
    bind_port: Option<u16>,
    keypair_path: Option<String>,
) -> Term<'a> {
    let config = HostConfig {
        relay_url,
        bind_port,
        keypair_path,
    };
    let (host, node_id_str) = Host::new(config);
    let resource = ResourceArc::new(HostResource { host });
    (resource, node_id_str).encode(env)
}

/// Dial a peer using their EndpointAddr JSON.
#[rustler::nif(schedule = "DirtyIo")]
fn dial(
    resource: ResourceArc<HostResource>,
    endpoint_addr_json: String,
) -> Result<String, rustler::Error> {
    match resource.host.dial(endpoint_addr_json) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Get this node's EndpointAddr as JSON for sharing.
#[rustler::nif(schedule = "DirtyIo")]
fn get_node_addr(resource: ResourceArc<HostResource>) -> String {
    resource.host.get_node_addr()
}

/// Get network statistics.
#[rustler::nif(schedule = "DirtyIo")]
fn get_network_stats(resource: ResourceArc<HostResource>) -> ElixirNetworkStats {
    let stats = resource.host.get_network_stats();
    ElixirNetworkStats {
        connected_peers: stats.connected_peers,
        relay_connected: stats.relay_connected,
        relay_url: stats.relay_url,
        peer_connection_type: stats.peer_connection_type.as_str().to_string(),
    }
}

// Mirror structs for Elixir interop
#[derive(NifStruct)]
#[module = "Mydia.P2p.NetworkStats"]
struct ElixirNetworkStats {
    pub connected_peers: usize,
    pub relay_connected: bool,
    pub relay_url: Option<String>,
    pub peer_connection_type: String,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.PairingRequest"]
struct ElixirPairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.PairingResponse"]
struct ElixirPairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
    pub direct_urls: Vec<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.GraphQLRequest"]
struct ElixirGraphQLRequest {
    pub query: String,
    pub variables: Option<String>,
    pub operation_name: Option<String>,
    pub auth_token: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.GraphQLResponse"]
struct ElixirGraphQLResponse {
    pub data: Option<String>,
    pub errors: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.HlsRequest"]
struct ElixirHlsRequest {
    pub session_id: String,
    pub path: String,
    pub range_start: Option<u64>,
    pub range_end: Option<u64>,
    pub auth_token: Option<String>,
}

#[derive(NifStruct)]
#[module = "Mydia.P2p.HlsResponseHeader"]
struct ElixirHlsResponseHeader {
    pub status: u16,
    pub content_type: String,
    pub content_length: u64,
    pub content_range: Option<String>,
    pub cache_control: Option<String>,
}

#[derive(NifTaggedEnum)]
enum ElixirResponse {
    Pairing(ElixirPairingResponse),
    MediaChunk(Vec<u8>),
    Graphql(ElixirGraphQLResponse),
    Error(String),
}

/// Send a response to an incoming request.
#[rustler::nif(schedule = "DirtyIo")]
fn send_response(
    resource: ResourceArc<HostResource>,
    request_id: String,
    response: ElixirResponse,
) -> Result<String, rustler::Error> {
    let core_response = match response {
        ElixirResponse::Pairing(r) => MydiaResponse::Pairing(PairingResponse {
            success: r.success,
            media_token: r.media_token,
            access_token: r.access_token,
            device_token: r.device_token,
            error: r.error,
            direct_urls: r.direct_urls,
        }),
        ElixirResponse::MediaChunk(data) => MydiaResponse::MediaChunk(data),
        ElixirResponse::Graphql(r) => MydiaResponse::GraphQL(GraphQLResponse {
            data: r.data,
            errors: r.errors,
        }),
        ElixirResponse::Error(e) => MydiaResponse::Error(e),
    };

    match resource.host.send_response(request_id, core_response) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Read a file chunk and send it as a response.
/// This is done in a separate thread to avoid blocking the NIF.
#[rustler::nif]
fn respond_with_file_chunk(
    resource: ResourceArc<HostResource>,
    request_id: String,
    file_path: String,
    offset: u64,
    length: u32,
) -> Result<String, rustler::Error> {
    let resource_clone = resource.clone();

    thread::spawn(move || {
        let response = match File::open(&file_path) {
            Ok(mut file) => {
                if file.seek(SeekFrom::Start(offset)).is_ok() {
                    let mut buffer = vec![0; length as usize];
                    match file.read(&mut buffer) {
                        Ok(n) => {
                            buffer.truncate(n);
                            MydiaResponse::MediaChunk(buffer)
                        }
                        Err(e) => MydiaResponse::Error(format!("Read error: {}", e)),
                    }
                } else {
                    MydiaResponse::Error("Seek error".to_string())
                }
            }
            Err(e) => MydiaResponse::Error(format!("File open error: {}", e)),
        };

        let _ = resource_clone.host.send_response(request_id, response);
    });

    Ok("ok".to_string())
}

/// Send an HLS response header for a streaming request.
/// Must be called before any send_hls_chunk calls.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn send_hls_header(
    resource: ResourceArc<HostResource>,
    stream_id: String,
    header: ElixirHlsResponseHeader,
) -> Result<String, rustler::Error> {
    let core_header = HlsResponseHeader {
        status: header.status,
        content_type: header.content_type,
        content_length: header.content_length,
        content_range: header.content_range,
        cache_control: header.cache_control,
    };

    match resource.host.send_hls_header(stream_id, core_header) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Send a chunk of HLS data.
/// Must be called after send_hls_header and before finish_hls_stream.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn send_hls_chunk(
    resource: ResourceArc<HostResource>,
    stream_id: String,
    data: Binary,
) -> Result<String, rustler::Error> {
    match resource
        .host
        .send_hls_chunk(stream_id, data.as_slice().to_vec())
    {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Finish an HLS stream.
/// Must be called after all chunks have been sent.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn finish_hls_stream(
    resource: ResourceArc<HostResource>,
    stream_id: String,
) -> Result<String, rustler::Error> {
    match resource.host.finish_hls_stream(stream_id) {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Stream a file range directly to a QUIC stream.
/// Reads the file in Rust and writes length-prefixed chunks, avoiding per-chunk NIF overhead.
/// The stream is finished automatically after all data is written.
/// Uses DirtyIo scheduler because blocking_send/blocking_recv block the thread.
#[rustler::nif(schedule = "DirtyIo")]
fn stream_file_range(
    resource: ResourceArc<HostResource>,
    stream_id: String,
    file_path: String,
    offset: u64,
    length: u64,
) -> Result<String, rustler::Error> {
    match resource
        .host
        .stream_file_range(stream_id, file_path, offset, length)
    {
        Ok(_) => Ok("ok".to_string()),
        Err(e) => Err(rustler::Error::Term(Box::new(e))),
    }
}

/// Start listening for events and forward them to the given Elixir process.
#[rustler::nif]
#[allow(unused_variables)]
fn start_listening(
    env: Env,
    resource: ResourceArc<HostResource>,
    pid: LocalPid,
) -> Result<String, rustler::Error> {
    let host = &resource.host;
    let event_rx = host.event_rx.clone();

    thread::spawn(move || {
        let rt = tokio::runtime::Runtime::new().unwrap();
        rt.block_on(async {
            let mut rx = event_rx.lock().await;
            while let Some(event) = rx.recv().await {
                let mut msg_env = OwnedEnv::new();
                let _ = msg_env.send_and_clear(&pid, |env| match event {
                    Event::Connected {
                        peer_id,
                        connection_type,
                    } => (
                        atoms::ok(),
                        "peer_connected",
                        peer_id,
                        connection_type.as_str(),
                    )
                        .encode(env),
                    Event::Disconnected(peer_id) => {
                        (atoms::ok(), "peer_disconnected", peer_id).encode(env)
                    }
                    Event::ConnectionTypeChanged {
                        peer_id,
                        connection_type,
                    } => (
                        atoms::ok(),
                        "peer_connection_type_changed",
                        peer_id,
                        connection_type.as_str(),
                    )
                        .encode(env),
                    Event::RequestReceived {
                        peer: _,
                        request,
                        request_id,
                    } => match request {
                        MydiaRequest::Pairing(req) => {
                            let elixir_req = ElixirPairingRequest {
                                claim_code: req.claim_code,
                                device_name: req.device_name,
                                device_type: req.device_type,
                                device_os: req.device_os,
                            };
                            (
                                atoms::ok(),
                                "request_received",
                                "pairing",
                                request_id,
                                elixir_req,
                            )
                                .encode(env)
                        }
                        MydiaRequest::GraphQL(req) => {
                            let elixir_req = ElixirGraphQLRequest {
                                query: req.query,
                                variables: req.variables,
                                operation_name: req.operation_name,
                                auth_token: req.auth_token,
                            };
                            (
                                atoms::ok(),
                                "request_received",
                                "graphql",
                                request_id,
                                elixir_req,
                            )
                                .encode(env)
                        }
                        MydiaRequest::Ping => {
                            (atoms::ok(), "request_received", "ping", request_id).encode(env)
                        }
                        _ => (atoms::ok(), "unknown_request").encode(env),
                    },
                    Event::HlsStreamRequest {
                        peer: _,
                        request,
                        stream_id,
                    } => {
                        let elixir_req = ElixirHlsRequest {
                            session_id: request.session_id,
                            path: request.path,
                            range_start: request.range_start,
                            range_end: request.range_end,
                            auth_token: request.auth_token,
                        };
                        (atoms::ok(), "hls_stream", stream_id, elixir_req).encode(env)
                    }
                    Event::RelayConnected => (atoms::ok(), "relay_connected").encode(env),
                    Event::Ready { node_addr } => (atoms::ok(), "ready", node_addr).encode(env),
                    Event::Log {
                        level,
                        target,
                        message,
                    } => {
                        let level_str = match level {
                            LogLevel::Trace => "trace",
                            LogLevel::Debug => "debug",
                            LogLevel::Info => "info",
                            LogLevel::Warn => "warn",
                            LogLevel::Error => "error",
                        };
                        (atoms::ok(), "log", level_str, target, message).encode(env)
                    }
                });
            }
        });
    });

    Ok("ok".to_string())
}

rustler::init!("Elixir.Mydia.P2p");
