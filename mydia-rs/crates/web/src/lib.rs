//! mydia-rs Dioxus 0.7 full-stack web UI surface.
//!
//! Public seam between the wasm-buildable UI tree and the server-side
//! axum mount in `crates/app`. The same `app()` component compiles for
//! the wasm client (hydration) and the native server (SSR) per Dioxus's
//! dual-target convention; feature flags on `dioxus` are forwarded by
//! the parent app crate so this crate stays target-agnostic.
//!
//! U22 lands the scaffolding: layout, core components, hello page,
//! router skeleton, security-header constants. The Phoenix `LiveView`
//! family ports start at U23 (the deliberate fitness probe) and fill
//! out the `pages/` and `server_fns/` trees through U28.

pub mod app;
pub mod components;
pub mod layout;
pub mod pages;
pub mod realtime;
pub mod routes;
pub mod security;
pub mod server_fns;

// U33 REST API surface — axum handlers mounted alongside the Dioxus
// full-stack router. Server-only (no wasm); kept off the wasm tree
// because the handlers depend on tokio::fs, sqlx, and tokio-util.
#[cfg(feature = "server")]
pub mod api;

#[cfg(feature = "server")]
pub mod server_state;

#[cfg(feature = "server")]
pub mod session;

#[cfg(feature = "server")]
pub mod oidc;

pub use app::App;
pub use routes::Route;

#[cfg(feature = "server")]
pub use server_state::WebState;

/// Dioxus root component entry point.
///
/// The parent app crate calls this as `dioxus::server::router(mydia_rs_web::app)`
/// for SSR; the wasm bin (added once `dx build` is wired) calls
/// `dioxus::launch(mydia_rs_web::app)`. Both paths converge here.
pub fn app() -> dioxus::dioxus_core::Element {
    use dioxus::prelude::*;
    rsx! { App {} }
}
