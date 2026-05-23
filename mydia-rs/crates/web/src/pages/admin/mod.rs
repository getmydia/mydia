//! Admin pages.
//!
//! U23 ships the deliberate pilot — [`library_paths`] — which exercises
//! every plumbing seam Phase 4 needs (server-fn CRUD, form validation
//! round-trips, realtime WebSocket subscription, real-time `DaisyUI`
//! progress component). U28 fills out the operational slice on top
//! of those primitives: jobs, transcodes, users, devices, requests.
//!
//! The U28 follow-up cohort lands the configuration-heavy surfaces —
//! system, settings, download clients, indexers, media servers,
//! remote access, import lists, release blacklist, and the
//! quality-profiles scaffold. Each is a thin shell over the
//! corresponding server-fn module; the shared chrome lives in
//! `components/admin/config_form`.

pub mod devices;
pub mod download_clients;
pub mod import_lists;
pub mod indexers;
pub mod jobs;
pub mod library_paths;
pub mod media_servers;
pub mod quality_profiles;
pub mod release_blacklist;
pub mod remote_access;
pub mod requests;
pub mod settings;
pub mod system;
pub mod transcodes;
pub mod users;
