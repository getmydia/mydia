//! Media pages (U25 — port of `MydiaWeb.MediaLive`).
//!
//! - `index` — grid of movies or TV shows with search/filter/sort,
//!   served at `/movies` and `/tv`.
//! - `show` (U25.b, pending) — detail page at `/media/:id`.

pub mod index;
pub mod show;
