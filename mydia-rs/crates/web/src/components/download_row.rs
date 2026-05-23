//! Download row component.
//!
//! Phoenix counterpart: the per-download `<tr>` block in
//! `lib/mydia_web/live/downloads_live/index.html.heex`. Renders the
//! display title, the optional season/episode marker, the status pill,
//! and a progress bar. The cancel control is wired through a callback
//! so the page owns the mutation flow.

use dioxus::prelude::*;

use crate::components::admin::StatusPill;
use crate::components::core::{Button, ButtonSize, ButtonVariant, ProgressBar};
use crate::server_fns::downloads::DownloadRow;

#[derive(Props, Clone, PartialEq)]
pub struct DownloadRowProps {
    pub row: DownloadRow,
    /// Called when the operator clicks "Cancel" — the page wires this
    /// to `cancel_download(...)` and refetches.
    pub on_cancel: Callback<String>,
    /// Called when the operator clicks "Match" on an unmatched row.
    /// The page opens its manual-match modal.
    #[props(default)]
    pub on_match: Option<Callback<DownloadRow>>,
    /// True iff the operator's role can manage downloads. Hides the
    /// cancel button when false (Phoenix `Authorization.authorize_manage_downloads`).
    #[props(default = true)]
    pub can_manage: bool,
}

#[component]
pub fn DownloadRowView(props: DownloadRowProps) -> Element {
    let row = props.row.clone();
    let on_cancel = props.on_cancel;
    let on_match = props.on_match;

    let display_title = display_title(&row);
    let subtitle = subtitle(&row);
    #[allow(clippy::cast_possible_truncation)]
    let progress_pct = (row.progress.unwrap_or(0.0).clamp(0.0, 1.0) * 100.0) as f32;
    let id_for_cancel = row.id.clone();
    let row_for_match = row.clone();
    let is_active = matches!(
        row.status.as_str(),
        "downloading" | "checking" | "queued" | "paused" | "seeding"
    );
    let needs_match = is_unmatched(&row);

    rsx! {
        tr { id: "download-row-{row.id}",
            td {
                div { class: "font-medium", "{display_title}" }
                if let Some(sub) = subtitle.as_ref() {
                    div { class: "text-xs text-base-content/60", "{sub}" }
                }
            }
            td { class: "min-w-[100px]",
                StatusPill { status: row.status.clone() }
            }
            td { class: "min-w-[160px]",
                ProgressBar {
                    value: progress_pct,
                    class: "w-full".to_string(),
                }
                div { class: "text-xs text-base-content/60 mt-1", "{format_progress(row.progress)}" }
            }
            td { class: "text-xs",
                if let Some(indexer) = row.indexer.as_ref() {
                    div { "{indexer}" }
                }
                if let Some(client) = row.download_client.as_ref() {
                    div { class: "text-base-content/60", "{client}" }
                }
            }
            td { class: "text-right whitespace-nowrap",
                if props.can_manage && needs_match {
                    if let Some(on_match) = on_match {
                        Button {
                            variant: ButtonVariant::Primary,
                            size: ButtonSize::Sm,
                            onclick: move |_| on_match.call(row_for_match.clone()),
                            "Match"
                        }
                        span { class: "mx-1" }
                    }
                }
                if props.can_manage && is_active {
                    Button {
                        variant: ButtonVariant::Error,
                        size: ButtonSize::Sm,
                        onclick: move |_| on_cancel.call(id_for_cancel.clone()),
                        "Cancel"
                    }
                } else if !is_active && !needs_match && !row.status.is_empty() {
                    span { class: "text-xs text-base-content/60",
                        "{row.status}"
                    }
                }
            }
        }
        if let Some(err) = row.error_message.as_ref() {
            tr {
                td { colspan: "5", class: "text-xs text-error pb-3", "{err}" }
            }
        }
    }
}

/// True when a download row needs an operator manual match. Phoenix
/// flags this via `match_status = "unmatched"` after the auto-matcher
/// fails to associate the release with a `media_items` row, and via
/// `media_item_id IS NULL` for legacy rows that pre-date the column.
fn is_unmatched(row: &DownloadRow) -> bool {
    if row.media_item_id.is_some() {
        return false;
    }
    matches!(row.match_status.as_deref(), Some("unmatched") | None)
}

fn display_title(row: &DownloadRow) -> String {
    row.media_item_title
        .clone()
        .unwrap_or_else(|| row.title.clone())
}

fn subtitle(row: &DownloadRow) -> Option<String> {
    if let (Some(s), Some(e)) = (row.episode_season, row.episode_number) {
        return Some(format!("S{s:02}E{e:02}"));
    }
    if row.media_item_type.as_deref() == Some("tv_show") {
        return Some("Series download".to_owned());
    }
    None
}

fn format_progress(progress: Option<f64>) -> String {
    match progress {
        Some(p) => format!("{:.1}%", p * 100.0),
        None => "—".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn make_row() -> DownloadRow {
        DownloadRow {
            id: "d1".to_owned(),
            title: "Show.S01E01.mkv".to_owned(),
            status: "downloading".to_owned(),
            progress: Some(0.5),
            indexer: Some("indexer".to_owned()),
            download_client: Some("qbittorrent".to_owned()),
            error_message: None,
            inserted_at: "2026-05-23T10:00:00Z".to_owned(),
            completed_at: None,
            media_item_title: Some("Show".to_owned()),
            media_item_id: Some("m1".to_owned()),
            media_item_type: Some("tv_show".to_owned()),
            episode_season: Some(1),
            episode_number: Some(1),
            bytes_pulled: None,
            import_failed_at: None,
            match_status: None,
        }
    }

    #[test]
    fn display_title_prefers_media_item() {
        assert_eq!(display_title(&make_row()), "Show");
    }

    #[test]
    fn display_title_falls_back_to_torrent_title() {
        let mut row = make_row();
        row.media_item_title = None;
        assert_eq!(display_title(&row), "Show.S01E01.mkv");
    }

    #[test]
    fn subtitle_with_season_episode() {
        assert_eq!(subtitle(&make_row()), Some("S01E01".to_owned()));
    }

    #[test]
    fn subtitle_show_level() {
        let mut row = make_row();
        row.episode_season = None;
        row.episode_number = None;
        assert_eq!(subtitle(&row), Some("Series download".to_owned()));
    }

    #[test]
    fn format_progress_rounds_to_one_decimal() {
        assert_eq!(format_progress(Some(0.5)), "50.0%");
        assert_eq!(format_progress(None), "—");
    }

    #[test]
    fn is_unmatched_when_no_media_item_and_unmatched_status() {
        let mut row = make_row();
        row.media_item_id = None;
        row.match_status = Some("unmatched".to_owned());
        assert!(is_unmatched(&row));
    }

    #[test]
    fn is_unmatched_false_when_media_item_present() {
        // A row with a media_item_id is matched even if match_status is
        // somehow stale — the foreign-key truth wins over the cached
        // string.
        let mut row = make_row();
        row.media_item_id = Some("m1".to_owned());
        row.match_status = Some("unmatched".to_owned());
        assert!(!is_unmatched(&row));
    }

    #[test]
    fn is_unmatched_handles_legacy_null_match_status() {
        let mut row = make_row();
        row.media_item_id = None;
        row.match_status = None;
        assert!(is_unmatched(&row));
    }
}
