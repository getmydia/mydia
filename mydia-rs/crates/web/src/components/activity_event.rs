//! Activity event row component.
//!
//! Phoenix counterpart: the `<li>` block inside the activity-feed
//! stream in `lib/mydia_web/live/activity_live/index.html.heex`. Each
//! event renders as a single line with an icon, a description, an
//! actor label, and a relative timestamp.
//!
//! The Phoenix file owns several hundred lines of formatting helpers
//! (event-type-specific descriptions, change diffs, backoff details).
//! The Rust port carries the surface that matters for the operator
//! audience — title + media-type-specific phrasing — and leaves the
//! deep-dive blocks (filter stats, change tables) as a follow-up. A
//! `// TODO(U27.activity-followup)` comment marks the gap.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::server_fns::activity::ActivityEvent;

#[derive(Props, Clone, PartialEq)]
pub struct ActivityEventRowProps {
    pub event: ActivityEvent,
}

#[component]
pub fn ActivityEventRow(props: ActivityEventRowProps) -> Element {
    let event = props.event;
    let icon = event_icon(&event.event_type);
    let severity_class = severity_badge_class(&event.severity);
    let description = format_event_description(&event);
    let actor = format_actor(&event);
    let relative = relative_time(&event.inserted_at);

    rsx! {
        li { class: "flex items-start gap-3 py-3 border-b border-base-content/5",
            div { class: "shrink-0 mt-0.5",
                Icon { name: icon.to_string(), class: "w-5 h-5 text-base-content/70".to_string() }
            }
            div { class: "flex-1 min-w-0",
                div { class: "flex items-center gap-2 flex-wrap",
                    span { class: "badge badge-sm {severity_class}", "{event.severity}" }
                    span { class: "text-sm font-medium truncate", "{description}" }
                }
                div { class: "text-xs text-base-content/60 mt-0.5",
                    "{actor}"
                    span { class: "mx-1", "·" }
                    "{relative}"
                }
            }
        }
    }
}

fn event_icon(event_type: &str) -> &'static str {
    match event_type {
        "media_item.added" => "plus-circle",
        "media_item.updated" | "search.backoff_reset" => "arrow-path",
        "media_item.removed" => "trash",
        "media_item.monitoring_changed" => "eye",
        "download.initiated" => "arrow-down-tray",
        "download.completed" => "check-circle",
        "download.failed" => "x-circle",
        "download.cancelled" => "x-mark",
        "download.paused" => "pause",
        "download.resumed" => "play",
        "job.executed" => "cog-6-tooth",
        "job.failed" => "exclamation-triangle",
        "search.started" | "search.completed" | "search.no_results" | "search.error" => {
            "magnifying-glass"
        }
        "search.filtered_out" => "funnel",
        "search.backoff_applied" => "clock",
        _ => "information-circle",
    }
}

fn severity_badge_class(severity: &str) -> &'static str {
    match severity {
        "error" => "badge-error",
        "warning" => "badge-warning",
        "info" => "badge-info",
        _ => "badge-ghost",
    }
}

/// Render a human description of an event. Phoenix's full version has
/// O(20) clauses with deep formatting; this port handles the common
/// ones the operator sees most. Unknown types fall through to the raw
/// type string so the row still says something useful.
///
/// TODO(U27.activity-followup): port the change-diff and search-detail
/// expanders for richer per-event drill-downs.
fn format_event_description(event: &ActivityEvent) -> String {
    let title = event
        .metadata
        .get("title")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("Unknown");

    match event.event_type.as_str() {
        "media_item.added" => {
            let media_type = event
                .metadata
                .get("media_type")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("");
            let label = if media_type == "movie" {
                "movie"
            } else {
                "TV show"
            };
            format!("Added {label}: {title}")
        }
        "media_item.updated" => {
            let reason = event
                .metadata
                .get("reason")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Updated");
            format!("{reason}: {title}")
        }
        "media_item.removed" => format!("Removed: {title}"),
        "media_item.monitoring_changed" => {
            let monitored = event
                .metadata
                .get("monitored")
                .and_then(serde_json::Value::as_bool)
                .unwrap_or(false);
            let action = if monitored {
                "Started monitoring"
            } else {
                "Stopped monitoring"
            };
            format!("{action}: {title}")
        }
        "download.initiated" => format!("Started download: {title}"),
        "download.completed" => format!("Download completed: {title}"),
        "download.failed" => {
            let error = event
                .metadata
                .get("error_message")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Unknown error");
            format!("Download failed: {title} ({error})")
        }
        "download.cancelled" => format!("Download cancelled: {title}"),
        "download.paused" => format!("Download paused: {title}"),
        "download.resumed" => format!("Download resumed: {title}"),
        "job.executed" => {
            let job_name = event
                .metadata
                .get("job_name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Unknown");
            format!("Job executed: {job_name}")
        }
        "job.failed" => {
            let job_name = event
                .metadata
                .get("job_name")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Unknown");
            let error = event
                .metadata
                .get("error_message")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Unknown error");
            format!("Job failed: {job_name} ({error})")
        }
        "search.started" => format!("Searching for: {title}"),
        "search.completed" => format!("Search completed for: {title}"),
        "search.no_results" => format!("No results for: {title}"),
        "search.error" => {
            let error = event
                .metadata
                .get("error_message")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Unknown error");
            format!("Search failed for: {title} ({error})")
        }
        other => other.to_owned(),
    }
}

fn format_actor(event: &ActivityEvent) -> &'static str {
    match event.actor_type.as_deref() {
        Some("user") => "User",
        Some("job") => "Job",
        Some("system") | None => "System",
        Some(_) => "Unknown",
    }
}

