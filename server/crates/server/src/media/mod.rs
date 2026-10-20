//! Media byte serving. HTTP concerns only; every decision belongs to
//! mydia-streaming.

pub mod auth;
pub mod range;
pub mod remux;
pub mod stream;
pub mod subtitles;

use axum::http::HeaderName;

/// Response header naming how the bytes are served ("direct" or "remux").
pub(crate) const STREAMING_MODE: HeaderName = HeaderName::from_static("x-streaming-mode");
