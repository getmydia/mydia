//! Auth-page components — [`login`] and [`setup`].
//!
//! Both live outside the [`AppShell`](crate::layout::AppShell) guard
//! so an unauthenticated visitor can reach them without bouncing.
//! See `routes.rs` for the `[layout(AuthShell)]` block.

pub mod login;
pub mod setup;
