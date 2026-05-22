//! Admin pages.
//!
//! U23 ships the deliberate pilot — [`library_paths`] — which exercises
//! every plumbing seam Phase 4 needs (server-fn CRUD, form validation
//! round-trips, realtime WebSocket subscription, real-time `DaisyUI`
//! progress component). U28 fills out the remaining 13 admin pages
//! using the patterns established here.

pub mod library_paths;
