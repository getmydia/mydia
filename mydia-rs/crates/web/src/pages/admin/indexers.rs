//! Admin → Configuration → Indexers page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminIndexersLive`. Lists every
//! configured cardigann-backed indexer with toggle and delete
//! affordances; "Add indexer" opens a modal for the four required
//! fields (name, definition slug, base URL, optional API key).
//!
//! Cardigann YAML-side definitions stay in the
//! `mydia-rs-indexers` crate. This page only manages the operator-
//! configurable per-instance row.

use dioxus::prelude::*;

use crate::components::admin::{ConfigSection, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::indexers::{
    create_indexer, delete_indexer, list_indexers, test_indexer, toggle_indexer, IndexerRow,
    NewIndexer,
};

#[component]
pub fn Indexers() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let indexers = use_resource(move || {
        let _ = reload_token.read();
        async move { list_indexers().await }
    });
    let show_create = use_signal(|| false);

    // Page-level header lives in `AdminConfigShell`. Per-tab chrome is
    // the right-aligned action bar.
    rsx! {
        div { class: "max-w-5xl mx-auto",
            div { class: "flex justify-end gap-2 mb-4",
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    onclick: move |_| reload_token.with_mut(|t| *t += 1),
                    "Refresh"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Sm,
                    onclick: {
                        let mut show_create = show_create;
                        move |_| show_create.set(true)
                    },
                    "Add indexer"
                }
            }

            ConfigSection {
                id: "admin-indexers".to_string(),
                title: "Configured indexers".to_string(),
                match &*indexers.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-indexers-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No indexers yet. Add a cardigann-backed source to start searching."
                                }
                            }
                        } else {
                            let rows = rows.clone();
                            rsx! {
                                div { class: "overflow-x-auto",
                                    table { class: "table",
                                        thead {
                                            tr {
                                                th { "Name" }
                                                th { "Definition" }
                                                th { "Base URL" }
                                                th { "Status" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-indexers-rows",
                                            for row in rows.into_iter() {
                                                IndexerRowView {
                                                    key: "{row.id}",
                                                    row: row,
                                                    on_changed: move || reload_token.with_mut(|t| *t += 1),
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Failed to load indexers: {err}" }
                    },
                    None => rsx! {
                        div { class: "py-8 text-center",
                            span { class: "loading loading-spinner loading-md" }
                        }
                    },
                }
            }
        }

        CreateModal {
            open: *show_create.read(),
            on_close: {
                let mut show_create = show_create;
                EventHandler::new(move |()| show_create.set(false))
            },
            on_created: move |()| reload_token.with_mut(|t| *t += 1),
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct IndexerRowProps {
    row: IndexerRow,
    on_changed: Callback<()>,
}

#[component]
fn IndexerRowView(props: IndexerRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let mut test_message: Signal<Option<(bool, String)>> = use_signal(|| None);
    let id_for_toggle = props.row.id.clone();
    let id_for_delete = props.row.id.clone();
    let id_for_test = props.row.id.clone();

    let toggle = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_toggle.clone();
        let on_changed = props.on_changed;
        spawn(async move {
            let _ = toggle_indexer(id).await;
            on_changed.call(());
            acting.set(false);
        });
    };

    let delete = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_delete.clone();
        let on_changed = props.on_changed;
        spawn(async move {
            let _ = delete_indexer(id).await;
            on_changed.call(());
            acting.set(false);
        });
    };

    let test = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        test_message.set(None);
        let id = id_for_test.clone();
        spawn(async move {
            match test_indexer(id).await {
                Ok(ack) => test_message.set(Some((ack.ok, ack.message))),
                Err(err) => test_message.set(Some((false, err.to_string()))),
            }
            acting.set(false);
        });
    };

    let status = if props.row.enabled {
        "active"
    } else {
        "inactive"
    };
    rsx! {
        tr {
            td {
                div { class: "font-medium", "{props.row.name}" }
                if let Some((ok, msg)) = test_message.read().clone() {
                    div { class: if ok { "text-xs text-success mt-1" } else { "text-xs text-error mt-1" },
                        "{msg}"
                    }
                }
            }
            td { class: "font-mono text-xs", "{props.row.definition}" }
            td { class: "font-mono text-xs", "{props.row.base_url}" }
            td {
                StatusPill {
                    status: status.to_string(),
                    label: Some(if props.row.enabled { "Enabled".to_string() } else { "Disabled".to_string() }),
                }
            }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Outline,
                    size: ButtonSize::Sm,
                    onclick: test,
                    "Test"
                }
                span { class: "mx-1" }
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    onclick: toggle,
                    if props.row.enabled { "Disable" } else { "Enable" }
                }
                span { class: "mx-1" }
                Button {
                    variant: ButtonVariant::Error,
                    size: ButtonSize::Sm,
                    onclick: delete,
                    "Delete"
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct CreateModalProps {
    open: bool,
    on_close: EventHandler<()>,
    on_created: EventHandler<()>,
}

#[component]
fn CreateModal(props: CreateModalProps) -> Element {
    let mut name = use_signal(String::new);
    let mut definition = use_signal(String::new);
    let mut base_url = use_signal(String::new);
    let mut api_key = use_signal(String::new);
    let mut enabled = use_signal(|| true);
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);

    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let payload = NewIndexer {
            name: name.read().clone(),
            definition: definition.read().clone(),
            base_url: base_url.read().clone(),
            api_key: {
                let s = api_key.read().clone();
                if s.is_empty() {
                    None
                } else {
                    Some(s)
                }
            },
            enabled: *enabled.read(),
        };
        let on_close = props.on_close;
        let on_created = props.on_created;
        spawn(async move {
            match create_indexer(payload).await {
                Ok(_) => {
                    name.set(String::new());
                    definition.set(String::new());
                    base_url.set(String::new());
                    api_key.set(String::new());
                    on_created.call(());
                    on_close.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    rsx! {
        Modal {
            id: "admin-indexers-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add indexer" },
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
                    "Create"
                }
            },
            Input {
                name: "name".to_string(),
                label: "Name".to_string(),
                value: "{name}",
                oninput: move |evt: FormEvent| name.set(evt.value()),
                required: true,
            }
            Input {
                name: "definition".to_string(),
                label: "Cardigann definition".to_string(),
                value: "{definition}",
                placeholder: Some("e.g. iptorrents".to_string()),
                oninput: move |evt: FormEvent| definition.set(evt.value()),
                required: true,
            }
            Input {
                name: "base_url".to_string(),
                label: "Base URL".to_string(),
                value: "{base_url}",
                placeholder: Some("https://iptorrents.com".to_string()),
                oninput: move |evt: FormEvent| base_url.set(evt.value()),
                required: true,
            }
            Input {
                name: "api_key".to_string(),
                r#type: "password".to_string(),
                label: "API key (optional)".to_string(),
                value: "{api_key}",
                oninput: move |evt: FormEvent| api_key.set(evt.value()),
            }
            Input {
                name: "enabled".to_string(),
                r#type: "checkbox".to_string(),
                label: "Enable immediately".to_string(),
                checked: *enabled.read(),
                onchange: move |evt: FormEvent| {
                    let on = matches!(
                        evt.value().to_ascii_lowercase().as_str(),
                        "true" | "1" | "yes" | "on"
                    );
                    enabled.set(on);
                },
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}
