//! Incoming-request dispatch for the p2p surface.
//!
//! [`P2pRouter`] is the seam between the [`crate::server`] event loop
//! and the rest of the application. The event loop pulls a
//! [`mydia_p2p_core::MydiaRequest`] off the Host's event channel,
//! calls into the router, and uses the returned [`RoutedResponse`] to
//! reply (or, for HLS streams, signals that the router will stream
//! chunks itself).
//!
//! ## Why a trait
//!
//! Three reasons:
//!
//! 1. Decouples the server from concrete graphql / streaming /
//!    pairing crates. The server depends on `P2pRouter`; production
//!    wires up [`DefaultRouter`]; tests pass a stub.
//! 2. Lets the integration tests exercise the routing logic without
//!    booting a Host (which would require iroh + the network).
//! 3. Future units can swap the dispatch (for example, attaching a
//!    metrics interceptor) by wrapping the inner router instead of
//!    forking the server.
//!
//! ## Blocking-API discipline
//!
//! Router methods are `async fn`. They MUST NOT call any blocking
//! `mydia_p2p_core::Host` method directly; the server wraps every
//! such call in `tokio::task::spawn_blocking`. The router's job is
//! to produce a response value; the server handles the I/O.

use std::sync::Arc;

use async_trait::async_trait;
use mydia_p2p_core::{
    GraphQLRequest, GraphQLResponse, HlsRequest, HlsResponseHeader, MydiaRequest, MydiaResponse,
    PairingRequest, PairingResponse, ReadMediaRequest,
};
use thiserror::Error;

use crate::media_token::ValidationError;
use crate::pairing::{DeviceAttrs, PairingError};

