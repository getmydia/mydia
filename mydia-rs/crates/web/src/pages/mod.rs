//! Page components rendered by Route variants.
//!
//! Each top-level Phoenix `LiveView` family gets its own submodule here
//! (e.g., `media`, `admin`, `music`, ...). U22 shipped a placeholder
//! `home` page; U24.e replaced it with the real `dashboard` and `hello`
//! remains as the navigation-link demo target.

pub mod activity;
pub mod add_media;
pub mod admin;
pub mod auth;
pub mod calendar;
pub mod dashboard;
pub mod discover;
pub mod downloads;
pub mod hello;
pub mod import_media;
pub mod media;
pub mod my_requests;
pub mod profile;
pub mod request_media;
