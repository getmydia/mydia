//! Admin → Library Paths page (U23 pilot).
//!
//! Phoenix counterpart: `MydiaWeb.AdminLibraryPathsLive.Index`. The
//! original mounts a `Phoenix.PubSub.subscribe("library_scanner")` in
//! its `mount/3`, then drives a series of `handle_info/2` clauses to
//! track scan progress across multiple library paths simultaneously.
//!
//! Dioxus 0.7 has no LiveView-equivalent diff protocol, so this port
//! uses three primitives:
//!   1. A `use_resource` over [`list_library_paths`] for the initial
//!      list (re-fetched after every mutation).
//!   2. A `use_websocket` connection to [`library_scanner_ws`] that
//!      streams [`LibraryScanEvent`]s into a `Signal<HashMap<_, _>>`
//!      keyed by `library_path_id`.
//!   3. Per-row [`ScanProgress`] readout driven by that signal.
//!
//! Server functions handle every mutation (`create`, `delete`,
//! `trigger_scan`). Validation errors arrive as `ServerFnError` and
//! the page surfaces them inline against the form, matching the
//! Phoenix `put_flash + assign(:library_path_form, ...)` pattern.

use std::collections::HashMap;

use dioxus::fullstack::{use_websocket, WebSocketOptions};
use dioxus::prelude::*;

use crate::components::core::{Button, ButtonSize, ButtonVariant, Input};
use crate::components::scan_progress::ScanProgress;
use crate::realtime::library_scanner::{library_scanner_ws, LibraryScanEvent};
use crate::server_fns::library_paths::{
    create_library_path, delete_library_path, list_library_paths, trigger_scan, LibraryPathRow,
    NewLibraryPath,
};

/// Library kinds we let an operator pick from. Mirrors the Phoenix
/// enum and the server-side `VALID_KINDS` allowlist; rendered once
/// inline because the list is tiny and a `<select>` doesn't justify
/// its own component.
const LIBRARY_KINDS: &[(&str, &str)] = &[
    ("movies", "Movies"),
    ("series", "TV shows"),
    ("music", "Music"),
    ("books", "Books"),
    ("adult", "Adult"),
    ("music_videos", "Music videos"),
];

