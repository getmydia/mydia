//! Admin → Configuration → Download clients page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminDownloadClientsLive`. Lists
//! the configured clients, lets the admin add a new one, toggle a
//! row enabled/disabled, delete it, and run a "Test connection"
//! probe.
//!
//! The Phoenix page edits a single row via inline form fields;
//! we promote that to a modal here because Dioxus is more honest
//! about state mutations and the modal scopes the per-row signals
//! cleanly. The trade-off is one extra click — acceptable for a
//! page admins reach a few times an install lifetime.

use dioxus::prelude::*;

use crate::components::admin::{ConfigSection, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::download_clients::{
    create_download_client, delete_download_client, list_download_clients, test_download_client,
    toggle_download_client, DownloadClientRow, NewDownloadClient, VALID_KINDS,
};

#[component]
pub fn DownloadClients() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let clients = use_resource(move || {
        let _ = reload_token.read();
        async move { list_download_clients().await }
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
                    "Add client"
                }
            }

            ConfigSection {
                id: "admin-download-clients".to_string(),
                title: "Configured clients".to_string(),
                match &*clients.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-download-clients-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No download clients yet. Add one to start handing releases off."
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
                                                th { "Kind" }
                                                th { "URL" }
                                                th { "Status" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-download-clients-rows",
                                            for row in rows.into_iter() {
                                                ClientRowView {
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
                        div { class: "alert alert-error", "Failed to load download clients: {err}" }
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
struct ClientRowProps {
    row: DownloadClientRow,
    on_changed: Callback<()>,
}

#[component]
fn ClientRowView(props: ClientRowProps) -> Element {
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
            let _ = toggle_download_client(id).await;
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
            let _ = delete_download_client(id).await;
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
            match test_download_client(id).await {
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
            td { class: "capitalize", "{props.row.kind}" }
            td { class: "font-mono text-xs", "{props.row.url}" }
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
    let mut kind = use_signal(|| "qbittorrent".to_owned());
    let mut url = use_signal(String::new);
    let mut username = use_signal(String::new);
    let mut password = use_signal(String::new);
    let mut enabled = use_signal(|| true);
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);

    let kind_options: Vec<(String, String)> = VALID_KINDS
        .iter()
        .map(|k| ((*k).to_owned(), (*k).to_owned()))
        .collect();

    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let payload = NewDownloadClient {
            name: name.read().clone(),
            kind: kind.read().clone(),
            url: url.read().clone(),
            username: {
                let s = username.read().clone();
                if s.is_empty() {
                    None
                } else {
                    Some(s)
                }
            },
            password: {
                let s = password.read().clone();
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
            match create_download_client(payload).await {
                Ok(_) => {
                    name.set(String::new());
                    url.set(String::new());
                    username.set(String::new());
                    password.set(String::new());
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
            id: "admin-download-clients-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add download client" },
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
                name: "kind".to_string(),
                r#type: "select".to_string(),
                label: "Kind".to_string(),
                value: "{kind}",
                options: kind_options,
                oninput: move |evt: FormEvent| kind.set(evt.value()),
            }
            Input {
                name: "url".to_string(),
                label: "URL".to_string(),
                value: "{url}",
                placeholder: Some("http://qbittorrent:8080".to_string()),
                oninput: move |evt: FormEvent| url.set(evt.value()),
                required: true,
            }
            Input {
                name: "username".to_string(),
                label: "Username (optional)".to_string(),
                value: "{username}",
                oninput: move |evt: FormEvent| username.set(evt.value()),
            }
            Input {
                name: "password".to_string(),
                r#type: "password".to_string(),
                label: "Password (optional)".to_string(),
                value: "{password}",
                oninput: move |evt: FormEvent| password.set(evt.value()),
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
