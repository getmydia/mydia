//! Page components rendered by Route variants.
//!
//! Each top-level Phoenix `LiveView` family gets its own submodule here
//! (e.g., `media`, `admin`, `music`, ...). U22 shipped a placeholder
//! `home` page; U24.e replaced it with the real `dashboard` and `hello`
//! remains as the navigation-link demo target.

pub mod admin;
pub mod auth;
pub mod dashboard;
pub mod discover;
pub mod hello;
pub mod media;
pub mod play;
pub mod profile;
