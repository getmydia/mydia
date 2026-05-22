//! Scan-progress indicator. Renders a `DaisyUI` `progress` bar (or a
//! spinner when total is unknown) tied to the latest
//! [`LibraryScanEvent`] observed for the relevant library path.
//!
//! This component is presentational only — the page owns the Signal
//! that drives it. Splitting it out (instead of inlining in the page)
//! keeps the JSX-shaped layout legible and gives U24+ admin pages a
//! reusable widget for their own progress channels.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::realtime::library_scanner::LibraryScanEvent;

#[derive(Props, Clone, PartialEq)]
pub struct ScanProgressProps {
    /// The most recent event observed for this library path. `None`
    /// means "no scan running" — the component renders nothing.
    pub event: Option<LibraryScanEvent>,
}

#[component]
pub fn ScanProgress(props: ScanProgressProps) -> Element {
    let Some(event) = props.event else {
        return rsx!();
    };

    match event {
        LibraryScanEvent::Started { .. } => rsx! {
            div { class: "flex items-center gap-3 text-sm text-base-content/70",
                span { class: "loading loading-spinner loading-xs" }
                span { "Scan starting..." }
            }
        },
        LibraryScanEvent::Progress {
            stage,
            current,
            total,
            files_found,
            ..
        } => {
            let label = render_label(stage.as_deref(), current, total, files_found);
            let (value, max) = bar_values(current, total, files_found);
            rsx! {
                div { class: "flex flex-col gap-1",
                    div { class: "flex items-center gap-2 text-sm text-base-content/70",
                        span { class: "loading loading-spinner loading-xs" }
                        span { "{label}" }
                    }
                    if let (Some(v), Some(m)) = (value, max) {
                        progress {
                            class: "progress progress-primary w-full",
                            value: "{v}",
                            max: "{m}"
                        }
                    } else {
                        progress { class: "progress progress-primary w-full" }
                    }
                }
            }
        }
        LibraryScanEvent::Completed {
            files_found,
            new_files,
            modified_files,
            ..
        } => {
            let summary = render_completed_summary(files_found, new_files, modified_files);
            rsx! {
                div { class: "flex items-center gap-2 text-sm text-success",
                    Icon { name: "information-circle".to_string(), class: "w-4 h-4".to_string() }
                    span { "{summary}" }
                }
            }
        }
        LibraryScanEvent::Failed { error, reason, .. } => {
            let message = error.or(reason).unwrap_or_else(|| "scan failed".to_owned());
            rsx! {
                div { class: "flex items-center gap-2 text-sm text-error",
                    Icon { name: "exclamation-circle".to_string(), class: "w-4 h-4".to_string() }
                    span { "{message}" }
                }
            }
        }
    }
}

fn render_label(
    stage: Option<&str>,
    current: Option<u64>,
    total: Option<u64>,
    files_found: Option<u64>,
) -> String {
    let stage_text = stage.map_or_else(|| "Scanning".to_owned(), humanize_stage);

    if let (Some(c), Some(t)) = (current, total) {
        format!("{stage_text}: {c} of {t}")
    } else if let Some(f) = files_found {
        format!("{stage_text}: {f} files found")
    } else {
        stage_text
    }
}

fn humanize_stage(stage: &str) -> String {
    match stage {
        "creating_files" => "Importing new files".to_owned(),
        "updating_files" => "Updating modified files".to_owned(),
        "deleting_files" => "Removing deleted files".to_owned(),
        other => other.replace('_', " "),
    }
}

fn bar_values(
    current: Option<u64>,
    total: Option<u64>,
    files_found: Option<u64>,
) -> (Option<u64>, Option<u64>) {
    match (current, total) {
        (Some(c), Some(t)) if t > 0 => (Some(c.min(t)), Some(t)),
        _ => {
            // No explicit total. files_found is a counter without a
            // known upper bound; show indeterminate (None, None) so
            // the bar animates without a misleading fill.
            let _ = files_found;
            (None, None)
        }
    }
}

fn render_completed_summary(
    files_found: Option<u64>,
    new_files: Option<u64>,
    modified_files: Option<u64>,
) -> String {
    match (new_files, modified_files, files_found) {
        (Some(n), Some(m), _) if n + m == 0 => "Scan complete: no changes".to_owned(),
        (Some(n), Some(m), _) => {
            format!("Scan complete: {n} added, {m} modified")
        }
        (_, _, Some(f)) => format!("Scan complete: {f} files"),
        _ => "Scan complete".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_values_known_progress_clamps_to_total() {
        assert_eq!(bar_values(Some(50), Some(100), None), (Some(50), Some(100)));
        // Defensive clamp in case worker emits current > total.
        assert_eq!(
            bar_values(Some(120), Some(100), None),
            (Some(100), Some(100))
        );
    }

    #[test]
    fn bar_values_files_found_only_is_indeterminate() {
        // Without a known total the bar must NOT fake a fraction. We
        // render an indeterminate animated bar instead.
        assert_eq!(bar_values(None, None, Some(42)), (None, None));
    }

    #[test]
    fn bar_values_zero_total_is_indeterminate() {
        // Divide-by-zero would be a bug; the empty library case
        // surfaces as an indeterminate state rather than 0%.
        assert_eq!(bar_values(Some(0), Some(0), None), (None, None));
    }

    #[test]
    fn humanize_stage_known_keys() {
        assert_eq!(humanize_stage("creating_files"), "Importing new files");
        assert_eq!(humanize_stage("updating_files"), "Updating modified files");
        assert_eq!(humanize_stage("custom_stage"), "custom stage");
    }

    #[test]
    fn render_label_prefers_current_total() {
        let s = render_label(Some("creating_files"), Some(5), Some(20), Some(100));
        assert_eq!(s, "Importing new files: 5 of 20");
    }

    #[test]
    fn render_label_falls_back_to_files_found() {
        let s = render_label(None, None, None, Some(42));
        assert_eq!(s, "Scanning: 42 files found");
    }

    #[test]
    fn render_completed_summary_picks_richest_field_set() {
        // Signature: (files_found, new_files, modified_files).
        // Worker-side Completed events carry new + modified; prefer that
        // pair when both are present.
        assert_eq!(
            render_completed_summary(None, Some(10), Some(2)),
            "Scan complete: 10 added, 2 modified"
        );
        assert_eq!(
            render_completed_summary(Some(100), Some(0), Some(0)),
            "Scan complete: no changes"
        );
        // Scanner-walker Completed carries only files_found; fall back.
        assert_eq!(
            render_completed_summary(Some(75), None, None),
            "Scan complete: 75 files"
        );
    }
}