#[component]
pub fn LibraryPaths() -> Element {
    // Server-side list. `use_resource` reruns when its read
    // dependencies invalidate; we bump `reload_token` after each
    // mutation to force a fresh fetch.
    let mut reload_token = use_signal(|| 0u64);
    let library_paths = use_resource(move || {
        let _ = reload_token.read();
        async move { list_library_paths().await }
    });

    // Form state. A submit handler turns this into a NewLibraryPath
    // and calls `create_library_path`. Inline validation errors
    // populate `form_error` and stay visible until the next submit.
    let mut form_path = use_signal(String::new);
    let mut form_kind = use_signal(|| LIBRARY_KINDS[0].0.to_owned());
    let mut form_monitored = use_signal(|| true);
    let mut form_error: Signal<Option<String>> = use_signal(|| None);
    let mut flash: Signal<Option<(FlashKind, String)>> = use_signal(|| None);

    // Per-row latest event, keyed by library_path_id. The WS task
    // mutates this signal on every received frame; the per-row
    // ScanProgress component re-renders accordingly.
    let scan_events: Signal<HashMap<String, LibraryScanEvent>> = use_signal(HashMap::new);

    // Open the realtime channel. `use_websocket` returns a
    // `UseWebsocket` handle whose `.recv()` futures plug into a
    // `use_future` loop below. `.recv()` internally waits for the
    // connection to be established and yields each incoming message,
    // so the loop is naturally throttled by the wire (no manual
    // backoff needed for the normal case).
    let mut ws = use_websocket(|| library_scanner_ws(WebSocketOptions::new()));

    use_future(move || {
        let mut scan_events = scan_events;
        async move {
            loop {
                match ws.recv().await {
                    Ok(event) => {
                        if let Some(id) = event.library_path_id().map(str::to_owned) {
                            scan_events.write().insert(id, event);
                        } else {
                            tracing::debug!(?event, "scan event without library_path_id");
                        }
                    }
                    Err(err) => {
                        // `UseWebsocket` triggers an automatic
                        // reconnect on the next `.recv()` when its
                        // `with_automatic_reconnect` option is set
                        // (which is the default we'd add when this
                        // page promotes from pilot). For now, a
                        // recv error terminates the loop — the
                        // operator reloads if they need to resume.
                        tracing::warn!(?err, "library scanner WS recv error; stopping fan-in");
                        break;
                    }
                }
            }
        }
    });

    let submit_path = move |evt: FormEvent| {
        evt.prevent_default();
        let new_path = NewLibraryPath {
            path: form_path.read().clone(),
            kind: form_kind.read().clone(),
            monitored: *form_monitored.read(),
        };
        spawn(async move {
            match create_library_path(new_path).await {
                Ok(row) => {
                    form_error.set(None);
                    form_path.set(String::new());
                    flash.set(Some((
                        FlashKind::Success,
                        format!("Added library path {}", row.path),
                    )));
                    reload_token.with_mut(|t| *t += 1);
                }
                Err(err) => {
                    form_error.set(Some(err.to_string()));
                }
            }
        });
    };

    // Page-level header lives in `AdminConfigShell`. No per-tab action
    // bar here — the "Add a path" form sits directly below.
    rsx! {
        div { class: "max-w-4xl mx-auto space-y-6",
            // Flash region — currently only success state from create.
            if let Some((kind, msg)) = flash.read().clone() {
                FlashBanner { kind: kind, message: msg }
            }

            // Add form
            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    h2 { class: "card-title text-lg", "Add a path" }
                    form {
                        id: "library-path-form",
                        onsubmit: submit_path,
                        class: "grid grid-cols-1 md:grid-cols-[1fr_180px_120px_auto] gap-3 items-end",
                        Input {
                            name: "path".to_string(),
                            label: "Filesystem path".to_string(),
                            placeholder: "/media/movies".to_string(),
                            value: "{form_path}",
                            oninput: move |e: FormEvent| form_path.set(e.value()),
                            required: true,
                        }
                        label { class: "form-control w-full",
                            div { class: "label",
                                span { class: "label-text", "Library type" }
                            }
                            select {
                                class: "select select-bordered w-full",
                                name: "type",
                                value: "{form_kind}",
                                oninput: move |evt| form_kind.set(evt.value()),
                                for (kind, label) in LIBRARY_KINDS.iter() {
                                    option { value: "{kind}", "{label}" }
                                }
                            }
                        }
                        label { class: "form-control w-full",
                            div { class: "label",
                                span { class: "label-text", "Monitor" }
                            }
                            label { class: "cursor-pointer label justify-start gap-2",
                                input {
                                    r#type: "checkbox",
                                    class: "toggle toggle-primary",
                                    checked: "{form_monitored}",
                                    onchange: move |evt| form_monitored.set(evt.value() == "true"),
                                }
                                span { class: "label-text", "Watch" }
                            }
                        }
                        Button {
                            variant: ButtonVariant::Primary,
                            r#type: "submit".to_string(),
                            class: "self-end".to_string(),
                            "Add"
                        }
                    }
                    if let Some(err) = form_error.read().clone() {
                        div { class: "mt-2 text-sm text-error", "{err}" }
                    }
                }
            }

            // Library paths table
            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    h2 { class: "card-title text-lg", "Configured paths" }
                    match &*library_paths.read_unchecked() {
                        Some(Ok(rows)) if rows.is_empty() => rsx! {
                            div { class: "text-sm text-base-content/60 py-8 text-center",
                                "No library paths configured yet. Add one above to start scanning."
                            }
                        },
                        Some(Ok(rows)) => rsx! {
                            div { class: "overflow-x-auto",
                                table { class: "table",
                                    thead {
                                        tr {
                                            th { "Path" }
                                            th { "Type" }
                                            th { "Last scan" }
                                            th { class: "w-1/3", "Progress" }
                                            th { class: "text-right", "Actions" }
                                        }
                                    }
                                    tbody {
                                        for row in rows.iter().cloned() {
                                            LibraryPathRowView {
                                                key: "{row.id}",
                                                row: row.clone(),
                                                event: scan_events.read().get(&row.id).cloned(),
                                                on_changed: move || reload_token.with_mut(|t| *t += 1),
                                            }
                                        }
                                    }
                                }
                            }
                        },
                        Some(Err(err)) => rsx! {
                            div { class: "alert alert-error",
                                "Failed to load library paths: {err}"
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

// ---------- per-row subcomponent ----------

#[derive(Props, Clone, PartialEq)]
struct LibraryPathRowProps {
    row: LibraryPathRow,
    event: Option<LibraryScanEvent>,
    on_changed: Callback<()>,
}

#[component]
fn LibraryPathRowView(props: LibraryPathRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let row = props.row.clone();
    let row_id_delete = row.id.clone();
    let row_id_scan = row.id.clone();
    let on_changed_delete = props.on_changed;
    let on_changed_scan = props.on_changed;

    let on_delete = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = row_id_delete.clone();
        spawn(async move {
            if let Err(err) = delete_library_path(id).await {
                tracing::warn!(%err, "delete_library_path failed");
            }
            on_changed_delete.call(());
            acting.set(false);
        });
    };

    let on_scan = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = row_id_scan.clone();
        spawn(async move {
            if let Err(err) = trigger_scan(id).await {
                tracing::warn!(%err, "trigger_scan failed");
            }
            on_changed_scan.call(());
            acting.set(false);
        });
    };

    let kind_label = LIBRARY_KINDS
        .iter()
        .find(|(k, _)| *k == row.kind)
        .map_or_else(|| row.kind.as_str(), |(_, l)| *l);

    rsx! {
        tr {
            td { class: "font-mono text-sm", "{row.path}" }
            td {
                span { class: "badge badge-ghost", "{kind_label}" }
            }
            td { class: "text-sm",
                {render_last_scan(&row)}
            }
            td {
                ScanProgress { event: props.event.clone() }
            }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Sm,
                    disabled: *acting.read(),
                    onclick: on_scan,
                    "Scan"
                }
                span { class: "mx-1" }
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    disabled: *acting.read(),
                    onclick: on_delete,
                    "Delete"
                }
            }
        }
    }
}

