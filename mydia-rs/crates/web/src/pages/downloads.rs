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
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::components::download_row::DownloadRowView;
use crate::realtime::downloads::downloads_ws;
use crate::server_fns::downloads::{
    cancel_download, list_downloads, manually_match_download, CancelDownload, DownloadRow,
    DownloadsQuery, ManuallyMatchDownload,
};
use crate::server_fns::search::{search_library, SearchQuery as LibrarySearchQuery};

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
    let match_target: Signal<Option<DownloadRow>> = use_signal(|| None);

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

    let on_match_open = {
        let mut match_target = match_target;
        Callback::new(move |row: DownloadRow| {
            match_target.set(Some(row));
        })
    };

    let on_match_close = {
        let mut match_target = match_target;
        EventHandler::new(move |()| match_target.set(None))
    };

    let on_match_done = {
        let mut match_target = match_target;
        let mut reload_token = reload_token;
        EventHandler::new(move |()| {
            match_target.set(None);
            reload_token.with_mut(|t| *t += 1);
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
                                                    on_match: on_match_open,
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

        ManualMatchModal {
            target: match_target.read().clone(),
            on_close: on_match_close,
            on_done: on_match_done,
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ManualMatchModalProps {
    /// Some(row) opens the modal scoped to that download. None hides
    /// it. The modal re-resets its inner search state each time the
    /// target changes (operator opens it on a fresh row → empty search,
    /// no candidate selected).
    target: Option<DownloadRow>,
    on_close: EventHandler<()>,
    on_done: EventHandler<()>,
}

#[component]
fn ManualMatchModal(props: ManualMatchModalProps) -> Element {
    let mut query = use_signal(String::new);
    let mut selected_id: Signal<Option<String>> = use_signal(|| None);
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);

    let target = props.target.clone();
    let target_id = target.as_ref().map(|r| r.id.clone());
    let target_title = target
        .as_ref()
        .map_or_else(String::new, |r| r.title.clone());

    // Reset the inner search state whenever the modal's target changes.
    let target_id_for_effect = target_id.clone();
    use_effect(use_reactive!(|target_id_for_effect| {
        let _ = target_id_for_effect;
        query.set(String::new());
        selected_id.set(None);
        error.set(None);
        acting.set(false);
    }));

    let q_signal = query;
    let candidates = use_resource(move || {
        let q = q_signal.read().clone();
        async move {
            if q.trim().len() < 2 {
                Ok(Vec::new())
            } else {
                search_library(LibrarySearchQuery { q }).await
            }
        }
    });

    let submit = {
        let target_id = target_id.clone();
        let on_done = props.on_done;
        move |_| {
            let Some(download_id) = target_id.clone() else {
                return;
            };
            let Some(media_item_id) = selected_id.read().clone() else {
                error.set(Some("Pick a media item from the results first".to_owned()));
                return;
            };
            if *acting.read() {
                return;
            }
            acting.set(true);
            error.set(None);
            spawn(async move {
                match manually_match_download(ManuallyMatchDownload {
                    download_id,
                    media_item_id,
                })
                .await
                {
                    Ok(()) => on_done.call(()),
                    Err(err) => error.set(Some(err.to_string())),
                }
                acting.set(false);
            });
        }
    };

    rsx! {
        Modal {
            id: "downloads-manual-match".to_string(),
            open: props.target.is_some(),
            size: ModalSize::Lg,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Match download to media" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| props.on_close.call(()),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    onclick: submit,
                    loading: *acting.read(),
                    disabled: selected_id.read().is_none(),
                    "Match"
                }
            },
            if !target_title.is_empty() {
                p { class: "text-sm text-base-content/70 mb-3",
                    "Pair "
                    span { class: "font-mono", "{target_title}" }
                    " with a media item in your library."
                }
            }
            Input {
                name: "manual-match-query".to_string(),
                placeholder: Some("Search library by title...".to_string()),
                value: "{query}",
                oninput: move |evt: FormEvent| query.set(evt.value()),
            }

            div { id: "downloads-manual-match-results", class: "mt-3 max-h-64 overflow-y-auto",
                match &*candidates.read_unchecked() {
                    Some(Ok(items)) if items.is_empty() && q_signal.read().trim().len() >= 2 => rsx! {
                        div { class: "text-sm text-base-content/60 py-4 text-center",
                            "No matches in the library."
                        }
                    },
                    Some(Ok(items)) if items.is_empty() => rsx! {
                        div { class: "text-sm text-base-content/60 py-4 text-center",
                            "Type at least two characters to search."
                        }
                    },
                    Some(Ok(items)) => {
                        let selected = selected_id.read().clone();
                        rsx! {
                            ul { class: "menu menu-sm bg-base-200 rounded-box w-full",
                                for item in items.iter().cloned() {
                                    {
                                        let id_for_click = item.id.clone();
                                        let is_selected = selected.as_deref() == Some(item.id.as_str());
                                        rsx! {
                                            li { key: "{item.id}",
                                                a {
                                                    class: if is_selected { "active" } else { "" },
                                                    onclick: move |_| {
                                                        selected_id.set(Some(id_for_click.clone()));
                                                    },
                                                    div { class: "flex flex-col",
                                                        span { class: "font-medium", "{item.title}" }
                                                        span { class: "text-xs text-base-content/60",
                                                            "{item.subtitle}"
                                                        }
                                                    }
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error text-sm", "Search failed: {err}" }
                    },
                    None => rsx! {
                        div { class: "py-4 text-center",
                            span { class: "loading loading-spinner loading-sm" }
                        }
                    },
                }
            }

            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}
