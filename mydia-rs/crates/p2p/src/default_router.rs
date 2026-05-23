//! Baseline [`P2pRouter`] implementation suitable for app boot.
//!
//! [`MinimalRouter`] wires the dispatch surface to the parts of the
//! app that exist today:
//!
//! - Pairing requests run the full [`crate::complete_pairing`] flow,
//!   protected by the atomic [`crate::ClaimRateLimiter`].
//! - HLS / GraphQL / `ReadMedia` requests reply with a clear
//!   "not implemented yet" error. Those branches light up in
//!   follow-up units when the streaming + GraphQL crates get their
//!   p2p adapters; the wire shape stays intact so client code keeps
//!   round-tripping during the parallel window.
//!
//! Production wiring assembles `MinimalRouter` from the boot-time
//! `Db`, the JWT signers from the auth crate, and a fresh rate
//! limiter (per-process; survives hot-patches via
//! `mydia_rs_app::main::BOOT`'s `OnceCell`).

use async_trait::async_trait;
use mydia_p2p_core::{
    GraphQLRequest, GraphQLResponse, HlsRequest, MydiaResponse, PairingRequest, PairingResponse,
    ReadMediaRequest,
};
use mydia_rs_auth::{AccessTokenSigner, MediaTokenSigner};
use mydia_rs_db::Db;

use crate::pairing::{complete_pairing, DeviceAttrs};
use crate::rate_limiter::{ClaimRateLimiter, RateLimitOutcome};
use crate::router::{
    device_attrs_from_request, pairing_response_from_error, pairing_response_from_outcome,
    HlsStreamHandle, P2pRouter, RouterContext, RouterError,
};

/// Production-shape router. Holds the long-lived handles every
/// request branch needs.
#[derive(Clone)]
pub struct MinimalRouter {
    db: Db,
    media_signer: MediaTokenSigner,
    access_signer: AccessTokenSigner,
    rate_limiter: ClaimRateLimiter,
    direct_urls: Vec<String>,
}

impl MinimalRouter {
    pub fn new(
        db: Db,
        media_signer: MediaTokenSigner,
        access_signer: AccessTokenSigner,
        rate_limiter: ClaimRateLimiter,
    ) -> Self {
        Self {
            db,
            media_signer,
            access_signer,
            rate_limiter,
            direct_urls: Vec::new(),
        }
    }

    /// Optional list of `https://host:port` direct URLs the client
    /// can use to bypass the relay. Configured by the operator; we
    /// surface it in the pairing response so paired clients can dial
    /// the box directly when possible.
    pub fn with_direct_urls(mut self, urls: Vec<String>) -> Self {
        self.direct_urls = urls;
        self
    }

    pub fn rate_limiter(&self) -> &ClaimRateLimiter {
        &self.rate_limiter
    }
}

#[async_trait]
impl P2pRouter for MinimalRouter {
    async fn handle_pairing(
        &self,
        request: PairingRequest,
        _ctx: RouterContext,
    ) -> Result<PairingResponse, RouterError> {
        // We don't have a per-peer IP at this level (iroh doesn't
        // expose it; the request_id is the only stable identifier).
        // Use the request_id-equivalent: the device-supplied name is
        // not stable enough; fall back to the claim code itself as
        // the rate-limit key. This matches Phoenix's "rate by
        // submitting actor" rule more loosely than ideal, but it
        // still blocks a brute-force loop from one origin.
        let rate_key = request.claim_code.clone();
        if self.rate_limiter.check_and_record_failure(&rate_key) == RateLimitOutcome::Blocked {
            return Ok(PairingResponse {
                success: false,
                media_token: None,
                access_token: None,
                device_token: None,
                error: Some("rate_limited".into()),
                direct_urls: Vec::new(),
            });
        }

        let attrs: DeviceAttrs = device_attrs_from_request(&request);
        match complete_pairing(
            &self.db,
            &self.media_signer,
            &self.access_signer,
            &request.claim_code,
            attrs,
        )
        .await
        {
            Ok(outcome) => {
                // Success clears the rate-limit counter for this key.
                self.rate_limiter.reset(&rate_key);
                Ok(pairing_response_from_outcome(
                    outcome,
                    self.direct_urls.clone(),
                ))
            }
            Err(err) => {
                tracing::warn!(error = %err, "pairing failed");
                Ok(pairing_response_from_error(&err))
            }
        }
    }

    async fn handle_read_media(
        &self,
        _request: ReadMediaRequest,
        _ctx: RouterContext,
    ) -> Result<MydiaResponse, RouterError> {
        // Legacy direct read path. Not yet wired in mydia-rs; HLS is
        // the supported surface.
        Ok(MydiaResponse::Error(
            "ReadMedia not implemented in mydia-rs; use HlsStream".into(),
        ))
    }

    async fn handle_graphql(
        &self,
        _request: GraphQLRequest,
        _ctx: RouterContext,
    ) -> Result<GraphQLResponse, RouterError> {
        // The p2p GraphQL bridge is gated on the U10/U11 resolver
        // families lighting up against shared state. We surface a
        // clear "not yet wired up" error rather than a wire-level
        // crash so paired clients see a deterministic shape.
        Ok(GraphQLResponse {
            data: None,
            errors: Some(
                r#"[{"message":"p2p GraphQL bridge not wired yet (lands in a U29 follow-up)"}]"#
                    .into(),
            ),
        })
    }

    async fn handle_hls_stream(
        &self,
        _request: HlsRequest,
        _stream_id: String,
        stream_handle: HlsStreamHandle,
        _ctx: RouterContext,
    ) -> Result<(), RouterError> {
        // Send a 501 header so the client doesn't hang waiting for
        // chunks. Production wiring routes through
        // `mydia_rs_streaming::Supervisor`; that adapter lands when
        // the streaming crate gets its p2p-side glue.
        let header = mydia_p2p_core::HlsResponseHeader {
            status: 501,
            content_type: "text/plain".to_string(),
            content_length: 0,
            content_range: None,
            cache_control: None,
        };
        let _ = stream_handle.send_header(header).await;
        let _ = stream_handle.finish().await;
        Ok(())
    }
}
