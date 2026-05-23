//! Server functions for the admin pages (U28).
//!
//! Each submodule mirrors the Phoenix `live/admin_*_live/index.ex`
//! event-handler surface. The U23 pilot kept its functions in the
//! flat `server_fns::library_paths` for parity with the pre-port
//! file layout — newer admin pages live here so the surface area
//! groups under one parent.

pub mod devices;
pub mod download_clients;
pub mod import_lists;
pub mod indexers;
pub mod jobs;
pub mod media_servers;
pub mod quality_profiles;
pub mod release_blacklist;
pub mod remote_access;
pub mod requests;
pub mod settings;
pub mod system;
pub mod transcodes;
pub mod users;
