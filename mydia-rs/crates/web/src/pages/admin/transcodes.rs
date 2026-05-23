//! Admin → Active transcodes page.
//!
//! Phoenix counterpart: `MydiaWeb.TranscodesLive.Index`. Renders the
//! `transcode_jobs` table with status, progress, and a cancel
//! action. Subscribes to the `transcodes` pubsub topic via WebSocket
//! and reloads the list on every event so the page tracks live
//! progress without polling.

use dioxus::fullstack::{use_websocket, WebSocketOptions};
use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, ProgressBar, ProgressVariant};
use crate::realtime::transcodes::transcodes_ws;
use crate::server_fns::admin::transcodes::{cancel_transcode, list_transcodes, TranscodeRow};

#[component]
pub fn Transcodes() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let jobs = use_resource(move || {
        let _ = reload_token.read();
        async move { list_transcodes().await }
    });

    let mut ws = use_websocket(|| transcodes_ws(WebSocketOptions::new()));

    use_future(move || {
        let mut reload_token = reload_token;
        async move {
            loop {
                match ws.recv().await {
                    Ok(_event) => {
                        // The Phoenix page does the same — every
                        // event is a "redisplay" trigger because
                        // re-fetching the row is cheaper than
                        // maintaining a per-id signal map. We accept
                        // (and drop) the `TranscodeEvent` to keep the
                        // generic on `recv` honest.
                        reload_token.with_mut(|t| *t += 1);
                    }
                    Err(err) => {
                        tracing::warn!(?err, "transcodes WS recv error; stopping fan-in");
                        break;
                    }
                }
            }
        }
    });

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Active transcodes".to_string(),
                subtitle: Some(
                    "Per-resolution HLS jobs feeding the player. Progress streams live.".to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: move |_| reload_token.with_mut(|t| *t += 1),
                        "Refresh"
                    }
                },
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*jobs.read_unchecked() {
                        Some(Ok(rows)) if rows.is_empty() => rsx! {
                            div { id: "admin-transcodes-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "No active transcodes."
                            }
                        },
                        Some(Ok(rows)) => rsx! {
                            div { class: "overflow-x-auto",
                                table { class: "table",
                                    thead {
                                        tr {
                                            th { "Media" }
                                            th { "Status" }
                                            th { class: "w-1/3", "Progress" }
                                            th { class: "text-right", "Actions" }
                                        }
                                    }
                                    tbody { id: "admin-transcodes-rows",
                                        for row in rows.iter().cloned() {
                                            TranscodeRowView {
                                                key: "{row.id}",
                                                row: row,
                                                on_changed: move || reload_token.with_mut(|t| *t += 1),
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error",
                                "Failed to load transcode jobs: {err}"
                            }
                        },
                        None => rsx! {
                            div { class: "py-8 text-center",
                                span { class: "loading loading-spinner loading-md" }
                            }
                        },
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct TranscodeRowProps {
    row: TranscodeRow,
    on_changed: Callback<()>,
}

#[component]
fn TranscodeRowView(props: TranscodeRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_cancel = props.row.id.clone();
    let on_changed = props.on_changed;

    let on_cancel = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_cancel.clone();
        spawn(async move {
            if let Err(err) = cancel_transcode(id).await {
                tracing::warn!(%err, "cancel_transcode failed");
            }
            on_changed.call(());
            acting.set(false);
        });
    };

    let progress_pct = ((props.row.progress.unwrap_or(0.0)) * 100.0).clamp(0.0, 100.0) as f32;
    let label = props
        .row
        .media_file_name
        .clone()
        .unwrap_or_else(|| props.row.media_file_id.clone());

    rsx! {
        tr {
            td {
                div { class: "font-medium", "{label}" }
                div { class: "text-xs text-base-content/60",
                    "{props.row.resolution}"
                    if let Some(started) = props.row.started_at.as_ref() {
                        span { class: "ml-2", "Started {started}" }
                    }
                }
                if let Some(err) = props.row.error.as_ref() {
                    div { class: "text-xs text-error mt-1", "{err}" }
                }
            }
            td {
                StatusPill { status: props.row.status.clone() }
            }
            td {
                div { class: "flex items-center gap-2",
                    ProgressBar {
                        value: progress_pct,
                        variant: ProgressVariant::Primary,
                        class: "w-32".to_string(),
                    }
                    span { class: "text-xs", "{progress_pct:.0}%" }
                }
            }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    disabled: *acting.read(),
                    loading: *acting.read(),
                    onclick: on_cancel,
                    "Cancel"
                }
            }
        }
    }
}
