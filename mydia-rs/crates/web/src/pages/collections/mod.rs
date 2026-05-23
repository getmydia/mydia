//! Collections pages (U26 — port of `MydiaWeb.CollectionLive`).
//!
//! - `index` — list of collections accessible to the session user
//!   (owned + shared), served at `/collections`.
//! - `show` — single-collection detail page rendering its member
//!   media as a grid, served at `/collections/:id`.

pub mod index;
pub mod show;
