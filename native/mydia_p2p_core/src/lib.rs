use libp2p::{
    identity,
    ping,
    mdns,
    kad,
    noise,
    tcp,
    yamux,
    relay,
    dcutr,
    request_response::{self, ProtocolSupport, OutboundRequestId},
    swarm::behaviour::toggle::Toggle,
    PeerId,
    SwarmBuilder,
    Multiaddr,
    swarm::{NetworkBehaviour, SwarmEvent, Config as SwarmConfig},
};
use std::time::Duration;
use std::collections::HashMap;
use tokio::runtime::Runtime;
use tokio::sync::{mpsc, oneshot};
use libp2p::futures::StreamExt;
use sha2::{Sha256, Digest};
use log::{info, warn, error, debug};

/// Initialize logging for the platform
pub fn init_logging() {
    #[cfg(target_os = "android")]
    {
        android_logger::init_once(
            android_logger::Config::default()
                .with_max_level(log::LevelFilter::Debug)
                .with_filter(android_logger::FilterBuilder::new()
                    .parse("debug,yamux=warn,libp2p_yamux=warn,multistream_select=warn,netlink_proto=warn")
                    .build())
                .with_tag("p2p_core"),
        );
    }
    
    #[cfg(not(target_os = "android"))]
    {
        use std::io::Write;
        let _ = env_logger::Builder::from_env(
            env_logger::Env::default().default_filter_or("mydia_p2p_core=info,mydia_libp2p=info")
        )
        .format(|buf, record| {
            writeln!(buf, "[RUST {}] {}: {}", record.level(), record.target(), record.args())
        })
        .try_init();
    }
}

// Define the Network Behaviour
#[derive(NetworkBehaviour)]
pub struct MydiaBehaviour {
    ping: ping::Behaviour,
    mdns: Toggle<mdns::tokio::Behaviour>,
    kad: kad::Behaviour<kad::store::MemoryStore>,
    request_response: request_response::cbor::Behaviour<MydiaRequest, MydiaResponse>,
    relay_client: relay::client::Behaviour,
    dcutr: dcutr::Behaviour,
    relay_server: relay::Behaviour,
}

