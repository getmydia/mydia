//! Admin → Configuration → Import lists page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminImportListsLive`. Configures
//! periodic-pull import sources (Trakt collections, `IMDb` lists,
//! TMDB lists). The actual pull workers live in the integrations
//! crate; this page only manages the row.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, ConfigSection, StatusPill};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::import_lists::{
    create_import_list, delete_import_list, list_import_lists, toggle_import_list, ImportListRow,
    NewImportList, VALID_KINDS,
};

#[component]
pub fn ImportLists() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let lists = use_resource(move || {
        let _ = reload_token.read();
        async move { list_import_lists().await }
    });
    let show_create = use_signal(|| false);

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Import lists".to_string(),
                subtitle: Some(
                    "Trakt / IMDb / TMDB sources mydia pulls into the catalog on a schedule."
                        .to_string(),
                ),
                actions: rsx! {
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
                        "Add list"
                    }
                },
            }

            ConfigSection {
                id: "admin-import-lists".to_string(),
                title: "Configured lists".to_string(),
                match &*lists.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-import-lists-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No import lists yet."
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
                                                th { "Source" }
                                                th { "Last synced" }
                                                th { "Status" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-import-lists-rows",
                                            for row in rows.into_iter() {
                                                ListRowView {
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
                        div { class: "alert alert-error", "Failed to load import lists: {err}" }
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
struct ListRowProps {
    row: ImportListRow,
    on_changed: Callback<()>,
}

#[component]
fn ListRowView(props: ListRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_toggle = props.row.id.clone();
    let id_for_delete = props.row.id.clone();
    let on_changed = props.on_changed;

    let toggle = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_toggle.clone();
        spawn(async move {
            let _ = toggle_import_list(id).await;
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
        spawn(async move {
            let _ = delete_import_list(id).await;
            on_changed.call(());
            acting.set(false);
        });
    };

    let last_synced = props
        .row
        .last_synced_at
        .clone()
        .unwrap_or_else(|| "Never".to_owned());
    let status = if props.row.enabled {
        "active"
    } else {
        "inactive"
    };

    rsx! {
        tr {
            td { class: "font-medium", "{props.row.name}" }
            td { class: "capitalize", "{props.row.kind}" }
            td { class: "font-mono text-xs", "{props.row.url_or_id}" }
            td { class: "text-xs", "{last_synced}" }
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
    let mut kind = use_signal(|| "trakt".to_owned());
    let mut url_or_id = use_signal(String::new);
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
        let payload = NewImportList {
            name: name.read().clone(),
            kind: kind.read().clone(),
            url_or_id: url_or_id.read().clone(),
            enabled: *enabled.read(),
        };
        let on_close = props.on_close;
        let on_created = props.on_created;
        spawn(async move {
            match create_import_list(payload).await {
                Ok(_) => {
                    name.set(String::new());
                    url_or_id.set(String::new());
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
            id: "admin-import-lists-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add import list" },
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
                name: "url_or_id".to_string(),
                label: "URL or list id".to_string(),
                value: "{url_or_id}",
                placeholder: Some("user/trakt-list-slug".to_string()),
                oninput: move |evt: FormEvent| url_or_id.set(evt.value()),
                required: true,
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
