//! DB-layer query helpers — the Rust counterpart of Phoenix's
//! `Mydia.Media`, `Mydia.Settings`, `Mydia.Library`, `Mydia.Playback`,
//! `Mydia.Accounts`, `Mydia.Collections` context modules.

pub mod accounts;
pub mod api_keys;
pub mod collections;
pub mod collections_query;
pub mod media;
pub mod playback;
pub mod settings;
