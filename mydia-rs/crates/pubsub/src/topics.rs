//! Canonical `PubSub` topic constants.
//!
//! Phoenix uses bare topic strings everywhere (`"library_scanner"`,
//! `"jobs:status"`, `"thumbnail_generation"`, ...). mydia-rs mirrors
//! the wire format exactly so a Dioxus `WebSocket` or `GraphQL`
//! subscription publishes / subscribes against the same string the
//! Phoenix `LiveViews` use today — keeps the parallel window honest.
//!
//! Two flavors:
//!
//! - **Static topics** — fixed strings. Use the `pub const FOO: &str = ...`
//!   declarations directly.
//! - **Templated topics** — interpolated with a `user_id` or `node_id`. Use
//!   the `*_for(...)` helper functions so the format string lives in
//!   exactly one place.
//!
//! ## Provenance
//!
//! Every constant below is grep-traceable to a Phoenix module that
//! either publishes or subscribes to the topic. Updates here should
//! be mirrored in the corresponding U17 worker (publish side) or
//! GraphQL subscription resolver (subscribe side).

// -- Static topics --------------------------------------------------------

/// Library scanner progress events (`scan_started`, `scan_progress`,
/// `scan_completed`, `scan_failed`). Published by U17's
/// `LibraryScanner`, `LibraryReorganize`, `MediaReclassify` workers;
/// subscribed by U23's admin library-paths page.
///
/// Phoenix reference: `lib/mydia/jobs/library_scanner.ex:200+`.
pub const LIBRARY_SCANNER: &str = "library_scanner";

/// Oban telemetry-bridged job status events. Phoenix's
/// `Mydia.Jobs.Broadcaster` re-publishes Oban `[:oban, :job, :start]`
/// / `:stop` / `:exception` telemetry on this topic; mydia-rs
/// publishes from the apalis telemetry shim in this crate.
///
/// Phoenix reference: `lib/mydia/jobs/broadcaster.ex:12`.
pub const JOBS_STATUS: &str = "jobs:status";

/// Thumbnail-generation progress and completion events.
///
/// Phoenix reference: `lib/mydia/jobs/thumbnail_generation.ex:58`.
pub const THUMBNAIL_GENERATION: &str = "thumbnail_generation";

/// Generic download-progress events (qbittorrent, transmission, ...).
///
/// Phoenix reference: `lib/mydia/downloads/*.ex` broadcast sites.
pub const DOWNLOADS: &str = "downloads";

/// Transcode job lifecycle (queued / running / completed / failed).
pub const TRANSCODES: &str = "transcodes";

/// HLS streaming session lifecycle events.
pub const HLS_SESSIONS: &str = "hls_sessions";

/// Music player state (now-playing, queue, scrub position) shared
/// across pages by the persistent music-player component.
pub const MUSIC_PLAYER: &str = "music_player";

/// Cross-cutting event stream the activity feed subscribes to. Every
/// `Mydia.Events.record/2` write fans out here.
pub const EVENTS_ALL: &str = "events:all";

/// Import-list scheduler progress (TMDB watchlist sync, custom-URL
/// list sync, ...).
pub const IMPORT_LISTS: &str = "import_lists";

/// Remote-access claim-code lifecycle (created / consumed / expired).
pub const REMOTE_ACCESS_CLAIMS: &str = "remote_access:claims";

// -- Templated topics -----------------------------------------------------

/// Per-media-item progress topic. The key IS the encoded global node
/// ID — `movie:<uuid>` or `episode:<uuid>` — matching Phoenix's
/// `topic: args.node_id` shape in
/// `lib/mydia_web/schema/subscription_types.ex`.
///
/// Use the encoded form directly as the topic; this helper is a
/// no-op wrapper for call-site readability and to anchor the
/// convention in one place. Producers should pass the result of
/// [`crate::Pubsub::publish`] and `mydia_rs_graphql::node_id::NodeId::encode()`;
/// subscribers in [`crate::Pubsub::subscribe`] do the same.
#[must_use]
pub fn progress_for(encoded_node_id: &str) -> String {
    encoded_node_id.to_owned()
}

/// Per-user device-status topic. Used by `deviceStatusChanged`
/// subscription and any worker that emits connect / disconnect /
/// revoke events for a specific user's paired devices.
///
/// Phoenix reference: `subscription_types.ex`
/// `topic: "device_status:#{args.user_id}"`.
#[must_use]
pub fn device_status_for(user_id: &str) -> String {
    format!("device_status:{user_id}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn static_constants_are_stable() {
        // These strings are part of the cross-backend wire contract during
        // the parallel window. Changing one is a behavior change, not a
        // refactor. The asserts catch accidental edits.
        assert_eq!(LIBRARY_SCANNER, "library_scanner");
        assert_eq!(JOBS_STATUS, "jobs:status");
        assert_eq!(THUMBNAIL_GENERATION, "thumbnail_generation");
        assert_eq!(DOWNLOADS, "downloads");
        assert_eq!(TRANSCODES, "transcodes");
        assert_eq!(HLS_SESSIONS, "hls_sessions");
        assert_eq!(MUSIC_PLAYER, "music_player");
        assert_eq!(EVENTS_ALL, "events:all");
        assert_eq!(IMPORT_LISTS, "import_lists");
        assert_eq!(REMOTE_ACCESS_CLAIMS, "remote_access:claims");
    }

    #[test]
    fn device_status_topic_is_user_keyed() {
        assert_eq!(
            device_status_for("550e8400-e29b-41d4-a716-446655440000"),
            "device_status:550e8400-e29b-41d4-a716-446655440000"
        );
    }

    #[test]
    fn progress_topic_passes_through_encoded_id() {
        assert_eq!(progress_for("movie:abc-uuid"), "movie:abc-uuid");
        assert_eq!(progress_for("episode:xyz-uuid"), "episode:xyz-uuid");
    }
}
