mod frb_generated; /* AUTO INJECTED BY flutter_rust_bridge. This line may not be accurate, and you can change it according to your needs. */
use crate::frb_generated::StreamSink;
use flutter_rust_bridge::frb;
use mydia_p2p_core::{
    runtime, Event, GraphQLRequest, HlsRequest, HlsRequester, Host, HostConfig, LoadContentRequest,
    MydiaRequest, MydiaResponse, PairingRequest, PeerConnectionType, PlaybackSnapshot,
    PlaybackState, RemoteControlRequest, RemoteControlResponse, TargetCapabilities, TrackInfo,
};
use std::sync::Arc;
use tokio::sync::{mpsc, Mutex};
#[cfg(not(target_arch = "wasm32"))]
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

    init_logging();

    log::info!("mydia_player_p2p initialized");
}

/// Point `tracing` at the platform's log sink.
///
/// Must run before `Host::new`, so iroh's startup logs are captured.
#[cfg(not(target_arch = "wasm32"))]
fn init_logging() {
    let filter = EnvFilter::try_from_default_env().unwrap_or_else(|_| {
        EnvFilter::new("info,mydia_p2p_core=debug,iroh=info,noq=warn,rustls=warn")
    });

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
}

/// A browser build deliberately installs no tracing subscriber.
///
/// `tracing_subscriber::fmt` cannot be used here on two counts: its default
/// timer calls `std::time::SystemTime::now`, which panics outright on
/// `wasm32-unknown-unknown`, and its default writer is stdout, which a browser
/// does not have. Leaving the global dispatcher unset is what makes
/// `tracing`'s `log` feature, enabled for this target only, forward every
/// event to the `log` crate, and `setup_default_user_utils` above has already
/// pointed `log` at the browser console. That call asks for `Trace`, which is
/// unreadable at iroh's volume, so the ceiling is lowered here.
#[cfg(target_arch = "wasm32")]
fn init_logging() {
    log::set_max_level(log::LevelFilter::Info);
}

