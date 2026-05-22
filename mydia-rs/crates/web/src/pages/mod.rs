//! Page components rendered by Route variants.
//!
//! Each top-level Phoenix `LiveView` family gets its own submodule here
//! (e.g., `media`, `admin`, `music`, ...). U22 ships only `home` and
//! `hello` to prove the router + layout chain works.

pub mod admin;
pub mod auth;
pub mod hello;
pub mod home;
pub mod profile;