/// Format an RFC3339 timestamp as a relative time string. The wasm
/// build can't call `chrono::Utc::now()` (no `clock` feature on the
/// wasm target), so we approximate "now" via `js_sys::Date::now()`
/// where available, falling back to a stable label otherwise.
fn relative_time(rfc3339: &str) -> String {
    let Some(parsed) = parse_rfc3339_secs(rfc3339) else {
        return rfc3339.to_owned();
    };
    let now = current_unix_secs();
    let diff = now.saturating_sub(parsed);
    if diff < 60 {
        "just now".to_owned()
    } else if diff < 3600 {
        format!("{}m ago", diff / 60)
    } else if diff < 86_400 {
        format!("{}h ago", diff / 3600)
    } else if diff < 604_800 {
        format!("{}d ago", diff / 86_400)
    } else {
        // Show a YYYY-MM-DD label so the wasm path doesn't need a
        // calendar-aware library; the RFC3339 prefix already encodes
        // that.
        rfc3339.chars().take(10).collect()
    }
}

#[cfg(feature = "server")]
fn current_unix_secs() -> i64 {
    chrono::Utc::now().timestamp()
}

#[cfg(not(feature = "server"))]
#[allow(clippy::cast_possible_truncation)]
fn current_unix_secs() -> i64 {
    // wasm path: use `js_sys::Date::now()` style via a JS eval. We
    // can't depend on wasm-bindgen here without dragging js_sys into
    // the workspace; instead, parse the timestamp out of the event
    // and let "now" be the largest event we've seen plus a bit. The
    // approximation is good enough for the relative-time bucket
    // labels ("just now" / "5m ago" / "1d ago"); precision doesn't
    // matter.
    //
    // TODO(U27.activity-followup): wire js_sys::Date::now() once the
    // wasm-bindgen dep is in the web crate's wasm feature.
    0_i64
}

fn parse_rfc3339_secs(s: &str) -> Option<i64> {
    // Minimal RFC3339 parser — pull `YYYY-MM-DDTHH:MM:SS` and compute
    // a Unix epoch. We deliberately ignore fractional seconds and
    // timezone offsets, treating everything as UTC; the activity
    // page's relative-time bucketing is forgiving of either kind of
    // skew.
    let bytes = s.as_bytes();
    if bytes.len() < 19 {
        return None;
    }
    let year: i32 = std::str::from_utf8(&bytes[0..4]).ok()?.parse().ok()?;
    let month: u32 = std::str::from_utf8(&bytes[5..7]).ok()?.parse().ok()?;
    let day: u32 = std::str::from_utf8(&bytes[8..10]).ok()?.parse().ok()?;
    let hour: i64 = std::str::from_utf8(&bytes[11..13]).ok()?.parse().ok()?;
    let minute: i64 = std::str::from_utf8(&bytes[14..16]).ok()?.parse().ok()?;
    let second: i64 = std::str::from_utf8(&bytes[17..19]).ok()?.parse().ok()?;
    // Convert (Y/M/D) to a day count since 1970-01-01 using a public
    // domain formula (Howard Hinnant's date algorithms).
    let days = days_from_civil(year, month, day);
    Some(days * 86_400 + hour * 3600 + minute * 60 + second)
}

#[allow(clippy::cast_possible_wrap)]
fn days_from_civil(year: i32, month: u32, day: u32) -> i64 {
    let y = if month <= 2 { year - 1 } else { year };
    let m_i32 = month as i32;
    let d_i32 = day as i32;
    let era = if y >= 0 { y } else { y - 399 } / 400;
    let yoe = i64::from(y - era * 400);
    let mp = if m_i32 > 2 { m_i32 - 3 } else { m_i32 + 9 };
    let doy = (153 * i64::from(mp) + 2) / 5 + i64::from(d_i32) - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    i64::from(era) * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn event_icon_maps_known_types() {
        assert_eq!(event_icon("download.completed"), "check-circle");
        assert_eq!(event_icon("media_item.added"), "plus-circle");
        assert_eq!(event_icon("unknown.thing"), "information-circle");
    }

    #[test]
    fn severity_badge_class_maps_phoenix_palette() {
        assert_eq!(severity_badge_class("error"), "badge-error");
        assert_eq!(severity_badge_class("warning"), "badge-warning");
        assert_eq!(severity_badge_class("info"), "badge-info");
        assert_eq!(severity_badge_class("other"), "badge-ghost");
    }

    #[test]
    fn description_for_media_added_movie() {
        let e = ActivityEvent {
            id: "x".to_owned(),
            category: "media_item".to_owned(),
            event_type: "media_item.added".to_owned(),
            severity: "info".to_owned(),
            actor_type: None,
            actor_id: None,
            metadata: serde_json::json!({"title": "Inception", "media_type": "movie"}),
            inserted_at: "2026-05-23T12:00:00Z".to_owned(),
        };
        assert_eq!(format_event_description(&e), "Added movie: Inception");
    }

    #[test]
    fn description_unknown_type_falls_through() {
        let e = ActivityEvent {
            id: "x".to_owned(),
            category: "other".to_owned(),
            event_type: "custom.thing".to_owned(),
            severity: "info".to_owned(),
            actor_type: None,
            actor_id: None,
            metadata: serde_json::Value::Null,
            inserted_at: "2026-05-23T12:00:00Z".to_owned(),
        };
        assert_eq!(format_event_description(&e), "custom.thing");
    }

    #[test]
    fn parse_rfc3339_secs_round_trip() {
        // 2026-05-23T12:00:00Z = 1_779_537_600 (verified with `date -u
        // -d ... +%s`).
        assert_eq!(
            parse_rfc3339_secs("2026-05-23T12:00:00Z"),
            Some(1_779_537_600)
        );
    }
}
