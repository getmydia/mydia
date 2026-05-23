//! Status badge for admin pages.
//!
//! Phoenix counterpart: the `status_badge_class(status)` private
//! helper duplicated across `admin_*_live/index.ex` files. Centralised
//! here because every admin page uses the same vocabulary
//! (`pending` / `completed` / `failed` / `running` / `cancelled`).

use dioxus::prelude::*;

/// Map a Phoenix-style status string to its `DaisyUI` badge class.
///
/// The unknown branch renders as `badge-ghost` rather than empty so a
/// freshly-added status from the worker side stays readable in the UI
/// during the parallel window.
#[must_use]
pub fn status_pill_class(status: &str) -> &'static str {
    match status {
        "completed" | "approved" | "ready" | "active" | "succeeded" => "badge-success",
        "failed" | "rejected" | "discarded" | "exception" | "error" | "revoked" => "badge-error",
        "cancelled" | "retryable" | "inactive" => "badge-warning",
        "pending" | "scheduled" | "waiting" => "badge-info",
        "executing" | "running" | "transcoding" | "in_progress" | "engage" => "badge-primary",
        _ => "badge-ghost",
    }
}

#[derive(Props, Clone, PartialEq)]
pub struct StatusPillProps {
    pub status: String,
    /// Optional override label. Defaults to a title-cased copy of
    /// `status` (`in_progress` → `In progress`).
    #[props(default)]
    pub label: Option<String>,
    #[props(default)]
    pub class: String,
}

#[component]
pub fn StatusPill(props: StatusPillProps) -> Element {
    let pill_class = status_pill_class(&props.status);
    let label = props
        .label
        .clone()
        .unwrap_or_else(|| humanize_status(&props.status));
    let extra = props.class.clone();
    rsx! {
        span { class: "badge {pill_class} {extra}", "{label}" }
    }
}

fn humanize_status(status: &str) -> String {
    let mut chars = status.replace('_', " ");
    if let Some(first) = chars.get_mut(..1) {
        first.make_ascii_uppercase();
    }
    chars
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_classes_cover_phoenix_vocabulary() {
        assert_eq!(status_pill_class("completed"), "badge-success");
        assert_eq!(status_pill_class("failed"), "badge-error");
        assert_eq!(status_pill_class("pending"), "badge-info");
        assert_eq!(status_pill_class("transcoding"), "badge-primary");
        assert_eq!(status_pill_class("cancelled"), "badge-warning");
        assert_eq!(status_pill_class("revoked"), "badge-error");
        assert_eq!(status_pill_class("mystery"), "badge-ghost");
    }

    #[test]
    fn humanize_replaces_underscores_and_capitalizes() {
        assert_eq!(humanize_status("in_progress"), "In progress");
        assert_eq!(humanize_status("ready"), "Ready");
        assert_eq!(humanize_status(""), "");
    }
}
