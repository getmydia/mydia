//! Admin → Configuration → Media servers page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminMediaServersLive`. Lists
//! configured Plex / Jellyfin / Emby instances mydia talks to for
//! cross-server library + watched-state sync. The page itself is
//! intentionally lean — the actual sync workers live in the
//! integrations crate; this surface only edits the connection rows.

use dioxus::prelude::*;

use crate::components::admin::{ConfigSection, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::media_servers::{
    create_media_server, delete_media_server, list_media_servers, toggle_media_server,
    MediaServerRow, NewMediaServer, VALID_KINDS,
};

#[component]
pub fn MediaServers() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let servers = use_resource(move || {
        let _ = reload_token.read();
        async move { list_media_servers().await }
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
                    "Add server"
                }
            }

            ConfigSection {
                id: "admin-media-servers".to_string(),
                title: "Configured servers".to_string(),
                match &*servers.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-media-servers-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No media servers configured."
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
                                                th { "Base URL" }
                                                th { "Status" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-media-servers-rows",
                                            for row in rows.into_iter() {
                                                ServerRowView {
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
                        div { class: "alert alert-error", "Failed to load media servers: {err}" }
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
struct ServerRowProps {
    row: MediaServerRow,
    on_changed: Callback<()>,
}

#[component]
fn ServerRowView(props: ServerRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_toggle = props.row.id.clone();
    let id_for_delete = props.row.id.clone();

    let toggle = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_toggle.clone();
        let on_changed = props.on_changed;
        spawn(async move {
            let _ = toggle_media_server(id).await;
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
            let _ = delete_media_server(id).await;
            on_changed.call(());
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
            td { class: "font-medium", "{props.row.name}" }
            td { class: "capitalize", "{props.row.kind}" }
            td { class: "font-mono text-xs", "{props.row.base_url}" }
            td {
                StatusPill {
                    status: status.to_string(),
                    label: Some(if props.row.enabled { "Enabled".to_string() } else { "Disabled".to_string() }),
                }
            }
            td { class: "text-right whitespace-nowrap",
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
    let mut kind = use_signal(|| "jellyfin".to_owned());
    let mut base_url = use_signal(String::new);
    let mut access_token = use_signal(String::new);
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
        let payload = NewMediaServer {
            name: name.read().clone(),
            kind: kind.read().clone(),
            base_url: base_url.read().clone(),
            access_token: {
                let s = access_token.read().clone();
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
            match create_media_server(payload).await {
                Ok(_) => {
                    name.set(String::new());
                    base_url.set(String::new());
                    access_token.set(String::new());
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
            id: "admin-media-servers-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add media server" },
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
                name: "base_url".to_string(),
                label: "Base URL".to_string(),
                value: "{base_url}",
                placeholder: Some("http://jellyfin:8096".to_string()),
                oninput: move |evt: FormEvent| base_url.set(evt.value()),
                required: true,
            }
            Input {
                name: "access_token".to_string(),
                r#type: "password".to_string(),
                label: "Access token (optional)".to_string(),
                value: "{access_token}",
                oninput: move |evt: FormEvent| access_token.set(evt.value()),
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
