//! Server functions powering the Dioxus pages.
//!
//! Each submodule groups the `#[server]` / `#[get]` / `#[post]` calls
//! a page family needs. Dioxus 0.7 auto-registers any `#[server]`-
//! annotated function via `inventory`, so simply declaring the module
//! and pulling it into the crate is enough to mount it on the axum
//! router built by `dioxus::server::router(...)`.
//!
//! Pattern: server fns deserialize their args via the macro, extract
//! the shared [`WebState`](crate::server_state::WebState) through
//! `FullstackContext::extension::<WebState>()` (server-only), and call
//! sqlx / pubsub / apalis directly. No business-logic indirection
//! layer — the surface is small and adding one would just paper over
//! the natural single-call shape of these handlers.

pub mod activity;
pub mod add_media;
pub mod admin;
pub mod auth;
pub mod calendar;
pub mod dashboard;
pub mod discover;
pub mod downloads;
pub mod library_paths;
pub mod media;
pub mod profile;
pub mod requests;
