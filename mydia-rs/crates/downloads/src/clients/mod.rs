//! Per-adapter implementations of [`crate::adapter::DownloadClient`].
//!
//! Each submodule talks to one external client API. The modules are
//! sized to roughly match their Phoenix counterparts in
//! `lib/mydia/downloads/client/*.ex` — the layout is one Rust module
//! per Phoenix module, no namespace flattening, so the parallel
//! window can grep across both code bases for the same feature.

pub mod blackhole;
pub mod debrid;
pub mod http;
pub mod nzbget;
pub mod qbittorrent;
pub mod rtorrent;
pub mod sabnzbd;
pub mod transmission;
