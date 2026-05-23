//! Downloads queue page.
//!
//! Phoenix counterpart: `MydiaWeb.DownloadsLive.Index`. Renders the
//! Queue / Completed / Issues tabs with a paginated row list. The
//! Rust port wires a WebSocket fan-in on the `downloads` pubsub topic
//! that drives a "refresh on any event" pattern, matching Phoenix's
//! `handle_info({:download_updated, _}, _) -> {:noreply, load_downloads(socket)}`.
//!
//! Authoring flows (manual match, file resolution, batch ops) are
//! deferred per `server_fns/downloads.rs` — this slice ships the
//! operational visibility surface and the cancel mutation.

use dioxus::fullstack::{use_websocket, WebSocketOptions};
use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::components::download_row::DownloadRowView;
use crate::realtime::downloads::downloads_ws;
use crate::server_fns::downloads::{
    cancel_download, list_downloads, CancelDownload, DownloadsQuery,
};

const TAB_OPTIONS: &[(&str, &str)] = &[
    ("queue", "Queue"),
    ("completed", "Completed"),
    ("issues", "Issues"),
];

#[component]
pub fn Downloads() -> Element {
    let tab = use_signal(|| "queue".to_owned());
    let page = use_signal(|| 0_i64);
    let reload_token = use_signal(|| 0_u64);
    let last_error = use_signal::<Option<String>>(|| None);

    let page_resource = use_resource(move || {
        let tab = tab.read().clone();
        let page_val = *page.read();
        let _ = reload_token.read();
        async move {
            list_downloads(DownloadsQuery {
                tab,
                page: page_val,
            })
            .await
        }
    });

    // Real-time fan-in — every frame triggers a reload, mirroring the
    // Phoenix LiveView's behavior. We don't render the event itself.
    let mut ws = use_websocket(|| downloads_ws(WebSocketOptions::new()));
    use_future(move || {
        let mut reload_token = reload_token;
        async move {
            loop {
                match ws.recv().await {
                    Ok(_event) => {
                        reload_token.with_mut(|t| *t += 1);
                    }
                    Err(err) => {
                        tracing::warn!(?err, "downloads WS recv error; stopping fan-in");
                        break;
                    }
                }
            }
        }
    });

    let on_tab = {
        let mut tab = tab;
        let mut page = page;
        move |value: String| {
            tab.set(value);
            page.set(0);
        }
    };

    let on_cancel = {
        let mut last_error = last_error;
        let mut reload_token = reload_token;
        Callback::new(move |id: String| {
            spawn(async move {
                match cancel_download(CancelDownload { id }).await {
                    Ok(()) => reload_token.with_mut(|t| *t += 1),
                    Err(err) => last_error.set(Some(err.to_string())),
                }
            });
        })
    };

    let load_more = {
        let mut page = page;
        move |_| page.with_mut(|p| *p += 1)
    };

    let refresh = {
        let mut reload_token = reload_token;
        let mut page = page;
        move |_| {
            page.set(0);
            reload_token.with_mut(|t| *t += 1);
        }
    };

    rsx! {
        div { class: "max-w-6xl mx-auto",
            AdminPageHeader {
                title: "Downloads".to_string(),
                subtitle: Some(
                    "Active queue, completed history, and issues that need attention.".to_string(),
                ),
                actions: rsx! {
                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        onclick: refresh,
                        "Refresh"
                    }
                },
            }

            div { class: "mb-4",
                FilterBar {
                    current: tab.read().clone(),
                    options: TAB_OPTIONS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_tab,
                }
            }

            if let Some(err) = last_error.read().clone() {
                div { class: "alert alert-error mb-4", "{err}" }
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*page_resource.read_unchecked() {
                        Some(Ok(view)) if view.rows.is_empty() => rsx! {
                            div { id: "downloads-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                "No downloads in this view."
                            }
                        },
                        Some(Ok(view)) => {
                            let has_more = view.has_more;
                            rsx! {
                                div { class: "overflow-x-auto",
                                    table { class: "table",
                                        thead {
                                            tr {
                                                th { "Title" }
                                                th { "Status" }
                                                th { "Progress" }
                                                th { "Source" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "downloads-rows",
                                            for row in view.rows.iter().cloned() {
                                                DownloadRowView {
                                                    key: "{row.id}",
                                                    row: row,
                                                    on_cancel: on_cancel,
                                                }
                                            }
                                        }
                                    }
                                }
                                if has_more {
                                    div { class: "mt-3 text-center",
                                        Button {
                                            variant: ButtonVariant::Ghost,
                                            size: ButtonSize::Sm,
                                            onclick: load_more,
                                            "Load more"
                                        }
                                    }
                                }
                            }
                        }
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error", "Failed to load downloads: {err}" }
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
