//! Admin pages.
//!
//! U23 ships the deliberate pilot — [`library_paths`] — which exercises
//! every plumbing seam Phase 4 needs (server-fn CRUD, form validation
//! round-trips, realtime WebSocket subscription, real-time `DaisyUI`
//! progress component). U28 fills out the operational slice on top
//! of those primitives: jobs, transcodes, users, devices, requests.
//!
//! Pages NOT in this module — system settings, quality profiles,
//! download clients, indexers, media servers, remote access,
//! import lists, release blacklist — are configuration-heavy
//! surfaces. They follow in a U28 follow-up cohort once the
//! `components/admin/config_form` primitive lands; see the
//! corresponding `// TODO(U28-follow-up):` notes in `layout.rs`.

pub mod devices;
pub mod jobs;
pub mod library_paths;
pub mod requests;
pub mod transcodes;
pub mod users;