/// Errors a router target can surface. Kept narrow; callers turn
/// these into `MydiaResponse::Error` on the wire.
#[derive(Debug, Error)]
pub enum RouterError {
    #[error("pairing failed: {0}")]
    Pairing(#[from] PairingError),
    #[error("auth: {0}")]
    Auth(#[from] ValidationError),
    #[error("not implemented: {0}")]
    NotImplemented(&'static str),
    #[error("internal: {0}")]
    Internal(String),
}

/// Per-request hint surface. Today: just the peer connection type
/// (so resolvers can enforce relay caps). Future units add per-peer
/// rate-limit state etc.
#[derive(Debug, Clone, Default)]
pub struct RouterContext {
    pub peer_connection_type: Option<String>,
}

/// Outcome of routing a single non-streaming request. HLS streams
/// don't pass through here; the server delivers them via
/// [`P2pRouter::handle_hls_stream`] directly so the router can drive
/// the chunk send loop.
#[derive(Debug)]
pub enum RoutedResponse {
    /// Reply with a single [`MydiaResponse`] payload.
    Reply(MydiaResponse),
    /// The router has already taken responsibility for streaming the
    /// reply via the supplied `stream_id`. Used only for HLS.
    Streamed,
}

/// Dispatch contract.
///
/// Every method is `async`. The server clones the router into the
/// per-request task before invoking the method, so implementors
/// should be cheap to clone (typically `Arc<...>` internally).
#[async_trait]
pub trait P2pRouter: Send + Sync + 'static {
    /// Handle a pairing request: claim-code validation, device
    /// creation, token issuance.
    async fn handle_pairing(
        &self,
        request: PairingRequest,
        ctx: RouterContext,
    ) -> Result<PairingResponse, RouterError>;

    /// Handle a `ReadMedia` request. Today this is the legacy direct
    /// file-chunk API; HLS is preferred. We pass it through so the
    /// parity matrix stays intact.
    async fn handle_read_media(
        &self,
        request: ReadMediaRequest,
        ctx: RouterContext,
    ) -> Result<MydiaResponse, RouterError>;

    /// Execute a GraphQL operation against the schema and return a
    /// serialised response.
    async fn handle_graphql(
        &self,
        request: GraphQLRequest,
        ctx: RouterContext,
    ) -> Result<GraphQLResponse, RouterError>;

    /// Handle an HLS streaming request. Implementations receive an
    /// [`HlsStreamHandle`] (an Arc-cloned handle to the server) so
    /// they can send the response header + chunks themselves via the
    /// server's [`crate::server::ServerHandle::send_hls_*`] family.
    async fn handle_hls_stream(
        &self,
        request: HlsRequest,
        stream_id: String,
        stream_handle: HlsStreamHandle,
        ctx: RouterContext,
    ) -> Result<(), RouterError>;
}

/// Top-level entry the server calls once per request. Dispatches on
/// the [`MydiaRequest`] variant. For HLS requests this is a no-op:
/// the server invokes [`P2pRouter::handle_hls_stream`] directly
/// because HLS uses a separate `Event` variant.
pub async fn route(
    router: &Arc<dyn P2pRouter>,
    request: MydiaRequest,
    ctx: RouterContext,
) -> Result<RoutedResponse, RouterError> {
    match request {
        MydiaRequest::Ping => Ok(RoutedResponse::Reply(MydiaResponse::Pong)),
        MydiaRequest::Pairing(req) => {
            let resp = router.handle_pairing(req, ctx).await?;
            Ok(RoutedResponse::Reply(MydiaResponse::Pairing(resp)))
        }
        MydiaRequest::ReadMedia(req) => {
            let resp = router.handle_read_media(req, ctx).await?;
            Ok(RoutedResponse::Reply(resp))
        }
        MydiaRequest::GraphQL(req) => {
            let resp = router.handle_graphql(req, ctx).await?;
            Ok(RoutedResponse::Reply(MydiaResponse::GraphQL(resp)))
        }
        MydiaRequest::HlsStream(_) => {
            // HLS requests arrive via Event::HlsStreamRequest, not
            // Event::RequestReceived, so this branch should not fire
            // in production. Defensive only.
            Err(RouterError::NotImplemented(
                "HlsStream requests are dispatched via Event::HlsStreamRequest",
            ))
        }
        MydiaRequest::Custom(_) => Err(RouterError::NotImplemented("Custom request")),
    }
}

/// Build a `Pairing` response payload from a [`crate::PairingOutcome`].
/// Surfaces `success = false` + `error` for ergonomic failure cases
/// rather than dropping them on the wire-error floor.
pub fn pairing_response_from_outcome(
    outcome: crate::pairing::PairingOutcome,
    direct_urls: Vec<String>,
) -> PairingResponse {
    PairingResponse {
        success: true,
        media_token: Some(outcome.media_token),
        access_token: Some(outcome.access_token),
        device_token: Some(outcome.device_token),
        error: None,
        direct_urls,
    }
}

/// Build a `Pairing` failure payload from an error. The wire shape is
/// `success = false` + a stringified reason; we keep it free of
/// internal-detail leakage by mapping each error variant to a short
/// stable code.
pub fn pairing_response_from_error(err: &PairingError) -> PairingResponse {
    let reason = match err {
        PairingError::Claim(crate::ClaimCodeError::NotFound) => "claim_not_found",
        PairingError::Claim(crate::ClaimCodeError::AlreadyUsed) => "claim_used",
        PairingError::Claim(crate::ClaimCodeError::Expired) => "claim_expired",
        PairingError::Claim(crate::ClaimCodeError::Database(_)) | PairingError::Database(_) => {
            "database"
        }
        PairingError::Token(_) => "token_issue",
        PairingError::Hash(_) => "hash_failed",
    };
    PairingResponse {
        success: false,
        media_token: None,
        access_token: None,
        device_token: None,
        error: Some(reason.to_string()),
        direct_urls: Vec::new(),
    }
}

/// Map a [`DeviceAttrs`] from a wire `PairingRequest`. The Phoenix
/// handler prefers `device_type`, falling back to `device_os`, then
/// `"unknown"`. We match exactly.
pub fn device_attrs_from_request(request: &PairingRequest) -> DeviceAttrs {
    let platform = if !request.device_type.is_empty() {
        request.device_type.clone()
    } else if let Some(os) = request.device_os.as_deref() {
        os.to_string()
    } else {
        "unknown".to_string()
    };
    DeviceAttrs {
        device_name: request.device_name.clone(),
        platform,
    }
}

/// Handle the server hands router targets so they can drive HLS
/// streaming responses.
///
/// Implementations exist only on the `server` module; the trait is
/// here so router targets can take it as a parameter without a cycle.
#[async_trait]
pub trait HlsStreamHandleApi: Send + Sync {
    async fn send_header(&self, header: HlsResponseHeader) -> Result<(), String>;
    async fn send_chunk(&self, data: Vec<u8>) -> Result<(), String>;
    async fn finish(&self) -> Result<(), String>;
    /// Convenience: stream a file range directly via the host's
    /// optimised zero-copy path. The server implementation wraps this
    /// in `spawn_blocking`.
    async fn stream_file_range(
        &self,
        file_path: String,
        offset: u64,
        length: u64,
    ) -> Result<(), String>;
}

/// Boxed handle the server hands to the router. Newtype so the router
/// trait signature doesn't leak the underlying box type.
pub struct HlsStreamHandle {
    inner: Arc<dyn HlsStreamHandleApi>,
}

impl HlsStreamHandle {
    pub fn new(inner: Arc<dyn HlsStreamHandleApi>) -> Self {
        Self { inner }
    }

    pub async fn send_header(&self, header: HlsResponseHeader) -> Result<(), String> {
        self.inner.send_header(header).await
    }

    pub async fn send_chunk(&self, data: Vec<u8>) -> Result<(), String> {
        self.inner.send_chunk(data).await
    }

    pub async fn finish(&self) -> Result<(), String> {
        self.inner.finish().await
    }

    pub async fn stream_file_range(
        &self,
        file_path: String,
        offset: u64,
        length: u64,
    ) -> Result<(), String> {
        self.inner
            .stream_file_range(file_path, offset, length)
            .await
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A small router stub used by integration tests to confirm the
    /// dispatch logic in [`route`] matches the request variant
    /// without booting a real Host.
    struct StubRouter;

    #[async_trait]
    impl P2pRouter for StubRouter {
        async fn handle_pairing(
            &self,
            _request: PairingRequest,
            _ctx: RouterContext,
        ) -> Result<PairingResponse, RouterError> {
            Ok(PairingResponse {
                success: true,
                media_token: Some("media".into()),
                access_token: Some("access".into()),
                device_token: Some("device".into()),
                error: None,
                direct_urls: Vec::new(),
            })
        }

        async fn handle_read_media(
            &self,
            _request: ReadMediaRequest,
            _ctx: RouterContext,
        ) -> Result<MydiaResponse, RouterError> {
            Ok(MydiaResponse::MediaChunk(vec![1, 2, 3]))
        }

        async fn handle_graphql(
            &self,
            _request: GraphQLRequest,
            _ctx: RouterContext,
        ) -> Result<GraphQLResponse, RouterError> {
            Ok(GraphQLResponse {
                data: Some(r#"{"x":1}"#.into()),
                errors: None,
            })
        }

        async fn handle_hls_stream(
            &self,
            _request: HlsRequest,
            _stream_id: String,
            _stream_handle: HlsStreamHandle,
            _ctx: RouterContext,
        ) -> Result<(), RouterError> {
            Ok(())
        }
    }

    #[tokio::test]
    async fn ping_replies_pong_without_touching_router() {
        let router: Arc<dyn P2pRouter> = Arc::new(StubRouter);
        let outcome = route(&router, MydiaRequest::Ping, RouterContext::default())
            .await
            .unwrap();
        assert!(matches!(
            outcome,
            RoutedResponse::Reply(MydiaResponse::Pong)
        ));
    }

    #[tokio::test]
    async fn pairing_routes_to_handle_pairing() {
        let router: Arc<dyn P2pRouter> = Arc::new(StubRouter);
        let req = MydiaRequest::Pairing(PairingRequest {
            claim_code: "ABCD-1234".into(),
            device_name: "test".into(),
            device_type: "android".into(),
            device_os: None,
        });
        let outcome = route(&router, req, RouterContext::default()).await.unwrap();
        match outcome {
            RoutedResponse::Reply(MydiaResponse::Pairing(resp)) => {
                assert!(resp.success);
                assert_eq!(resp.media_token.as_deref(), Some("media"));
            }
            other => panic!("expected Pairing reply, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn hls_via_request_received_returns_not_implemented() {
        let router: Arc<dyn P2pRouter> = Arc::new(StubRouter);
        let req = MydiaRequest::HlsStream(HlsRequest {
            session_id: "s".into(),
            path: "p".into(),
            range_start: None,
            range_end: None,
            auth_token: None,
        });
        let result = route(&router, req, RouterContext::default()).await;
        assert!(matches!(result, Err(RouterError::NotImplemented(_))));
    }

    #[test]
    fn device_attrs_prefers_device_type() {
        let req = PairingRequest {
            claim_code: "c".into(),
            device_name: "d".into(),
            device_type: "android".into(),
            device_os: Some("linux".into()),
        };
        assert_eq!(device_attrs_from_request(&req).platform, "android");
    }

    #[test]
    fn device_attrs_falls_back_to_device_os() {
        let req = PairingRequest {
            claim_code: "c".into(),
            device_name: "d".into(),
            device_type: String::new(),
            device_os: Some("linux".into()),
        };
        assert_eq!(device_attrs_from_request(&req).platform, "linux");
    }

    #[test]
    fn device_attrs_falls_back_to_unknown() {
        let req = PairingRequest {
            claim_code: "c".into(),
            device_name: "d".into(),
            device_type: String::new(),
            device_os: None,
        };
        assert_eq!(device_attrs_from_request(&req).platform, "unknown");
    }
}
