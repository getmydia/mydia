//! Server functions for the admin pages (U28).
//!
//! Each submodule mirrors the Phoenix `live/admin_*_live/index.ex`
//! event-handler surface. The U23 pilot kept its functions in the
//! flat `server_fns::library_paths` for parity with the pre-port
//! file layout — newer admin pages live here so the surface area
//! groups under one parent.

pub mod devices;
pub mod jobs;
pub mod requests;
pub mod transcodes;
pub mod users;