pub struct P2pHost {
    inner: Host,
    hls_requester: HlsRequester,
    /// Fed by a dispatcher spawned in `init`. `event_stream` reads from this
    /// instead of `inner.event_rx` directly.
    ///
    /// Splitting it out of `inner.event_rx` is what makes control-request
    /// routing (see `control_rx` below) independent of whether Dart ever
    /// calls `event_stream()`. See the dispatcher in `init` for the full
    /// reasoning.
    generic_event_rx: Arc<Mutex<mpsc::UnboundedReceiver<Event>>>,
    /// Inbound control requests, routed here by the same `init` dispatcher.
    /// Drained by `remote_control_stream`.
    control_rx: Arc<Mutex<mpsc::Receiver<FlutterInboundControlRequest>>>,
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
    /// Base64url-encoded JSON describing what this client can decode. Same
    /// value the HTTP path sends in the X-Mydia-Device-Profile header; the
    /// p2p transport has no headers, so it rides along in the request body.
    pub device_profile: Option<String>,
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

/// A control command, mirrored for the bridge.
#[frb(non_opaque)]
#[derive(Clone, Debug, PartialEq)]
pub enum FlutterRemoteControlRequest {
    Hello {
        controller_name: String,
        protocol_version: u32,
    },
    GetState,
    Play,
    Pause,
    Stop,
    Seek {
        position_ms: u64,
    },
    SetVolume {
        level: f32,
    },
    SetMute {
        muted: bool,
    },
    SelectAudioTrack {
        id: Option<String>,
    },
    SelectSubtitleTrack {
        id: Option<String>,
    },
    NextEpisode,
    PreviousEpisode,
    LoadContent(FlutterLoadContentRequest),
}

#[derive(Clone, Debug, PartialEq)]
pub struct FlutterLoadContentRequest {
    pub media_item_id: String,
    pub episode_id: Option<String>,
    pub position_ms: u64,
    pub audio_track: Option<String>,
    pub subtitle_track: Option<String>,
    pub autoplay: bool,
}

#[frb(non_opaque)]
#[derive(Clone, Debug, PartialEq)]
pub enum FlutterRemoteControlResponse {
    Welcome {
        target_name: String,
        protocol_version: u32,
        capabilities: FlutterTargetCapabilities,
    },
    State(FlutterPlaybackSnapshot),
    Accepted,
    NotAuthorized,
    NotPlaying,
    Unsupported,
    Error(String),
}

#[frb(non_opaque)]
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FlutterPlaybackState {
    Idle,
    Loading,
    Buffering,
    Playing,
    Paused,
    Ended,
    Error,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct FlutterTargetCapabilities {
    pub volume: bool,
    pub track_selection: bool,
    pub next_previous: bool,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FlutterTrackInfo {
    pub id: String,
    pub label: String,
    pub language: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct FlutterPlaybackSnapshot {
    pub state: FlutterPlaybackState,
    pub media_item_id: Option<String>,
    pub episode_id: Option<String>,
    pub title: String,
    pub subtitle: Option<String>,
    pub image_url: Option<String>,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub volume: Option<f32>,
    pub muted: bool,
    pub audio_tracks: Vec<FlutterTrackInfo>,
    pub subtitle_tracks: Vec<FlutterTrackInfo>,
    pub selected_audio: Option<String>,
    pub selected_subtitle: Option<String>,
    pub capabilities: FlutterTargetCapabilities,
    pub sequence: u64,
}

/// An inbound command with the identifiers needed to answer it.
///
/// `peer` is the dialing node's ID, authenticated by iroh during the handshake.
/// It is what the Dart roster check tests against, and it cannot be forged by
/// the payload.
#[derive(Clone, Debug, PartialEq)]
pub struct FlutterInboundControlRequest {
    pub peer: String,
    pub request_id: String,
    pub request: FlutterRemoteControlRequest,
}

impl From<FlutterTargetCapabilities> for TargetCapabilities {
    fn from(c: FlutterTargetCapabilities) -> Self {
        TargetCapabilities {
            volume: c.volume,
            track_selection: c.track_selection,
            next_previous: c.next_previous,
        }
    }
}

impl From<TargetCapabilities> for FlutterTargetCapabilities {
    fn from(c: TargetCapabilities) -> Self {
        FlutterTargetCapabilities {
            volume: c.volume,
            track_selection: c.track_selection,
            next_previous: c.next_previous,
        }
    }
}

impl From<FlutterPlaybackState> for PlaybackState {
    fn from(s: FlutterPlaybackState) -> Self {
        match s {
            FlutterPlaybackState::Idle => PlaybackState::Idle,
            FlutterPlaybackState::Loading => PlaybackState::Loading,
            FlutterPlaybackState::Buffering => PlaybackState::Buffering,
            FlutterPlaybackState::Playing => PlaybackState::Playing,
            FlutterPlaybackState::Paused => PlaybackState::Paused,
            FlutterPlaybackState::Ended => PlaybackState::Ended,
            FlutterPlaybackState::Error => PlaybackState::Error,
        }
    }
}

impl From<PlaybackState> for FlutterPlaybackState {
    fn from(s: PlaybackState) -> Self {
        match s {
            PlaybackState::Idle => FlutterPlaybackState::Idle,
            PlaybackState::Loading => FlutterPlaybackState::Loading,
            PlaybackState::Buffering => FlutterPlaybackState::Buffering,
            PlaybackState::Playing => FlutterPlaybackState::Playing,
            PlaybackState::Paused => FlutterPlaybackState::Paused,
            PlaybackState::Ended => FlutterPlaybackState::Ended,
            PlaybackState::Error => FlutterPlaybackState::Error,
        }
    }
}

impl From<FlutterTrackInfo> for TrackInfo {
    fn from(t: FlutterTrackInfo) -> Self {
        TrackInfo {
            id: t.id,
            label: t.label,
            language: t.language,
        }
    }
}

impl From<TrackInfo> for FlutterTrackInfo {
    fn from(t: TrackInfo) -> Self {
        FlutterTrackInfo {
            id: t.id,
            label: t.label,
            language: t.language,
        }
    }
}

impl From<FlutterLoadContentRequest> for LoadContentRequest {
    fn from(r: FlutterLoadContentRequest) -> Self {
        LoadContentRequest {
            media_item_id: r.media_item_id,
            episode_id: r.episode_id,
            position_ms: r.position_ms,
            audio_track: r.audio_track,
            subtitle_track: r.subtitle_track,
            autoplay: r.autoplay,
        }
    }
}

impl From<LoadContentRequest> for FlutterLoadContentRequest {
    fn from(r: LoadContentRequest) -> Self {
        FlutterLoadContentRequest {
            media_item_id: r.media_item_id,
            episode_id: r.episode_id,
            position_ms: r.position_ms,
            audio_track: r.audio_track,
            subtitle_track: r.subtitle_track,
            autoplay: r.autoplay,
        }
    }
}

impl From<FlutterRemoteControlRequest> for RemoteControlRequest {
    fn from(r: FlutterRemoteControlRequest) -> Self {
        match r {
            FlutterRemoteControlRequest::Hello {
                controller_name,
                protocol_version,
            } => RemoteControlRequest::Hello {
                controller_name,
                protocol_version,
            },
            FlutterRemoteControlRequest::GetState => RemoteControlRequest::GetState,
            FlutterRemoteControlRequest::Play => RemoteControlRequest::Play,
            FlutterRemoteControlRequest::Pause => RemoteControlRequest::Pause,
            FlutterRemoteControlRequest::Stop => RemoteControlRequest::Stop,
            FlutterRemoteControlRequest::Seek { position_ms } => {
                RemoteControlRequest::Seek { position_ms }
            }
            FlutterRemoteControlRequest::SetVolume { level } => {
                RemoteControlRequest::SetVolume { level }
            }
            FlutterRemoteControlRequest::SetMute { muted } => {
                RemoteControlRequest::SetMute { muted }
            }
            FlutterRemoteControlRequest::SelectAudioTrack { id } => {
                RemoteControlRequest::SelectAudioTrack { id }
            }
            FlutterRemoteControlRequest::SelectSubtitleTrack { id } => {
                RemoteControlRequest::SelectSubtitleTrack { id }
            }
            FlutterRemoteControlRequest::NextEpisode => RemoteControlRequest::NextEpisode,
            FlutterRemoteControlRequest::PreviousEpisode => RemoteControlRequest::PreviousEpisode,
            FlutterRemoteControlRequest::LoadContent(req) => {
                RemoteControlRequest::LoadContent(req.into())
            }
        }
    }
}

impl From<RemoteControlRequest> for FlutterRemoteControlRequest {
    fn from(r: RemoteControlRequest) -> Self {
        match r {
            RemoteControlRequest::Hello {
                controller_name,
                protocol_version,
            } => FlutterRemoteControlRequest::Hello {
                controller_name,
                protocol_version,
            },
            RemoteControlRequest::GetState => FlutterRemoteControlRequest::GetState,
            RemoteControlRequest::Play => FlutterRemoteControlRequest::Play,
            RemoteControlRequest::Pause => FlutterRemoteControlRequest::Pause,
            RemoteControlRequest::Stop => FlutterRemoteControlRequest::Stop,
            RemoteControlRequest::Seek { position_ms } => {
                FlutterRemoteControlRequest::Seek { position_ms }
            }
            RemoteControlRequest::SetVolume { level } => {
                FlutterRemoteControlRequest::SetVolume { level }
            }
            RemoteControlRequest::SetMute { muted } => {
                FlutterRemoteControlRequest::SetMute { muted }
            }
            RemoteControlRequest::SelectAudioTrack { id } => {
                FlutterRemoteControlRequest::SelectAudioTrack { id }
            }
            RemoteControlRequest::SelectSubtitleTrack { id } => {
                FlutterRemoteControlRequest::SelectSubtitleTrack { id }
            }
            RemoteControlRequest::NextEpisode => FlutterRemoteControlRequest::NextEpisode,
            RemoteControlRequest::PreviousEpisode => FlutterRemoteControlRequest::PreviousEpisode,
            RemoteControlRequest::LoadContent(req) => {
                FlutterRemoteControlRequest::LoadContent(req.into())
            }
        }
    }
}

impl From<FlutterRemoteControlResponse> for RemoteControlResponse {
    fn from(r: FlutterRemoteControlResponse) -> Self {
        match r {
            FlutterRemoteControlResponse::Welcome {
                target_name,
                protocol_version,
                capabilities,
            } => RemoteControlResponse::Welcome {
                target_name,
                protocol_version,
                capabilities: capabilities.into(),
            },
            FlutterRemoteControlResponse::State(snapshot) => {
                RemoteControlResponse::State(snapshot.into())
            }
            FlutterRemoteControlResponse::Accepted => RemoteControlResponse::Accepted,
            FlutterRemoteControlResponse::NotAuthorized => RemoteControlResponse::NotAuthorized,
            FlutterRemoteControlResponse::NotPlaying => RemoteControlResponse::NotPlaying,
            FlutterRemoteControlResponse::Unsupported => RemoteControlResponse::Unsupported,
            FlutterRemoteControlResponse::Error(e) => RemoteControlResponse::Error(e),
        }
    }
}

impl From<RemoteControlResponse> for FlutterRemoteControlResponse {
    fn from(r: RemoteControlResponse) -> Self {
        match r {
            RemoteControlResponse::Welcome {
                target_name,
                protocol_version,
                capabilities,
            } => FlutterRemoteControlResponse::Welcome {
                target_name,
                protocol_version,
                capabilities: capabilities.into(),
            },
            RemoteControlResponse::State(snapshot) => {
                FlutterRemoteControlResponse::State(snapshot.into())
            }
            RemoteControlResponse::Accepted => FlutterRemoteControlResponse::Accepted,
            RemoteControlResponse::NotAuthorized => FlutterRemoteControlResponse::NotAuthorized,
            RemoteControlResponse::NotPlaying => FlutterRemoteControlResponse::NotPlaying,
            RemoteControlResponse::Unsupported => FlutterRemoteControlResponse::Unsupported,
            RemoteControlResponse::Error(e) => FlutterRemoteControlResponse::Error(e),
        }
    }
}

impl From<FlutterPlaybackSnapshot> for PlaybackSnapshot {
    fn from(s: FlutterPlaybackSnapshot) -> Self {
        PlaybackSnapshot {
            state: s.state.into(),
            media_item_id: s.media_item_id,
            episode_id: s.episode_id,
            title: s.title,
            subtitle: s.subtitle,
            image_url: s.image_url,
            position_ms: s.position_ms,
            duration_ms: s.duration_ms,
            volume: s.volume,
            muted: s.muted,
            audio_tracks: s.audio_tracks.into_iter().map(Into::into).collect(),
            subtitle_tracks: s.subtitle_tracks.into_iter().map(Into::into).collect(),
            selected_audio: s.selected_audio,
            selected_subtitle: s.selected_subtitle,
            capabilities: s.capabilities.into(),
            sequence: s.sequence,
        }
    }
}

impl From<PlaybackSnapshot> for FlutterPlaybackSnapshot {
    fn from(s: PlaybackSnapshot) -> Self {
        FlutterPlaybackSnapshot {
            state: s.state.into(),
            media_item_id: s.media_item_id,
            episode_id: s.episode_id,
            title: s.title,
            subtitle: s.subtitle,
            image_url: s.image_url,
            position_ms: s.position_ms,
            duration_ms: s.duration_ms,
            volume: s.volume,
            muted: s.muted,
            audio_tracks: s.audio_tracks.into_iter().map(Into::into).collect(),
            subtitle_tracks: s.subtitle_tracks.into_iter().map(Into::into).collect(),
            selected_audio: s.selected_audio,
            selected_subtitle: s.selected_subtitle,
            capabilities: s.capabilities.into(),
            sequence: s.sequence,
        }
    }
}

/// Drains `event_rx`, routing an inbound `RemoteControl` request onto
/// `control_tx` and every other event onto `generic_tx`. Spawned once,
/// unconditionally, by `P2pHost::init` — see the comment at that call site
/// for why splitting the two here (rather than inline in `event_stream`'s
/// own loop) matters, and why the generic side is unbounded.
///
/// Admission onto `control_tx` is `try_send`, not an awaited `send`,
/// deliberately. `control_tx` is bounded at 32 specifically so a Dart side
/// that never subscribes (or whose `remote_control_stream` sink closed)
/// cannot make this dispatcher accumulate requests forever — but a bounded
/// channel enforces that bound by having `send` block once it is full, and
/// this is the same loop that has to keep draining `event_rx` for the
/// generic side too. An awaited `send` here would stop draining `event_rx`
/// the moment the control side backed up, taking generic event delivery
/// down with it — exactly the coupling this split exists to avoid. Both
/// `Full` (32 unconsumed) and `Closed` (no receiver at all) mean the same
/// thing operationally — nobody is currently able to receive this control
/// request — so both are handled the same way: the request is dropped and
/// logged, and the loop moves on to keep draining `event_rx`.
async fn run_event_dispatcher(
    event_rx: Arc<Mutex<mpsc::Receiver<Event>>>,
    control_tx: mpsc::Sender<FlutterInboundControlRequest>,
    generic_tx: mpsc::UnboundedSender<Event>,
) {
    let mut event_rx = event_rx.lock().await;
    while let Some(event) = event_rx.recv().await {
        match event {
            Event::RequestReceived {
                peer,
                request: MydiaRequest::RemoteControl(req),
                request_id,
            } => {
                if let Err(err) = control_tx.try_send(FlutterInboundControlRequest {
                    peer,
                    request_id,
                    request: req.into(),
                }) {
                    let reason = match err {
                        mpsc::error::TrySendError::Full(_) => {
                            "the control channel is full (32 unconsumed requests)"
                        }
                        mpsc::error::TrySendError::Closed(_) => {
                            "the control channel has no receiver"
                        }
                    };
                    log::warn!("Dropping inbound control request: {reason}");
                }
            }
            other => {
                // An error here just means no `event_stream` subscriber is
                // currently listening; keep draining `event_rx` regardless
                // so control routing above is never blocked by it.
                let _ = generic_tx.send(other);
            }
        }
    }
}

impl P2pHost {
    /// Initialize a new P2P host with optional custom relay URL.
    ///
    /// `keypair_bytes` is the node's raw 32-byte Ed25519 secret. A browser has
    /// no filesystem, so it reads the secret out of IndexedDB and hands it in
    /// here. Native passes None and leaves the identity to the core, which is
    /// where it was already decided. A slice of the wrong length is dropped
    /// rather than trusted, which costs a fresh identity but never a
    /// malformed one.
    #[frb(sync)]
    pub fn init(relay_url: Option<String>, keypair_bytes: Option<Vec<u8>>) -> (Self, String) {
        let keypair_supplied = keypair_bytes.is_some();
        log::info!(
            "P2pHost::init() called with relay_url: {relay_url:?}, keypair_supplied: {keypair_supplied}"
        );
        let keypair_bytes = keypair_bytes.and_then(|bytes| {
            let len = bytes.len();
            <[u8; 32]>::try_from(bytes.as_slice())
                .inspect_err(|_| {
                    log::warn!(
                        "Ignoring keypair_bytes of length {len} (expected 32); generating a new identity"
                    );
                })
                .ok()
        });
        let config = HostConfig {
            relay_url,
            bind_port: None,
            keypair_path: None,
            keypair_bytes,
        };
        let (host, node_id) = Host::new(config);
        let hls_requester = host.hls_requester();
        log::info!("P2pHost created with node_id: {}", node_id);

        // Fan `inner.event_rx` out into two channels: one carrying inbound
        // control requests for `remote_control_stream`, the other carrying
        // everything else for `event_stream` to format into its
        // colon-delimited strings.
        //
        // This dispatcher is spawned here, unconditionally, rather than
        // inline inside `event_stream`'s own loop. If control routing lived
        // there instead, it would only run while a Dart caller happened to
        // have an active `event_stream()` subscription — `remote_control_stream()`
        // on its own would silently receive nothing, with no error anywhere,
        // because nothing would ever be draining `inner.event_rx` to find the
        // control requests in the first place. `P2pService.initialize()`
        // does always subscribe to `event_stream()` today, but that is an
        // application-level habit, not a guarantee this layer enforces, and
        // this file is exactly where guaranteeing it costs nothing. Spawning
        // the dispatcher immediately here means `remote_control_stream()`
        // gets inbound requests whether or not `event_stream()` is ever
        // called at all.
        //
        // The generic side uses an unbounded channel on purpose.
        // `inner.event_rx` is bounded at 100 and already backpressures the
        // whole host event loop if it is never drained (a pre-existing
        // property of every event type, not something introduced here).
        // Routing the generic side through another *bounded* channel would
        // reproduce that stall one hop later inside this dispatcher's own
        // loop, and while stalled there it would stop reading `inner.event_rx`
        // altogether — taking control-request delivery down with it, which
        // is precisely the coupling this split exists to remove. Unbounded
        // avoids that at the cost of unbounded growth if `event_stream` is
        // never consumed; connection-lifecycle events are small and rare
        // enough that this is a reasonable trade.
        //
        // The control side stays bounded at 32 (below), for the opposite
        // reason: an unconsumed inbound control request is a request nobody
        // will ever answer, so bounding it caps how much of that this
        // dispatcher will accumulate. See `run_event_dispatcher`'s own doc
        // for why admission onto it has to be non-blocking despite that.
        let (generic_tx, generic_rx) = mpsc::unbounded_channel::<Event>();
        let (control_tx, control_rx) = mpsc::channel::<FlutterInboundControlRequest>(32);

        let event_rx = host.event_rx.clone();
        let _guard = runtime::enter();
        runtime::spawn(run_event_dispatcher(event_rx, control_tx, generic_tx));

        (
            P2pHost {
                inner: host,
                hls_requester,
                generic_event_rx: Arc::new(Mutex::new(generic_rx)),
                control_rx: Arc::new(Mutex::new(control_rx)),
            },
            node_id,
        )
    }

    /// Get this node's EndpointAddr as JSON for sharing.
    pub async fn get_node_addr(&self) -> String {
        self.inner.get_node_addr().await
    }

    /// Dial a peer using their EndpointAddr JSON.
    pub async fn dial(&self, endpoint_addr_json: String) -> anyhow::Result<()> {
        log::info!("P2pHost::dial() called");
        match self.inner.dial(endpoint_addr_json).await {
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
    ///
    /// Reads from `generic_event_rx`, not `inner.event_rx` directly: a
    /// dispatcher spawned once in `init` already pulled inbound control
    /// requests out onto their own channel, so subscribing here is *not*
    /// required for `remote_control_stream` to work. See `init` for why that
    /// independence matters.
    pub fn event_stream(&self, sink: StreamSink<String>) -> anyhow::Result<()> {
        log::info!("P2pHost::event_stream() called");
        let rx = self.generic_event_rx.clone();

        // Entering the core's runtime rather than spawning a thread with a
        // runtime of its own: this is called from the Dart isolate thread,
        // which has no ambient reactor for `spawn` to attach to, and a browser
        // has no thread to spawn at all. `enter` is a no-op on wasm, where the
        // task lands on the microtask queue instead.
        let _guard = runtime::enter();
        runtime::spawn(async move {
            let mut rx = rx.lock().await;
            log::info!("event_stream listening for events");
            while let Some(event) = rx.recv().await {
                let msg = match event {
                    Event::Connected {
                        peer_id,
                        connection_type,
                    } => format!("connected:{}:{}", peer_id, connection_type.as_str()),
                    Event::Disconnected(peer_id) => format!("disconnected:{}", peer_id),
                    Event::RelayConnected => "relay_connected".to_string(),
                    Event::Ready { node_addr } => format!("ready:{}", node_addr),
                    Event::RequestReceived { .. } => {
                        // RemoteControl requests never reach this channel:
                        // the `init` dispatcher already routed them to
                        // `remote_control_stream`. Every other inbound
                        // request is still a server role this client does
                        // not handle.
                        continue;
                    }
                    Event::HlsStreamRequest { .. } => {
                        // Client doesn't handle incoming HLS requests
                        continue;
                    }
                    Event::ConnectionTypeChanged {
                        peer_id,
                        connection_type,
                    } => {
                        format!(
                            "connection_type_changed:{}:{}",
                            peer_id,
                            connection_type.as_str()
                        )
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
        Ok(())
    }

    /// Stream inbound control requests to Flutter.
    ///
    /// Separate from `event_stream` on purpose: that one is a colon-delimited
    /// string protocol, which cannot carry a structured command. This mirrors
    /// `send_hls_request_streaming`, which is already typed.
    ///
    /// Unlike `send_hls_request_streaming`, this does not depend on
    /// `event_stream` being subscribed to: the `init` dispatcher feeds
    /// `control_rx` independently. Calling only this method, without ever
    /// calling `event_stream()`, is a fully supported way to act as a
    /// control target.
    pub fn remote_control_stream(
        &self,
        sink: StreamSink<FlutterInboundControlRequest>,
    ) -> anyhow::Result<()> {
        let rx = self.control_rx.clone();
        let _guard = runtime::enter();
        runtime::spawn(async move {
            let mut rx = rx.lock().await;
            while let Some(inbound) = rx.recv().await {
                if sink.add(inbound).is_err() {
                    log::warn!("remote_control_stream sink closed, exiting");
                    break;
                }
            }
        });
        Ok(())
    }

    /// Send a control command to a peer and await its answer.
    pub async fn send_remote_control_request(
        &self,
        peer: String,
        req: FlutterRemoteControlRequest,
    ) -> anyhow::Result<FlutterRemoteControlResponse> {
        let response = self
            .inner
            .send_request(peer, MydiaRequest::RemoteControl(req.into()))
            .await
            .map_err(|e| anyhow::anyhow!("remote control request failed: {}", e))?;

        match response {
            MydiaResponse::RemoteControl(res) => Ok(res.into()),
            MydiaResponse::Error(e) => Err(anyhow::anyhow!("target returned an error: {}", e)),
            other => Err(anyhow::anyhow!("unexpected response: {:?}", other)),
        }
    }

    /// Answer an inbound control request.
    ///
    /// A successful return means the response was *enqueued* on the host's
    /// command channel, not that it reached the wire. Task 1 hit this for
    /// real: a process that exits promptly after this returns can drop an
    /// in-flight response. Callers that need the answer delivered must keep
    /// the host alive until the peer's request completes.
    pub async fn respond_to_remote_control(
        &self,
        request_id: String,
        res: FlutterRemoteControlResponse,
    ) -> anyhow::Result<()> {
        self.inner
            .send_response(request_id, MydiaResponse::RemoteControl(res.into()))
            .await
            .map_err(|e| anyhow::anyhow!("send_response failed: {}", e))
    }

    /// Send a pairing request to a specific peer.
    pub async fn send_pairing_request(
        &self,
        peer: String,
        req: FlutterPairingRequest,
    ) -> anyhow::Result<FlutterPairingResponse> {
        // Never log the claim code. It is a live pairing credential for five
        // minutes, so anyone reading client logs could pair a device with it.
        // Same class of leak as 518337412 on the Dart side.
        log::info!("P2pHost::send_pairing_request() called for peer: {}", peer);
        let core_req = PairingRequest {
            claim_code: req.claim_code,
            device_name: req.device_name,
            device_type: req.device_type,
            device_os: req.device_os,
        };

        match self
            .inner
            .send_request(peer.clone(), MydiaRequest::Pairing(core_req))
            .await
        {
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
                log::error!(
                    "send_pairing_request() unexpected response type: {:?}",
                    other
                );
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_pairing_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_pairing_request failed: {}", e))
            }
        }
    }

    /// Send a GraphQL request to a specific peer.
    pub async fn send_graphql_request(
        &self,
        peer: String,
        req: FlutterGraphQLRequest,
    ) -> anyhow::Result<FlutterGraphQLResponse> {
        log::info!("P2pHost::send_graphql_request() called for peer: {}", peer);
        let core_req = GraphQLRequest {
            query: req.query,
            variables: req.variables,
            operation_name: req.operation_name,
            auth_token: req.auth_token,
            device_profile: req.device_profile,
        };

        match self
            .inner
            .send_request(peer.clone(), MydiaRequest::GraphQL(core_req))
            .await
        {
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
                log::error!(
                    "send_graphql_request() unexpected response type: {:?}",
                    other
                );
                Err(anyhow::anyhow!("Unexpected response type"))
            }
            Err(e) => {
                log::error!("send_graphql_request() failed for peer {}: {}", peer, e);
                Err(anyhow::anyhow!("send_graphql_request failed: {}", e))
            }
        }
    }

    /// Get network statistics.
    pub async fn get_network_stats(&self) -> FlutterNetworkStats {
        let stats = self.inner.get_network_stats().await;
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
            peer,
            req.session_id,
            req.path
        );

        let core_req = HlsRequest {
            session_id: req.session_id,
            path: req.path,
            range_start: req.range_start,
            range_end: req.range_end,
            auth_token: req.auth_token,
        };

        let requester = self.hls_requester.clone();

        // See `event_stream` for why this enters the core's runtime instead of
        // spawning a thread with a runtime of its own.
        let _guard = runtime::enter();
        runtime::spawn(async move {
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
                    let _ = sink.add(FlutterHlsStreamEvent::Error(format!(
                        "HLS request failed: {}",
                        e
                    )));
                }
            }
        });

        Ok(())
    }

    /// Send an HLS request to a specific peer and collect the complete response.
    ///
    /// This is a non-streaming version that collects all chunks into a single buffer.
    /// For large files, consider using the local proxy service instead.
    pub async fn send_hls_request(
        &self,
        peer: String,
        req: FlutterHlsRequest,
    ) -> anyhow::Result<FlutterHlsResponse> {
        log::info!(
            "P2pHost::send_hls_request() called for peer: {}, session: {}, path: {}",
            peer,
            req.session_id,
            req.path
        );

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

                log::info!(
                    "HLS request completed for peer: {}, received {} bytes",
                    peer,
                    data.len()
                );
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

/// The decrypted contents of a sealed pairing claim.
pub struct ClaimPayload {
    pub node_addr: String,
    pub instance_id: String,
}

/// Keys derived from a pairing claim code.
///
/// Held as an object rather than exposed as two free functions so that Argon2id
/// runs once per pairing attempt. At 64 MiB it costs a few hundred milliseconds
/// on a phone and more in a browser, and the lookup and the open both need it.
pub struct PairingKeys {
    code: String,
}

impl PairingKeys {
    /// Derive from a claim code as the user typed it. Case, dashes, and
    /// whitespace are normalized inside the core crate.
    #[frb(sync)]
    pub fn derive(code: String) -> PairingKeys {
        PairingKeys { code }
    }

    /// The relay URL path segment: 64 lowercase hex characters.
    pub fn lookup_key(&self) -> anyhow::Result<String> {
        mydia_p2p_core::pairing_seal::lookup_key_for(&self.code)
            .map_err(|e| anyhow::anyhow!(e.to_string()))
    }

    /// Open a sealed blob fetched from the relay.
    ///
    /// A failure here is meaningful. A wrong code cannot produce a lookup hit
    /// short of a 256-bit collision, so a blob that fetches but does not open
    /// was altered in storage or in transit.
    pub fn open(&self, sealed: String) -> anyhow::Result<ClaimPayload> {
        let payload = mydia_p2p_core::pairing_seal::open_claim(&self.code, &sealed)
            .map_err(|e| anyhow::anyhow!(e.to_string()))?;

        Ok(ClaimPayload {
            node_addr: payload.node_addr,
            instance_id: payload.instance_id,
        })
    }
}

#[cfg(test)]
mod pairing_keys_tests {
    use super::*;

    #[test]
    fn opens_a_blob_sealed_by_the_core() {
        let sealed = mydia_p2p_core::pairing_seal::seal_claim(
            "K7RPM2",
            &mydia_p2p_core::pairing_seal::ClaimPayload {
                node_addr: "addr".to_string(),
                instance_id: "inst".to_string(),
            },
        )
        .unwrap();

        let keys = PairingKeys::derive("k7r-pm2".to_string());

        assert_eq!(keys.lookup_key().unwrap(), sealed.lookup_key);

        let opened = keys.open(sealed.sealed).unwrap();
        assert_eq!(opened.node_addr, "addr");
        assert_eq!(opened.instance_id, "inst");
    }

    #[test]
    fn a_wrong_code_fails_to_open() {
        let sealed = mydia_p2p_core::pairing_seal::seal_claim(
            "K7RPM2",
            &mydia_p2p_core::pairing_seal::ClaimPayload {
                node_addr: "addr".to_string(),
                instance_id: "inst".to_string(),
            },
        )
        .unwrap();

        assert!(PairingKeys::derive("K7RPM3".to_string())
            .open(sealed.sealed)
            .is_err());
    }
}

#[cfg(test)]
mod remote_control_bridge_tests {
    use super::*;
    use mydia_p2p_core::{PlaybackState, RemoteControlRequest, TargetCapabilities};

    #[test]
    fn a_seek_converts_both_ways() {
        let flutter = FlutterRemoteControlRequest::Seek {
            position_ms: 754_000,
        };
        let core: RemoteControlRequest = flutter.clone().into();
        assert_eq!(
            core,
            RemoteControlRequest::Seek {
                position_ms: 754_000
            }
        );
        assert_eq!(FlutterRemoteControlRequest::from(core), flutter);
    }

    #[test]
    fn capabilities_convert_both_ways() {
        let core = TargetCapabilities {
            volume: true,
            track_selection: false,
            next_previous: true,
        };
        let flutter: FlutterTargetCapabilities = core.into();
        assert!(flutter.volume);
        assert!(!flutter.track_selection);
        assert_eq!(TargetCapabilities::from(flutter), core);
    }

    #[test]
    fn playback_state_converts_both_ways() {
        for state in [
            PlaybackState::Idle,
            PlaybackState::Loading,
            PlaybackState::Buffering,
            PlaybackState::Playing,
            PlaybackState::Paused,
            PlaybackState::Ended,
            PlaybackState::Error,
        ] {
            let flutter: FlutterPlaybackState = state.into();
            assert_eq!(PlaybackState::from(flutter), state);
        }
    }
}

#[cfg(test)]
mod event_dispatcher_tests {
    use super::*;
    use mydia_p2p_core::runtime::time::{timeout, Duration};

    fn control_event(request_id: &str) -> Event {
        Event::RequestReceived {
            peer: "peer-controller".to_string(),
            request: MydiaRequest::RemoteControl(RemoteControlRequest::GetState),
            request_id: request_id.to_string(),
        }
    }

    /// Pins the bug CodeRabbit found: an awaited `send` on the bounded
    /// control channel used to block this loop once it filled up, which
    /// stopped it from draining `event_rx` at all — silently stalling
    /// *every* event, control and generic alike, not just the control
    /// requests that were actually piling up.
    #[test]
    fn a_full_control_channel_does_not_stall_generic_event_delivery() {
        runtime::block_on(async {
            let (event_tx, event_rx) = mpsc::channel::<Event>(100);
            let event_rx = Arc::new(Mutex::new(event_rx));
            // Deliberately tiny, so the test does not need to send 33 events
            // to reproduce a full channel.
            let (control_tx, mut control_rx) = mpsc::channel::<FlutterInboundControlRequest>(2);
            let (generic_tx, mut generic_rx) = mpsc::unbounded_channel::<Event>();

            let _guard = runtime::enter();
            runtime::spawn(run_event_dispatcher(event_rx, control_tx, generic_tx));

            // Fill the control channel past capacity without ever draining
            // `control_rx` — the "Dart never subscribed" scenario the
            // finding describes.
            for i in 0..5 {
                event_tx
                    .send(control_event(&format!("req-{i}")))
                    .await
                    .unwrap();
            }

            // A generic event sent after the control channel backed up must
            // still arrive, and promptly: proof the dispatcher never
            // blocked trying to hand the 3rd control request to a full
            // channel.
            event_tx.send(Event::RelayConnected).await.unwrap();

            let generic = timeout(Duration::from_secs(2), generic_rx.recv())
                .await
                .expect(
                    "the dispatcher must still be draining event_rx for the generic side, \
                     even with the control side backed up",
                )
                .expect("generic_tx must still be open");
            assert!(matches!(generic, Event::RelayConnected));

            // Only as many control requests as fit the bounded channel were
            // actually admitted; the rest were dropped rather than queued
            // forever.
            let mut received = 0;
            while control_rx.try_recv().is_ok() {
                received += 1;
            }
            assert_eq!(received, 2);
        });
    }

    /// The other half of the same finding: `remote_control_stream`'s sink
    /// closing (its subscriber cancels, or the stream itself ends) drops
    /// `control_rx` entirely, which makes every future `try_send` return
    /// `Closed` rather than `Full`. Generic event delivery must survive
    /// that too.
    #[test]
    fn a_closed_control_receiver_does_not_stall_generic_event_delivery() {
        runtime::block_on(async {
            let (event_tx, event_rx) = mpsc::channel::<Event>(100);
            let event_rx = Arc::new(Mutex::new(event_rx));
            let (control_tx, control_rx) = mpsc::channel::<FlutterInboundControlRequest>(32);
            drop(control_rx);
            let (generic_tx, mut generic_rx) = mpsc::unbounded_channel::<Event>();

            let _guard = runtime::enter();
            runtime::spawn(run_event_dispatcher(event_rx, control_tx, generic_tx));

            event_tx.send(control_event("req-1")).await.unwrap();
            event_tx.send(Event::RelayConnected).await.unwrap();

            let generic = timeout(Duration::from_secs(2), generic_rx.recv())
                .await
                .expect("the dispatcher must still be draining event_rx")
                .expect("generic_tx must still be open");
            assert!(matches!(generic, Event::RelayConnected));
        });
    }
}