// Request/Response Types (using Serde/CBOR)
#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaRequest {
    Ping,
    Pairing(PairingRequest),
    ReadMedia(ReadMediaRequest),
    Custom(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PairingRequest {
    pub claim_code: String,
    pub device_name: String,
    pub device_type: String,
    pub device_os: Option<String>,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct ReadMediaRequest {
    pub file_path: String,
    pub offset: u64,
    pub length: u32,
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub enum MydiaResponse {
    Pong,
    Pairing(PairingResponse),
    MediaChunk(Vec<u8>),
    Custom(Vec<u8>),
    Error(String),
}

#[derive(Debug, Clone, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct PairingResponse {
    pub success: bool,
    pub media_token: Option<String>,
    pub access_token: Option<String>,
    pub device_token: Option<String>,
    pub error: Option<String>,
}

// Commands that can be sent to the Host
pub enum Command {
    Listen(String),
    Dial(String),
    Bootstrap(String), // Add a bootstrap peer address
    /// Connect to a relay server and request a reservation.
    /// This allows other peers to reach us through the relay.
    ConnectRelay {
        /// Multiaddr of the relay, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3KooW..."
        relay_addr: String,
    },
    /// Add an external address that this host is reachable at.
    /// This is important for relay servers to advertise their addresses in reservations.
    AddExternalAddress(String),
    SendRequest { 
        peer: String, 
        request: MydiaRequest, 
        reply: oneshot::Sender<Result<MydiaResponse, String>> 
    },
    SendResponse { request_id: String, response: MydiaResponse },
    // DHT commands for claim code discovery
    ProvideClaimCode { 
        claim_code: String,
        reply: oneshot::Sender<Result<(), String>>,
    },
    LookupClaimCode { 
        claim_code: String,
        reply: oneshot::Sender<Result<LookupResult, String>>,
    },
    // Get DHT statistics
    GetDhtStats {
        reply: oneshot::Sender<DhtStats>,
    },
}

/// Result of a DHT lookup for a claim code
#[derive(Debug, Clone)]
pub struct LookupResult {
    pub peer_id: String,
    pub addresses: Vec<String>,
}

/// DHT statistics
#[derive(Debug, Clone)]
pub struct DhtStats {
    pub routing_table_size: usize,
    pub provided_keys_count: usize,
    pub bootstrap_complete: bool,
}

// Events emitted by the Host
#[derive(Debug)]
pub enum Event {
    PeerDiscovered(String),
    PeerExpired(String),
    PeerConnected(String),
    PeerDisconnected(String),
    RequestReceived { 
        peer: String, 
        request: MydiaRequest, 
        request_id: String,
    },
    BootstrapCompleted,
    /// A new listen address was obtained (e.g., relay circuit address)
    NewListenAddr(String),
    /// Relay reservation was successful - we can now receive connections through this relay
    RelayReservationReady {
        relay_peer_id: String,
        /// Our address through the relay (e.g., /ip4/.../p2p/<relay>/p2p-circuit/p2p/<us>)
        relayed_addr: String,
    },
    /// Relay reservation failed
    RelayReservationFailed {
        relay_peer_id: String,
        error: String,
    },
}

/// Converts a claim code to a Kademlia record key using SHA256 hash
fn claim_code_to_key(claim_code: &str) -> kad::RecordKey {
    let mut hasher = Sha256::new();
    hasher.update(b"mydia-claim:");
    hasher.update(claim_code.to_uppercase().as_bytes());
    let hash = hasher.finalize();
    let hash_vec: Vec<u8> = hash.to_vec();
    kad::RecordKey::new(&hash_vec)
}

// Configuration for the Host
pub struct HostConfig {
    pub enable_relay_server: bool,
    /// Optional list of bootstrap peer addresses (multiaddr format with peer ID)
    /// e.g., "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN"
    pub bootstrap_peers: Vec<String>,
    /// Optional path to persist the keypair. If set, the keypair will be loaded from this file
    /// if it exists, or generated and saved if it doesn't. This ensures stable peer IDs across restarts.
    pub keypair_path: Option<String>,
}

impl Default for HostConfig {
    fn default() -> Self {
        Self {
            enable_relay_server: false,
            bootstrap_peers: vec![],
            keypair_path: None,
        }
    }
}

/// Public IPFS/libp2p bootstrap nodes
/// DNS-based addresses require DNS transport (not available on Android)
/// IP-based addresses work everywhere
#[cfg(not(target_os = "android"))]
pub const IPFS_BOOTSTRAP_NODES: &[&str] = &[
    // DNS-based (requires DNS transport)
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmNnooDu7bfjPFoTZYxMNLWUQJyrVwtbZg5gBMjTezGAJN",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmQCU2EcMqAqQPR2i9bChDtGNJchTbq5TbXJJ16u19uLTa",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmbLHAnMoJPWSCR5Zhtx6BHJX9KiKNN6tpvbUcqanj75Nb",
    "/dnsaddr/bootstrap.libp2p.io/p2p/QmcZf59bWwK5XFi76CZX8cbJ4BhTzzA3gU1ZjYZcYW3dwt",
    // IP-based fallback
    "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
];

/// Android-specific bootstrap nodes (IP addresses only, no DNS resolution needed)
#[cfg(target_os = "android")]
pub const IPFS_BOOTSTRAP_NODES: &[&str] = &[
    // Protocol Labs bootstrap nodes (direct IP)
    "/ip4/104.131.131.82/tcp/4001/p2p/QmaCpDMGvV2BGHeYERUEnRQAwe3N8SzbUtfsmvsqQLuvuJ",
    "/ip4/104.236.179.241/tcp/4001/p2p/QmSoLPppuBtQSGwKDZT2M73ULpjvfd3aZ6ha4oFGL1KrGM",
    "/ip4/128.199.219.111/tcp/4001/p2p/QmSoLSafTMBsPKadTEgaXctDQVcqN88CNLHXMkTNwMKPnu",
    "/ip4/104.236.76.40/tcp/4001/p2p/QmSoLV4Bbm51jM9C4gDYZQ9Cy3U6aXMJDAbzgu2fzaDs64",
    "/ip4/178.62.158.247/tcp/4001/p2p/QmSoLer265NRgSp2LA3dPaeykiS1J6DifTC88f5uVQKNAd",
    "/ip4/178.62.61.185/tcp/4001/p2p/QmSoLMeWqB7YGVLJN3pNLQpmmEk35v6wYtsMGLzSr5QBU3",
    "/ip4/104.236.151.122/tcp/4001/p2p/QmSoLju6m7xTh3DuokvT3886QRYqxAzb1kShaanJgW36yx",
];

/// Helper function to add bootstrap peer to swarm
fn add_bootstrap_peer(swarm: &mut libp2p::Swarm<MydiaBehaviour>, addr_str: &str) -> bool {
    if let Ok(addr) = addr_str.parse::<Multiaddr>() {
        // Extract peer ID from /p2p/... component
        let peer_id = addr.iter().find_map(|p| {
            if let libp2p::multiaddr::Protocol::P2p(id) = p {
                Some(id)
            } else {
                None
            }
        });
        
        if let Some(peer_id) = peer_id {
            // Add address to Kademlia routing table
            swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
            // Dial the peer
            let _ = swarm.dial(addr);
            return true;
        }
    }
    false
}

/// Load a keypair from a file, or generate a new one and save it.
/// This ensures stable peer IDs across restarts when a path is provided.
fn load_or_generate_keypair(path: Option<&str>) -> identity::Keypair {
    match path {
        Some(p) => {
            let path = std::path::Path::new(p);
            
            // Try to load existing keypair
            if path.exists() {
                match std::fs::read(path) {
                    Ok(bytes) => {
                        match identity::Keypair::from_protobuf_encoding(&bytes) {
                            Ok(keypair) => {
                                info!("Loaded existing keypair from {}", p);
                                return keypair;
                            }
                            Err(e) => {
                                warn!("Failed to decode keypair from {}: {:?}, generating new one", p, e);
                            }
                        }
                    }
                    Err(e) => {
                        warn!("Failed to read keypair from {}: {:?}, generating new one", p, e);
                    }
                }
            }
            
            // Generate new keypair and save it
            let keypair = identity::Keypair::generate_ed25519();
            match keypair.to_protobuf_encoding() {
                Ok(bytes) => {
                    // Ensure parent directory exists
                    if let Some(parent) = path.parent() {
                        let _ = std::fs::create_dir_all(parent);
                    }
                    match std::fs::write(path, &bytes) {
                        Ok(_) => {
                            info!("Generated and saved new keypair to {}", p);
                        }
                        Err(e) => {
                            warn!("Failed to save keypair to {}: {:?}", p, e);
                        }
                    }
                }
                Err(e) => {
                    warn!("Failed to encode keypair: {:?}", e);
                }
            }
            keypair
        }
        None => {
            // No path provided, just generate a new keypair
            identity::Keypair::generate_ed25519()
        }
    }
}

// The core Host struct that manages the Libp2p Swarm
pub struct Host {
    pub cmd_tx: mpsc::Sender<Command>,
    pub event_rx: std::sync::Arc<tokio::sync::Mutex<mpsc::Receiver<Event>>>,
    pub peer_id: PeerId,
}

impl Host {
    pub fn new(config: HostConfig) -> (Self, String) {
        let id_keys = load_or_generate_keypair(config.keypair_path.as_deref());
        let peer_id = PeerId::from(id_keys.public());
        let peer_id_str = peer_id.to_string();

        let (cmd_tx, mut cmd_rx) = mpsc::channel::<Command>(32);
        let (event_tx, event_rx) = mpsc::channel::<Event>(100);

        // Spawn the Swarm in a background thread/runtime
        std::thread::spawn(move || {
            // Initialize logging for this thread
            init_logging();
            info!("Swarm thread started");
            
            // Catch panics to log them
            let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                let rt = match Runtime::new() {
                    Ok(rt) => rt,
                    Err(e) => {
                        error!("Failed to create Tokio runtime: {:?}", e);
                        return;
                    }
                };
                rt.block_on(async move {
                    info!("Building swarm...");
                    
                    // Build swarm using a macro to handle the different builder types
                    // On Android, we skip DNS because it requires /etc/resolv.conf which doesn't exist
                    macro_rules! build_swarm {
                        ($builder:expr) => {{
                            let relay_result = $builder.with_relay_client(noise::Config::new, yamux::Config::default);
                            let relay_builder = match relay_result {
                                Ok(b) => b,
                                Err(e) => {
                                    error!("Failed to create relay client: {:?}", e);
                                    return;
                                }
                            };
                            info!("Relay client created");
                            
                            let behaviour_result = relay_builder.with_behaviour(|key: &identity::Keypair, relay_client: relay::client::Behaviour| {
                                let peer_id = PeerId::from(key.public());
                                info!("Creating behaviours for peer: {}", peer_id);
                                
                                // Try to create mDNS - may fail on Android/iOS, that's OK
                                let mdns = match mdns::tokio::Behaviour::new(mdns::Config::default(), peer_id) {
                                    Ok(m) => {
                                        info!("mDNS created successfully");
                                        Toggle::from(Some(m))
                                    }
                                    Err(e) => {
                                        // mDNS is not critical for DHT-based discovery
                                        warn!("mDNS creation failed (non-fatal): {:?}", e);
                                        Toggle::from(None)
                                    }
                                };
                                
                                let kad_store = kad::store::MemoryStore::new(peer_id);
                                let kad = kad::Behaviour::new(peer_id, kad_store);
                                info!("Kademlia DHT created");
                                
                                let request_response = request_response::cbor::Behaviour::new(
                                    [(
                                        libp2p::StreamProtocol::new("/mydia/1.0.0"),
                                        ProtocolSupport::Full,
                                    )],
                                    request_response::Config::default(),
                                );
                                info!("Request/Response protocol created");

                                let dcutr = dcutr::Behaviour::new(peer_id);
                                let relay_server = relay::Behaviour::new(peer_id, relay::Config::default());
                                info!("All behaviours created successfully");

                                MydiaBehaviour {
                                    ping: ping::Behaviour::new(ping::Config::new().with_interval(Duration::from_secs(1))),
                                    mdns,
                                    kad,
                                    request_response,
                                    relay_client,
                                    dcutr,
                                    relay_server,
                                }
                            });
                            
                            match behaviour_result {
                                Ok(b) => b.with_swarm_config(|c: SwarmConfig| c.with_idle_connection_timeout(Duration::from_secs(60))).build(),
                                Err(e) => {
                                    error!("Failed to create behaviour: {:?}", e);
                                    return;
                                }
                            }
                        }};
                    }
                    
                    // Clone id_keys for potential fallback rebuild on non-Android
                    #[cfg(not(target_os = "android"))]
                    let id_keys_backup = id_keys.clone();
                    
                    let tcp_result = SwarmBuilder::with_existing_identity(id_keys)
                        .with_tokio()
                        .with_tcp(
                            tcp::Config::default(),
                            noise::Config::new,
                            yamux::Config::default,
                        );
                    
                    let tcp_builder = match tcp_result {
                        Ok(b) => b,
                        Err(e) => {
                            error!("Failed to create TCP transport: {:?}", e);
                            return;
                        }
                    };
                    info!("TCP transport created");
                    
                    // On Android, skip DNS transport (requires /etc/resolv.conf which doesn't exist)
                    // On other platforms, use DNS for /dnsaddr/ multiaddr resolution
                    #[cfg(target_os = "android")]
                    let mut swarm = {
                        info!("Android: skipping DNS transport (not available)");
                        build_swarm!(tcp_builder)
                    };
                    
                    #[cfg(not(target_os = "android"))]
                    let mut swarm = {
                        match tcp_builder.with_dns() {
                            Ok(dns_builder) => {
                                info!("DNS transport created");
                                build_swarm!(dns_builder)
                            }
                            Err(e) => {
                                warn!("DNS transport failed (non-fatal, skipping): {:?}", e);
                                // This shouldn't happen on non-Android, but handle it gracefully
                                // We need to rebuild the TCP builder since with_dns consumed it
                                let tcp_result = SwarmBuilder::with_existing_identity(id_keys_backup)
                                    .with_tokio()
                                    .with_tcp(
                                        tcp::Config::default(),
                                        noise::Config::new,
                                        yamux::Config::default,
                                    );
                                match tcp_result {
                                    Ok(tcp_builder) => build_swarm!(tcp_builder),
                                    Err(e) => {
                                        error!("Failed to recreate TCP transport: {:?}", e);
                                        return;
                                    }
                                }
                            }
                        }
                    };
                    
                    info!("Swarm built successfully");

                swarm.behaviour_mut().kad.set_mode(Some(kad::Mode::Server));

                // Auto-bootstrap to IPFS nodes
                let mut bootstrap_peers_added = 0;
                for addr_str in IPFS_BOOTSTRAP_NODES {
                    if add_bootstrap_peer(&mut swarm, addr_str) {
                        bootstrap_peers_added += 1;
                    }
                }
                // Also add any custom bootstrap peers from config
                for addr_str in &config.bootstrap_peers {
                    if add_bootstrap_peer(&mut swarm, addr_str) {
                        bootstrap_peers_added += 1;
                    }
                }
                
                // Trigger bootstrap if we added any peers
                if bootstrap_peers_added > 0 {
                    info!("Added {} bootstrap peers, starting DHT bootstrap...", bootstrap_peers_added);
                    let _ = swarm.behaviour_mut().kad.bootstrap();
                }

                let mut response_channels = std::collections::HashMap::new();
                let mut pending_requests: std::collections::HashMap<OutboundRequestId, oneshot::Sender<Result<MydiaResponse, String>>> = std::collections::HashMap::new();
                
                // Track pending DHT operations
                let mut pending_provides: HashMap<kad::QueryId, oneshot::Sender<Result<(), String>>> = HashMap::new();
                let mut pending_lookups: HashMap<kad::QueryId, oneshot::Sender<Result<LookupResult, String>>> = HashMap::new();
                
                // Track state
                let mut bootstrap_complete = false;
                let mut provided_keys_count: usize = 0;
                // Track pending relay connection - (Optional<relay_peer_id>, relay_addr)
                // If peer_id is None, we accept any peer ID that is reachable at relay_addr
                let mut pending_relay: Option<(Option<PeerId>, Multiaddr)> = None;

                loop {
                    tokio::select! {
                        event = swarm.select_next_some() => match event {
                            SwarmEvent::NewListenAddr { address, .. } => {
                                let addr_str = address.to_string();
                                info!("Libp2p listening on {:?}", address);
                                
                                // Notify about new listen address
                                let _ = event_tx.send(Event::NewListenAddr(addr_str.clone())).await;
                                
                                // Check if this is a relay circuit address (contains /p2p-circuit/)
                                if addr_str.contains("/p2p-circuit/") {
                                    // Extract relay peer ID from the address
                                    // Format: /ip4/.../tcp/.../p2p/<relay-peer-id>/p2p-circuit/p2p/<our-peer-id>
                                    let parts: Vec<&str> = addr_str.split("/p2p/").collect();
                                    if parts.len() >= 2 {
                                        // The relay peer ID is in the first /p2p/ segment
                                        let relay_peer_id = parts[1].split('/').next().unwrap_or("unknown");
                                        info!("Relay reservation ready via peer: {}", relay_peer_id);
                                        let _ = event_tx.send(Event::RelayReservationReady {
                                            relay_peer_id: relay_peer_id.to_string(),
                                            relayed_addr: addr_str,
                                        }).await;
                                    }
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Discovered(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    swarm.behaviour_mut().kad.add_address(&peer_id, _multiaddr);
                                    let _ = event_tx.send(Event::PeerDiscovered(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Mdns(mdns::Event::Expired(list))) => {
                                for (peer_id, _multiaddr) in list {
                                    let _ = event_tx.send(Event::PeerExpired(peer_id.to_string())).await;
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RequestResponse(event)) => {
                                match event {
                                    request_response::Event::Message { peer, message, .. } => {
                                        match message {
                                            request_response::Message::Request { request, channel, .. } => {
                                                let request_id = uuid::Uuid::new_v4().to_string();
                                                response_channels.insert(request_id.clone(), channel);
                                                
                                                let _ = event_tx.send(Event::RequestReceived {
                                                    peer: peer.to_string(),
                                                    request,
                                                    request_id,
                                                }).await;
                                            }
                                            request_response::Message::Response { response, request_id } => {
                                                if let Some(reply) = pending_requests.remove(&request_id) {
                                                    let _ = reply.send(Ok(response));
                                                }
                                            }
                                        }
                                    }
                                    request_response::Event::OutboundFailure { request_id, error, .. } => {
                                        if let Some(reply) = pending_requests.remove(&request_id) {
                                            let _ = reply.send(Err(format!("Outbound failure: {:?}", error)));
                                        }
                                    }
                                    _ => {}
                                }
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RelayServer(relay::Event::ReservationReqAccepted { src_peer_id, .. })) => {
                                if config.enable_relay_server {
                                    info!("Relay reservation accepted for {:?}", src_peer_id);
                                }
                            }
                            // Handle Relay Client events
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::RelayClient(event)) => {
                                match event {
                                    relay::client::Event::ReservationReqAccepted { relay_peer_id, renewal, limit } => {
                                        info!("Relay reservation accepted by {:?}, renewal={}, limit={:?}", relay_peer_id, renewal, limit);
                                        // Build the relayed address format that clients can use to connect to us
                                        // Format: /p2p/<relay-peer-id>/p2p-circuit/p2p/<our-peer-id>
                                        let relayed_addr = format!("/p2p/{}/p2p-circuit/p2p/{}", relay_peer_id, peer_id);
                                        info!("Sending RelayReservationReady event with addr: {}", relayed_addr);
                                        let _ = event_tx.send(Event::RelayReservationReady {
                                            relay_peer_id: relay_peer_id.to_string(),
                                            relayed_addr,
                                        }).await;
                                    }
                                    relay::client::Event::OutboundCircuitEstablished { relay_peer_id, limit } => {
                                        info!("Outbound circuit established via {:?}, limit={:?}", relay_peer_id, limit);
                                    }
                                    relay::client::Event::InboundCircuitEstablished { src_peer_id, limit } => {
                                        info!("Inbound circuit established from {:?}, limit={:?}", src_peer_id, limit);
                                    }
                                }
                            }
                            // Handle Ping events
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Ping(event)) => {
                                match event.result {
                                    Ok(rtt) => {
                                        debug!("Ping success with {:?}: {:?}", event.peer, rtt);
                                    }
                                    Err(e) => {
                                        debug!("Ping failure with {:?}: {:?}", event.peer, e);
                                    }
                                }
                            }
                            // Handle DCUtR (Direct Connection Upgrade through Relay) events
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Dcutr(event)) => {
                                info!("DCUtR event: {:?}", event);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::RoutingUpdated { peer, .. })) => {
                                info!("Kademlia routing updated for peer: {:?}", peer);
                            }
                            SwarmEvent::ConnectionEstablished { peer_id, endpoint, .. } => {
                                info!("Connection established with peer: {:?}", peer_id);
                                debug!("Connection endpoint: {:?}", endpoint);
                                let _ = event_tx.send(Event::PeerConnected(peer_id.to_string())).await;
                                
                                // Check if this is our pending relay connection
                                if let Some((maybe_relay_peer_id, relay_addr)) = pending_relay.take() {
                                    debug!("Checking against pending relay: peer_id={:?}, addr={}", maybe_relay_peer_id, relay_addr);
                                    // Check if this connection matches our pending relay
                                    let is_relay = match maybe_relay_peer_id {
                                        Some(id) => id == peer_id,
                                        None => {
                                            // Check if the connection endpoint matches the relay address we dialed
                                            match endpoint {
                                                libp2p::core::ConnectedPoint::Dialer { ref address, .. } => {
                                                    // Strict matching: Check if endpoint address starts with relay_addr components
                                                    // This prevents false positives where relay_addr is a substring (e.g. just IP)
                                                    let relay_comps: Vec<_> = relay_addr.iter().collect();
                                                    let addr_comps: Vec<_> = address.iter().collect();
                                                    
                                                    debug!("Checking pending relay match: Relay={:?}, Endpoint={:?}", relay_addr, address);
                                                    
                                                    if addr_comps.len() >= relay_comps.len() {
                                                        relay_comps.iter().zip(addr_comps.iter()).all(|(a, b)| a == b)
                                                    } else {
                                                        false
                                                    }
                                                }
                                                _ => {
                                                    debug!("Endpoint not a Dialer, ignoring for relay match");
                                                    false
                                                }
                                            }
                                        }
                                    };

                                    if is_relay {
                                        info!("Connected to relay peer {}, now listening on circuit", peer_id);
                                        
                                        // Build the relay circuit listen address using the ACTUAL endpoint address
                                        // This ensures we have the correct transport/IP/port and avoids malformed addresses
                                        let mut circuit_addr = match endpoint {
                                            libp2p::core::ConnectedPoint::Dialer { address, .. } => address.clone(),
                                            libp2p::core::ConnectedPoint::Listener { send_back_addr, .. } => send_back_addr.clone(), 
                                        };

                                        // Ensure it has the Peer ID
                                        let has_peer_id = circuit_addr.iter().any(|p| matches!(p, libp2p::multiaddr::Protocol::P2p(_)));
                                        if !has_peer_id {
                                            circuit_addr.push(libp2p::multiaddr::Protocol::P2p(peer_id));
                                        }
                                        
                                        // Append p2p-circuit
                                        circuit_addr.push(libp2p::multiaddr::Protocol::P2pCircuit);
                                        
                                        info!("Attempting to listen on relay circuit: {}", circuit_addr);
                                        
                                        if let Err(e) = swarm.listen_on(circuit_addr) {
                                            error!("Failed to listen on relay circuit: {:?}", e);
                                        } else {
                                            info!("Successfully started listening on relay circuit");
                                        }
                                        
                                        // Update the relay peer ID in our records if we didn't know it
                                        if maybe_relay_peer_id.is_none() {
                                            info!("Learned relay Peer ID: {}", peer_id);
                                        }
                                    } else {
                                        // Not our relay, put it back
                                        pending_relay = Some((maybe_relay_peer_id, relay_addr));
                                    }
                                }
                            }

                            SwarmEvent::ConnectionClosed { peer_id, cause, .. } => {
                                info!("Connection closed with peer: {:?}, cause: {:?}", peer_id, cause);
                                let _ = event_tx.send(Event::PeerDisconnected(peer_id.to_string())).await;
                            }
                            SwarmEvent::OutgoingConnectionError { peer_id, error, .. } => {
                                warn!("Outgoing connection error to {:?}: {:?}", peer_id, error);
                            }
                            SwarmEvent::Dialing { peer_id, connection_id } => {
                                debug!("Dialing peer {:?} on connection {:?}", peer_id, connection_id);
                            }
                            SwarmEvent::ListenerError { listener_id, error } => {
                                warn!("Listener error {:?}: {:?}", listener_id, error);
                            }
                            SwarmEvent::Behaviour(MydiaBehaviourEvent::Kad(kad::Event::OutboundQueryProgressed { id, result, .. })) => {
                                match result {
                                    kad::QueryResult::StartProviding(Ok(_)) => {
                                        provided_keys_count += 1;
                                        if let Some(reply) = pending_provides.remove(&id) {
                                            let _ = reply.send(Ok(()));
                                        }
                                    }
                                    kad::QueryResult::StartProviding(Err(e)) => {
                                        if let Some(reply) = pending_provides.remove(&id) {
                                            let _ = reply.send(Err(format!("Failed to provide: {:?}", e)));
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FoundProviders { providers, .. })) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            if let Some(provider) = providers.into_iter().next() {
                                                // Get addresses for this peer from Kademlia routing table
                                                let addresses: Vec<String> = swarm
                                                    .behaviour_mut()
                                                    .kad
                                                    .kbuckets()
                                                    .filter_map(|bucket| {
                                                        bucket.iter().find_map(|entry| {
                                                            if entry.node.key.preimage() == &provider {
                                                                Some(entry.node.value.iter().map(|a| a.to_string()).collect::<Vec<_>>())
                                                            } else {
                                                                None
                                                            }
                                                        })
                                                    })
                                                    .flatten()
                                                    .collect();
                                                
                                                let _ = reply.send(Ok(LookupResult {
                                                    peer_id: provider.to_string(),
                                                    addresses,
                                                }));
                                            } else {
                                                let _ = reply.send(Err("No providers found".to_string()));
                                            }
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Ok(kad::GetProvidersOk::FinishedWithNoAdditionalRecord { .. })) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            let _ = reply.send(Err("Lookup finished with no results".to_string()));
                                        }
                                    }
                                    kad::QueryResult::GetProviders(Err(e)) => {
                                        if let Some(reply) = pending_lookups.remove(&id) {
                                            let _ = reply.send(Err(format!("Lookup failed: {:?}", e)));
                                        }
                                    }
                                    kad::QueryResult::Bootstrap(Ok(_)) => {
                                        info!("Kademlia bootstrap completed");
                                        bootstrap_complete = true;
                                        let _ = event_tx.send(Event::BootstrapCompleted).await;
                                    }
                                    kad::QueryResult::Bootstrap(Err(e)) => {
                                        warn!("Kademlia bootstrap failed: {:?}", e);
                                    }
                                    _ => {}
                                }
                            }
                            SwarmEvent::ListenerClosed { listener_id, reason, addresses } => {
                                warn!("Listener {:?} closed: {:?}, addresses: {:?}", listener_id, reason, addresses);
                            }
                            SwarmEvent::IncomingConnection { local_addr, send_back_addr, .. } => {
                                info!("Incoming connection from {} to {}", send_back_addr, local_addr);
                            }
                            SwarmEvent::IncomingConnectionError { local_addr, send_back_addr, error, .. } => {
                                warn!("Incoming connection error from {} to {}: {:?}", send_back_addr, local_addr, error);
                            }
                            other => {
                                info!("Unhandled swarm event: {:?}", other);
                            }
                        },
                        command = cmd_rx.recv() => match command {
                            Some(Command::Listen(addr_str)) => {
                                if let Ok(addr) = addr_str.parse() {
                                    let _ = swarm.listen_on(addr);
                                }
                            }
                            Some(Command::Dial(addr_str)) => {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    // Extract peer ID from address if present and add to Kademlia
                                    // This ensures request-response can find the peer
                                    let peer_id = addr.iter().find_map(|p| {
                                        if let libp2p::multiaddr::Protocol::P2p(id) = p {
                                            Some(id)
                                        } else {
                                            None
                                        }
                                    });
                                    
                                    if let Some(peer_id) = peer_id {
                                        // Add to Kademlia routing table so request-response can find it
                                        swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
                                    }
                                    
                                    let _ = swarm.dial(addr);
                                }
                            }
                            Some(Command::Bootstrap(addr_str)) => {
                                // Parse the multiaddr and extract peer ID
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    // Extract peer ID from /p2p/... component
                                    let peer_id = addr.iter().find_map(|p| {
                                        if let libp2p::multiaddr::Protocol::P2p(id) = p {
                                            Some(id)
                                        } else {
                                            None
                                        }
                                    });
                                    
                                    if let Some(peer_id) = peer_id {
                                        // Add address to Kademlia routing table
                                        swarm.behaviour_mut().kad.add_address(&peer_id, addr.clone());
                                        // Dial the peer
                                        let _ = swarm.dial(addr);
                                        // Trigger bootstrap
                                        let _ = swarm.behaviour_mut().kad.bootstrap();
                                    }
                                }
                            }
                            Some(Command::ConnectRelay { relay_addr }) => {
                                // Parse the relay multiaddr
                                info!("Connecting to relay: {}", relay_addr);
                                if let Ok(addr) = relay_addr.parse::<Multiaddr>() {
                                    // Try to extract relay peer ID from /p2p/... component
                                    let relay_peer_id = addr.iter().find_map(|p| {
                                        if let libp2p::multiaddr::Protocol::P2p(id) = p {
                                            Some(id)
                                        } else {
                                            None
                                        }
                                    });
                                    
                                    if let Some(relay_peer_id) = relay_peer_id {
                                        // Case 1: Peer ID is present in the address
                                        // Add relay to Kademlia routing table
                                        swarm.behaviour_mut().kad.add_address(&relay_peer_id, addr.clone());
                                        
                                        // Check if we are already connected to the relay
                                        if swarm.is_connected(&relay_peer_id) {
                                            info!("Already connected to relay peer {}, listening on circuit immediately", relay_peer_id);
                                            
                                            // Format: /p2p/<relay-peer-id>/p2p-circuit
                                            let circuit_addr: Multiaddr = format!(
                                                "/p2p/{}/p2p-circuit",
                                                relay_peer_id
                                            ).parse().expect("valid circuit address");
                                            
                                            info!("Listening on relay circuit: {}", circuit_addr);
                                            if let Err(e) = swarm.listen_on(circuit_addr) {
                                                error!("Failed to listen on relay circuit: {:?}", e);
                                            }
                                        } else {
                                            // Store the pending relay info
                                            pending_relay = Some((Some(relay_peer_id), addr.clone()));
                                            
                                            // Dial the relay
                                            if let Err(e) = swarm.dial(addr.clone()) {
                                                error!("Failed to dial relay: {:?}", e);
                                                pending_relay = None;
                                            } else {
                                                info!("Dialing relay peer: {}", relay_peer_id);
                                            }
                                        }
                                    } else {
                                        // Case 2: Peer ID is missing from address
                                        // We will dial the address and wait for connection to established to learn the Peer ID
                                        info!("Relay address missing peer ID, will learn from connection: {}", relay_addr);
                                        debug!("Pending relay address parsed: {:?}", addr);
                                        
                                        // Store pending relay with None peer ID
                                        pending_relay = Some((None, addr.clone()));
                                        
                                        // Dial the address (without Peer ID)
                                        if let Err(e) = swarm.dial(addr.clone()) {
                                            error!("Failed to dial relay address: {:?}", e);
                                            pending_relay = None;
                                        } else {
                                            info!("Dialing relay address: {}", addr);
                                        }
                                    }
                                } else {
                                    error!("Invalid relay address: {}", relay_addr);
                                }
                            }
                            Some(Command::AddExternalAddress(addr_str)) => {
                                if let Ok(addr) = addr_str.parse::<Multiaddr>() {
                                    info!("Adding external address: {}", addr);
                                    swarm.add_external_address(addr);
                                } else {
                                    warn!("Invalid external address: {}", addr_str);
                                }
                            }
                            Some(Command::ProvideClaimCode { claim_code, reply }) => {
                                let key = claim_code_to_key(&claim_code);
                                match swarm.behaviour_mut().kad.start_providing(key) {
                                    Ok(query_id) => {
                                        pending_provides.insert(query_id, reply);
                                    }
                                    Err(e) => {
                                        let _ = reply.send(Err(format!("Failed to start providing: {:?}", e)));
                                    }
                                }
                            }
                            Some(Command::LookupClaimCode { claim_code, reply }) => {
                                let key = claim_code_to_key(&claim_code);
                                let query_id = swarm.behaviour_mut().kad.get_providers(key);
                                pending_lookups.insert(query_id, reply);
                            }
                            Some(Command::SendRequest { peer, request, reply }) => {
                                if let Ok(peer_id) = peer.parse::<PeerId>() {
                                    let request_id = swarm.behaviour_mut().request_response.send_request(&peer_id, request);
                                    pending_requests.insert(request_id, reply);
                                } else {
                                    let _ = reply.send(Err("Invalid peer ID".to_string()));
                                }
                            }
                            Some(Command::SendResponse { request_id, response }) => {
                                if let Some(channel) = response_channels.remove(&request_id) {
                                    let _ = swarm.behaviour_mut().request_response.send_response(channel, response);
                                }
                            }
                            Some(Command::GetDhtStats { reply }) => {
                                // Count peers in routing table
                                let routing_table_size: usize = swarm
                                    .behaviour_mut()
                                    .kad
                                    .kbuckets()
                                    .map(|bucket| bucket.num_entries())
                                    .sum();
                                
                                let _ = reply.send(DhtStats {
                                    routing_table_size,
                                    provided_keys_count,
                                    bootstrap_complete,
                                });
                            }
                            None => {
                                info!(" Command channel closed, swarm loop exiting");
                                return;
                            }
                        }
                    }
                }
            });
            }));
            
            // Log if the swarm thread panicked
            if let Err(panic_info) = result {
                let panic_msg = if let Some(s) = panic_info.downcast_ref::<&str>() {
                    s.to_string()
                } else if let Some(s) = panic_info.downcast_ref::<String>() {
                    s.clone()
                } else {
                    "Unknown panic".to_string()
                };
                info!(" PANIC in swarm thread: {}", panic_msg);
            }
            info!(" Swarm thread exiting");
        });

        (Host { cmd_tx, event_rx: std::sync::Arc::new(tokio::sync::Mutex::new(event_rx)), peer_id }, peer_id_str)
    }

    pub fn listen(&self, addr: String) -> Result<(), String> {
        info!(" listen() called with addr: {}", addr);
        match self.cmd_tx.try_send(Command::Listen(addr.clone())) {
            Ok(_) => {
                info!(" listen() command sent successfully for: {}", addr);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("listen send_failed for {}: {}", addr, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    pub fn dial(&self, addr: String) -> Result<(), String> {
        info!(" dial() called with addr: {}", addr);
        match self.cmd_tx.try_send(Command::Dial(addr.clone())) {
            Ok(_) => {
                info!(" dial() command sent successfully for: {}", addr);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("dial send_failed for {}: {}", addr, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    pub async fn send_request(&self, peer: String, request: MydiaRequest) -> Result<MydiaResponse, String> {
        info!(" send_request() called for peer: {}", peer);
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.send(Command::SendRequest { peer: peer.clone(), request, reply: tx }).await {
            Ok(_) => {
                info!(" send_request() command sent, waiting for response from: {}", peer);
                match rx.await {
                    Ok(res) => {
                        info!(" send_request() got response from: {}", peer);
                        res
                    }
                    Err(e) => {
                        let err_msg = format!("send_request response channel closed for {}: {}", peer, e);
                        info!(" {}", err_msg);
                        Err(err_msg)
                    }
                }
            }
            Err(e) => {
                let err_msg = format!("send_request send_failed for {}: {}", peer, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    pub fn send_response(&self, request_id: String, response: MydiaResponse) -> Result<(), String> {
        info!(" send_response() called for request_id: {}", request_id);
        match self.cmd_tx.try_send(Command::SendResponse { request_id: request_id.clone(), response }) {
            Ok(_) => {
                info!(" send_response() command sent successfully for: {}", request_id);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("send_response send_failed for {}: {}", request_id, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    /// Add a bootstrap peer and initiate DHT bootstrap.
    /// The address should include the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
    pub fn bootstrap(&self, addr: String) -> Result<(), String> {
        info!(" bootstrap() called with addr: {}", addr);
        match self.cmd_tx.try_send(Command::Bootstrap(addr.clone())) {
            Ok(_) => {
                info!(" bootstrap() command sent successfully for: {}", addr);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("bootstrap send_failed for {}: {}", addr, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    /// Connect to a relay server and request a reservation.
    /// This allows other peers to connect to us through the relay.
    /// The address should include the relay's peer ID, e.g., "/ip4/1.2.3.4/tcp/4001/p2p/12D3..."
    /// or "/dns4/p2p.mydia.dev/tcp/4001/p2p/12D3..."
    pub fn connect_relay(&self, relay_addr: String) -> Result<(), String> {
        info!(" connect_relay() called with addr: {}", relay_addr);
        match self.cmd_tx.try_send(Command::ConnectRelay { relay_addr: relay_addr.clone() }) {
            Ok(_) => {
                info!(" connect_relay() command sent successfully for: {}", relay_addr);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("connect_relay send_failed for {}: {}", relay_addr, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    /// Add an external address that this host is reachable at.
    /// This is important for relay servers to include their addresses in relay reservations.
    /// The address should be a full multiaddr without the peer ID, e.g., "/ip4/1.2.3.4/tcp/4001"
    /// or "/dns4/p2p.mydia.dev/tcp/4001"
    pub fn add_external_address(&self, addr: String) -> Result<(), String> {
        info!(" add_external_address() called with addr: {}", addr);
        match self.cmd_tx.try_send(Command::AddExternalAddress(addr.clone())) {
            Ok(_) => {
                info!(" add_external_address() command sent successfully for: {}", addr);
                Ok(())
            }
            Err(e) => {
                let err_msg = format!("add_external_address send_failed for {}: {}", addr, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    /// Provide a claim code on the DHT, announcing this peer as the provider.
    /// Call this when a new claim code is generated.
    /// This is a blocking version suitable for calling from NIFs.
    pub fn provide_claim_code(&self, claim_code: String) -> Result<(), String> {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::ProvideClaimCode { claim_code, reply: tx }) {
            Ok(_) => {
                // Block waiting for the result
                match rx.blocking_recv() {
                    Ok(res) => res,
                    Err(_) => Err("Response channel closed".to_string()),
                }
            }
            Err(_) => Err("send_failed".to_string()),
        }
    }

    /// Lookup a claim code on the DHT to find the provider peer.
    /// Returns the peer ID and addresses of the server that provided this claim code.
    pub async fn lookup_claim_code(&self, claim_code: String) -> Result<LookupResult, String> {
        info!(" lookup_claim_code() called for: {}", claim_code);
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.send(Command::LookupClaimCode { claim_code: claim_code.clone(), reply: tx }).await {
            Ok(_) => {
                info!(" lookup_claim_code() command sent, waiting for response");
                match rx.await {
                    Ok(res) => {
                        match &res {
                            Ok(lookup) => info!(" lookup_claim_code() found peer: {}", lookup.peer_id),
                            Err(e) => info!(" lookup_claim_code() DHT error: {}", e),
                        }
                        res
                    }
                    Err(e) => {
                        let err_msg = format!("lookup_claim_code response channel closed for {}: {}", claim_code, e);
                        info!(" {}", err_msg);
                        Err(err_msg)
                    }
                }
            }
            Err(e) => {
                let err_msg = format!("lookup_claim_code send_failed for {}: {}", claim_code, e);
                info!(" {}", err_msg);
                Err(err_msg)
            }
        }
    }

    /// Get DHT statistics (routing table size, provided keys, bootstrap status).
    /// This is a blocking call suitable for NIFs.
    pub fn get_dht_stats(&self) -> DhtStats {
        let (tx, rx) = oneshot::channel();
        match self.cmd_tx.blocking_send(Command::GetDhtStats { reply: tx }) {
            Ok(_) => {
                rx.blocking_recv().unwrap_or(DhtStats {
                    routing_table_size: 0,
                    provided_keys_count: 0,
                    bootstrap_complete: false,
                })
            }
            Err(_) => DhtStats {
                routing_table_size: 0,
                provided_keys_count: 0,
                bootstrap_complete: false,
            },
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_relay_matching_logic() {
        let peer_id = identity::Keypair::generate_ed25519().public().to_peer_id();
        let peer_id_str = peer_id.to_string();
        
        let relay_str = "/ip4/1.2.3.4/tcp/4001";
        let relay_addr: Multiaddr = relay_str.parse().unwrap();
        
        // Case 1: Exact match (except p2p suffix)
        let endpoint_str = format!("/ip4/1.2.3.4/tcp/4001/p2p/{}", peer_id_str);
        let endpoint_addr: Multiaddr = endpoint_str.parse().unwrap();
        
        let relay_comps: Vec<_> = relay_addr.iter().collect();
        let addr_comps: Vec<_> = endpoint_addr.iter().collect();
        
        let is_match = if addr_comps.len() >= relay_comps.len() {
            relay_comps.iter().zip(addr_comps.iter()).all(|(a, b)| a == b)
        } else {
            false
        };
        assert!(is_match, "Should match correct endpoint");

        // Case 2: Partial match (False positive prevention)
        // Relay has port 4001, Endpoint has port 4002
        let bad_endpoint_str = format!("/ip4/1.2.3.4/tcp/4002/p2p/{}", peer_id_str);
        let bad_endpoint_addr: Multiaddr = bad_endpoint_str.parse().unwrap();
        let bad_addr_comps: Vec<_> = bad_endpoint_addr.iter().collect();
        
        let is_match_bad = if bad_addr_comps.len() >= relay_comps.len() {
            relay_comps.iter().zip(bad_addr_comps.iter()).all(|(a, b)| a == b)
        } else {
            false
        };
        assert!(!is_match_bad, "Should NOT match different port");
        
        // Case 3: Relay addr is just IP (Incomplete)
        let incomplete_relay_str = "/ip4/1.2.3.4";
        let incomplete_relay_addr: Multiaddr = incomplete_relay_str.parse().unwrap();
        let incomplete_comps: Vec<_> = incomplete_relay_addr.iter().collect();
        
        // It matches the IP part of the endpoint
        let is_match_incomplete = if addr_comps.len() >= incomplete_comps.len() {
            incomplete_comps.iter().zip(addr_comps.iter()).all(|(a, b)| a == b)
        } else {
            false
        };
        assert!(is_match_incomplete, "Matches prefix (IP only)");
        
        // Verify circuit construction fix
        let mut circuit_addr = endpoint_addr.clone();
        
        // Logic: ensure p2p ID and append p2p-circuit
        // Check if P2p exists
        let _has_peer_id = circuit_addr.iter().any(|p| matches!(p, libp2p::multiaddr::Protocol::P2p(_)));
        // It does
        
        circuit_addr.push(libp2p::multiaddr::Protocol::P2pCircuit);
        
        assert_eq!(circuit_addr.to_string(), format!("/ip4/1.2.3.4/tcp/4001/p2p/{}/p2p-circuit", peer_id_str));
    }
}
