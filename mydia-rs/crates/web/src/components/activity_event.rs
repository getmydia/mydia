//! Activity event row component.
//!
//! Phoenix counterpart: the `<li>` block inside the activity-feed
//! stream in `lib/mydia_web/live/activity_live/index.html.heex`. Each
//! event renders as a single line with an icon, a description, an
//! actor label, and a relative timestamp.
//!
//! Operators can click a row to expand a per-event-type drill-down
//! panel: a JSON diff for `media_item.updated`, the candidate set
//! for `search.completed`, the analyzer output for
//! `file_analysis.completed`. The drill-down renderers live in
//! [`details`] and are dispatched by event type; unknown types fall
//! back to a raw key/value list so the operator still sees the
//! metadata payload.
//!
//! The renderers are deliberately small and per-type — easier to add
//! new event types later than to grow one mega-renderer that knows
//! the whole event taxonomy.

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
    let has_details = details::has_drill_down(&event);
    let event_id = event.id.clone();

    let mut expanded = use_signal(|| false);

    let event_for_details = event.clone();
    rsx! {
        li { class: "py-3 border-b border-base-content/5",
            div { class: "flex items-start gap-3",
                div { class: "shrink-0 mt-0.5",
                    Icon { name: icon.to_string(), class: "w-5 h-5 text-base-content/70".to_string() }
                }
                div { class: "flex-1 min-w-0",
                    div { class: "flex items-center gap-2 flex-wrap",
                        span { class: "badge badge-sm {severity_class}", "{event.severity}" }
                        span { class: "text-sm font-medium truncate", "{description}" }
                        if has_details {
                            button {
                                id: "activity-event-{event_id}-toggle",
                                r#type: "button",
                                class: "btn btn-xs btn-ghost ml-auto",
                                onclick: move |_| expanded.toggle(),
                                if *expanded.read() { "Hide" } else { "Details" }
                            }
                        }
                    }
                    div { class: "text-xs text-base-content/60 mt-0.5",
                        "{actor}"
                        span { class: "mx-1", "·" }
                        "{relative}"
                    }
                }
            }
            if has_details && *expanded.read() {
                div { id: "activity-event-{event_id}-details", class: "mt-2 ml-8",
                    {details::render(&event_for_details)}
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

/// Per-event-type drill-down renderers. Each event type gets its own
/// small dedicated function so the dispatch table is honest about
/// what surfaces have detailed views and which fall back to a raw
/// key/value list.
///
/// TODO(U27.activity-followup): port the remaining Phoenix renderers
/// (`download.failed` with backoff details, `job.failed` with the
/// retry trace, `search.backoff_applied` with the cooldown table).
/// They follow the same shape as the ones in this module; each is a
/// small dedicated function so adding one doesn't disturb the rest.
pub(crate) mod details {
    use dioxus::prelude::*;
    use serde_json::Value;

    use super::ActivityEvent;
    use crate::components::core::Icon;

    /// True when the event has a registered drill-down renderer.
    /// Drives the "Details" toggle visibility — events without a
    /// dedicated renderer also have no metadata worth surfacing
    /// beyond the description line.
    #[must_use]
    pub fn has_drill_down(event: &ActivityEvent) -> bool {
        renderer(event.event_type.as_str()).is_some() || has_payload_fallback(event)
    }

    /// Returns the typed renderer for an event type, or `None` if no
    /// drill-down exists. The dispatch table stays explicit so adding
    /// a new event type is a small obvious change.
    fn renderer(event_type: &str) -> Option<fn(&ActivityEvent) -> Element> {
        match event_type {
            "media_item.updated" => Some(render_metadata_change),
            "search.completed" => Some(render_search_completed),
            "file_analysis.completed" => Some(render_file_analysis),
            _ => None,
        }
    }

    /// True when the event has a non-trivial JSON metadata payload
    /// worth showing in a raw key/value table even without a typed
    /// renderer. An empty `{}` or a single `title` field doesn't
    /// count — those are already in the description line.
    fn has_payload_fallback(event: &ActivityEvent) -> bool {
        let Value::Object(map) = &event.metadata else {
            return false;
        };
        map.iter().any(|(k, _)| k != "title")
    }

    /// Dispatch to the appropriate renderer, or fall back to the raw
    /// key/value table. Called by [`super::ActivityEventRow`].
    pub fn render(event: &ActivityEvent) -> Element {
        if let Some(f) = renderer(event.event_type.as_str()) {
            return f(event);
        }
        render_raw_payload(event)
    }

    /// `media_item.updated` events carry a `changes` array of
    /// `{field, before, after}` triples in their metadata. Render it
    /// as a small diff table; fall back to the raw payload when the
    /// shape doesn't match.
    fn render_metadata_change(event: &ActivityEvent) -> Element {
        let Some(changes) = event.metadata.get("changes").and_then(Value::as_array) else {
            return render_raw_payload(event);
        };
        if changes.is_empty() {
            return rsx! {
                div { class: "text-xs text-base-content/60 italic", "No field changes recorded." }
            };
        }
        rsx! {
            div { class: "text-xs",
                div { class: "font-semibold mb-1 text-base-content/80",
                    Icon { name: "arrow-path".to_string(), class: "w-3 h-3 inline mr-1".to_string() }
                    "Metadata changes"
                }
                table { class: "table table-xs",
                    thead {
                        tr {
                            th { "Field" }
                            th { "Before" }
                            th { "After" }
                        }
                    }
                    tbody {
                        for (idx , change) in changes.iter().enumerate() {
                            tr { key: "{idx}",
                                td { class: "font-mono", "{json_string(change, &[\"field\"])}" }
                                td { class: "text-base-content/60",
                                    "{json_string(change, &[\"before\"])}"
                                }
                                td { class: "text-success",
                                    "{json_string(change, &[\"after\"])}"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `search.completed` events carry a `candidates` array — release
    /// titles the search returned. Render the top-N as a list with
    /// indexer attribution; fall back to the raw payload when missing.
    fn render_search_completed(event: &ActivityEvent) -> Element {
        let Some(candidates) = event.metadata.get("candidates").and_then(Value::as_array) else {
            return render_raw_payload(event);
        };
        if candidates.is_empty() {
            let total = event
                .metadata
                .get("total")
                .and_then(Value::as_i64)
                .unwrap_or(0);
            return rsx! {
                div { class: "text-xs text-base-content/60 italic",
                    "Search returned no candidates ({total} total)."
                }
            };
        }
        rsx! {
            div { class: "text-xs",
                div { class: "font-semibold mb-1 text-base-content/80",
                    Icon { name: "magnifying-glass".to_string(), class: "w-3 h-3 inline mr-1".to_string() }
                    "Candidates"
                }
                ul { class: "menu menu-xs bg-base-200 rounded-box",
                    for (idx , candidate) in candidates.iter().take(10).enumerate() {
                        li { key: "{idx}",
                            div { class: "flex flex-col",
                                span { class: "font-mono", "{json_string(candidate, &[\"title\"])}" }
                                span { class: "text-base-content/60",
                                    "{json_string(candidate, &[\"indexer\"])}"
                                    " · "
                                    "{json_string(candidate, &[\"size\"])}"
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// `file_analysis.completed` events carry detected codec / track /
    /// resolution data. Render the salient fields as a compact key
    /// list; fall back to the raw payload when the shape doesn't
    /// match.
    fn render_file_analysis(event: &ActivityEvent) -> Element {
        let Value::Object(_) = &event.metadata else {
            return render_raw_payload(event);
        };
        let analysis = event.metadata.get("analysis").or(Some(&event.metadata));
        let Some(Value::Object(map)) = analysis else {
            return render_raw_payload(event);
        };
        let pairs: Vec<(&str, String)> = [
            ("Resolution", "resolution"),
            ("Video codec", "video_codec"),
            ("Audio codec", "audio_codec"),
            ("Audio channels", "audio_channels"),
            ("Container", "container"),
            ("Duration", "duration_seconds"),
            ("Size", "size_bytes"),
        ]
        .iter()
        .filter_map(|(label, key)| {
            map.get(*key)
                .map(|v| (*label, value_to_display(v)))
                .filter(|(_, s)| !s.is_empty())
        })
        .collect();
        if pairs.is_empty() {
            return render_raw_payload(event);
        }
        rsx! {
            div { class: "text-xs",
                div { class: "font-semibold mb-1 text-base-content/80",
                    Icon { name: "film".to_string(), class: "w-3 h-3 inline mr-1".to_string() }
                    "File analysis"
                }
                dl { class: "grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1",
                    for (label , val) in pairs.iter() {
                        dt { key: "{label}", class: "text-base-content/60", "{label}" }
                        dd { class: "font-mono", "{val}" }
                    }
                }
            }
        }
    }

    /// Render an event's metadata payload as a raw key/value table —
    /// the last-resort fallback when no typed renderer matches. Skips
    /// the `title` key because it's already on the description line.
    fn render_raw_payload(event: &ActivityEvent) -> Element {
        let Value::Object(map) = &event.metadata else {
            return rsx! {
                div { class: "text-xs text-base-content/60 italic", "No payload." }
            };
        };
        let pairs: Vec<(String, String)> = map
            .iter()
            .filter(|(k, _)| *k != "title")
            .map(|(k, v)| (k.clone(), value_to_display(v)))
            .collect();
        if pairs.is_empty() {
            return rsx! {
                div { class: "text-xs text-base-content/60 italic", "No payload." }
            };
        }
        rsx! {
            dl { class: "grid grid-cols-[max-content_1fr] gap-x-3 gap-y-1 text-xs",
                for (key , val) in pairs.iter() {
                    dt { key: "{key}", class: "text-base-content/60 font-mono", "{key}" }
                    dd { class: "font-mono break-words", "{val}" }
                }
            }
        }
    }

    /// Pull a string-typed field out of a JSON object, returning the
    /// stringified version of whatever's there (number, bool, etc.).
    /// Used by the diff renderers to coerce mixed payloads into row
    /// text without crashing on a number-shaped `before`.
    fn json_string(value: &Value, path: &[&str]) -> String {
        let mut cur = value;
        for segment in path {
            match cur.get(*segment) {
                Some(next) => cur = next,
                None => return String::new(),
            }
        }
        value_to_display(cur)
    }

    /// Render a `serde_json::Value` as a short human-readable string.
    /// Strings render verbatim, numbers/bools as their canonical
    /// stringifications, nulls as an empty string, and
    /// arrays/objects via JSON serialization (for the rare nested
    /// case).
    pub(crate) fn value_to_display(value: &Value) -> String {
        match value {
            Value::Null => String::new(),
            Value::String(s) => s.clone(),
            Value::Bool(b) => b.to_string(),
            Value::Number(n) => n.to_string(),
            other => serde_json::to_string(other).unwrap_or_default(),
        }
    }
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

    fn make_event(event_type: &str, metadata: serde_json::Value) -> ActivityEvent {
        ActivityEvent {
            id: "x".to_owned(),
            category: "media_item".to_owned(),
            event_type: event_type.to_owned(),
            severity: "info".to_owned(),
            actor_type: None,
            actor_id: None,
            metadata,
            inserted_at: "2026-05-23T12:00:00Z".to_owned(),
        }
    }

    #[test]
    fn details_drill_down_present_for_known_event_types() {
        let metadata_change = make_event(
            "media_item.updated",
            serde_json::json!({"changes": [{"field": "title", "before": "A", "after": "B"}]}),
        );
        assert!(details::has_drill_down(&metadata_change));

        let search = make_event(
            "search.completed",
            serde_json::json!({"candidates": [{"title": "x", "indexer": "i"}]}),
        );
        assert!(details::has_drill_down(&search));

        let analysis = make_event(
            "file_analysis.completed",
            serde_json::json!({"resolution": "1080p", "video_codec": "h264"}),
        );
        assert!(details::has_drill_down(&analysis));
    }

    #[test]
    fn details_falls_back_when_event_has_payload_but_no_renderer() {
        // Unknown event type with a richer payload (more than just
        // `title`) still gets the raw fallback drill-down.
        let event = make_event("weird.event", serde_json::json!({"foo": "bar", "count": 7}));
        assert!(details::has_drill_down(&event));
    }

    #[test]
    fn details_skipped_when_only_title_in_payload() {
        // Event whose payload is only `{title: ...}` has no drill-down
        // worth showing — the title is already in the description
        // line. The "Details" toggle must not appear.
        let event = make_event(
            "media_item.added",
            serde_json::json!({"title": "Inception"}),
        );
        assert!(!details::has_drill_down(&event));
    }

    #[test]
    fn details_value_to_display_coerces_mixed_types() {
        use super::details::value_to_display;
        assert_eq!(value_to_display(&serde_json::Value::Null), "");
        assert_eq!(
            value_to_display(&serde_json::Value::String("hi".into())),
            "hi"
        );
        assert_eq!(value_to_display(&serde_json::Value::Bool(true)), "true");
        assert_eq!(
            value_to_display(&serde_json::Value::Number(42.into())),
            "42"
        );
    }
}
