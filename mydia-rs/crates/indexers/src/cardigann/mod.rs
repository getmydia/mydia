//! Cardigann indexer engine.
//!
//! Port of the `lib/mydia/indexers/cardigann_*.ex` modules. The flat
//! `cardigann_*` Phoenix naming is collapsed here into a submodule
//! tree:
//!
//! - [`auth`] — login flows for private indexers.
//! - [`compat`] — schema v10 → v11 normalization shims.
//! - [`definition`] — typed row schema for the database table.
//! - [`definition_parsed`] — typed shape returned by the YAML parser.
//! - [`filters`] — Cardigann filter chain (`trim`, `re_replace`, ...).
//! - [`health_check`] — Cardigann-specific health probe.
//! - [`overrides`] — patches for known buggy upstream definitions.
//! - [`parser`] — YAML → [`definition_parsed::ParsedDefinition`].
//! - [`result_parser`] — HTML / JSON → [`crate::SearchResult`] list.
//! - [`search_engine`] — request building + HTTP execution.
//! - [`search_session`] — per-request state (debug + analytics).
//! - [`template`] — Go-template renderer subset.

pub mod auth;
pub mod compat;
pub mod definition;
pub mod definition_parsed;
pub mod filters;
pub mod health_check;
pub mod overrides;
pub mod parser;
pub mod result_parser;
pub mod search_engine;
pub mod search_session;
pub mod template;
