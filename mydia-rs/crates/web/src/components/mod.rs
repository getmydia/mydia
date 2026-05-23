//! Three-tier component layout per the project's CLAUDE.md:
//!
//! - `core` — framework-level primitives (button, input, modal, table,
//!   icon, flash). Mirrors `lib/mydia_web/components/core_components.ex`
//!   (`CoreComponents`).
//! - `library`, `admin`, `collection`, `discover`, `feedback`,
//!   `playlist` — shared domain components, mirroring the Phoenix
//!   `*_components.ex` modules. Stubbed in U22; filled out as the
//!   corresponding `LiveView` families port in U24-U28.
//! - Page-private components live under `pages/<family>/components.rs`
//!   and aren't re-exported here.

pub mod admin;
pub mod collection;
pub mod core;
pub mod discover;
pub mod feedback;
pub mod library;
pub mod media;
pub mod playlist;
pub mod scan_progress;