fn render_last_scan(row: &LibraryPathRow) -> Element {
    let status = row.last_scan_status.as_deref();
    let badge_class = match status {
        Some("completed") => "badge badge-success",
        Some("failed") => "badge badge-error",
        Some("in_progress") => "badge badge-info",
        Some("pending") => "badge badge-warning",
        _ => "badge badge-ghost",
    };
    let badge_text = status.unwrap_or("never");
    rsx! {
        div { class: "flex flex-col gap-1",
            span { class: "{badge_class} w-fit", "{badge_text}" }
            if let Some(at) = row.last_scan_at.as_ref() {
                span { class: "text-xs text-base-content/60", "{at}" }
            }
            if let Some(err) = row.last_scan_error.as_ref() {
                span { class: "text-xs text-error", "{err}" }
            }
        }
    }
}

// ---------- Flash banner (page-local) ----------

#[derive(Clone, PartialEq, Eq, Copy, Debug)]
enum FlashKind {
    Success,
}

#[derive(Props, Clone, PartialEq)]
struct FlashBannerProps {
    kind: FlashKind,
    message: String,
}

#[component]
fn FlashBanner(props: FlashBannerProps) -> Element {
    let class = match props.kind {
        FlashKind::Success => "alert alert-success",
    };
    rsx! {
        div { class: "{class}",
            span { "{props.message}" }
        }
    }
}
