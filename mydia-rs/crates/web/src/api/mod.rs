//! REST API surface for mydia-rs (U33).
//!
//! Port of the eleven Phoenix controllers under
//! `lib/mydia_web/controllers/api/` plus the `api/player/v1/` subtree.
//! These endpoints are not covered by the GraphQL surface (U8-U14):
//! they serve byte-range video streams, thumbnail sprites, the
//! operator config-management API, and the player-specific subtitle
//! file downloads.
//!
//! ## Layout
//!
//! - [`v1`] mirrors `MydiaWeb.Api.*` (config, downloads, indexers,
//!   media, playback, stream, thumbnail, hls).
//! - [`player::v1`] mirrors `MydiaWeb.Api.Player.V1.*` (subtitle
//!   endpoints).
//! - [`range_helper`] is the Rust port of
//!   `lib/mydia_web/controllers/api/range_helper.ex` — `Range:` header
//!   parsing, content-range formatting, and MIME inference for the
//!   common video container set.
//!
//! ## Mounting
//!
//! [`router`] returns an `axum::Router` that the application
//! supervisor merges into the top-level router alongside the Dioxus
//! full-stack surface. Static handlers (rather than Dioxus
//! `#[server]` functions) because byte-range streaming, file
//! responses, and per-route auth pipelines don't fit the server-fn
//! shape.
//!
//! ## Auth posture
//!
//! Today the routes mount without their per-route auth pipeline
//! attached — the U6 extractors (API key, media token, session
//! cookie) exist in `mydia-rs-auth`, but the per-route Phoenix Plug
//! pipeline mapping (`api_auth`, `media_api_auth`, `require_admin`,
//! `require_authenticated`) ports as part of U33's follow-up slice.
//! The handlers themselves are scaffolded so the surface is wired
//! and verifiable; the byte-range and thumbnail endpoints are
//! behaviorally complete on the request side.
//!
//! TODO(U33-follow-up): wire `mydia_rs_auth::api_key`, `media_token`,
//! and session extractors into per-route middleware so the auth
//! pipeline matches the Phoenix `router.ex` scope blocks (lines
//! 213-273).

#![cfg(feature = "server")]

pub mod player;
pub mod range_helper;
pub mod v1;

#[doc(hidden)]
pub use v1::stream::serve_file_for_tests;

use axum::Router;

use crate::WebState;

/// Build the combined REST router (`/api/v1` + `/api/player/v1`).
///
/// The returned `Router` carries no `Extension<WebState>` of its own;
/// the caller (the application server module) attaches the shared
/// `WebState` extension once for the entire merged router so the
/// REST handlers, the Dioxus server fns, and the OIDC handlers all
/// see the same instance. `_state` is accepted (and ignored) so the
/// call site mirrors the GraphQL `router(schema)` signature and so
/// future per-handler state initialization (rate-limit buckets, the
/// media-token cache) can hang off it without a call-site churn.
pub fn router(_state: WebState) -> Router {
    Router::new()
        .merge(v1::router())
        .merge(player::v1::router())
}
