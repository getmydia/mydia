//! Admin → Configuration → Release blacklist page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminReleaseBlacklistLive`. CRUD
//! over the blacklist used by the downloads pipeline to skip
//! unwanted releases.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, ConfigSection};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::release_blacklist::{
    create_blacklist_entry, delete_blacklist_entry, list_blacklist_entries, BlacklistEntryRow,
    NewBlacklistEntry, VALID_KINDS,
};

#[component]
pub fn ReleaseBlacklist() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let entries = use_resource(move || {
        let _ = reload_token.read();
        async move { list_blacklist_entries().await }
    });
    let show_create = use_signal(|| false);

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Release blacklist".to_string(),
                subtitle: Some(
                    "Title patterns and content hashes the downloads pipeline refuses to grab."
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
                        "Add entry"
                    }
                },
            }

            ConfigSection {
                id: "admin-release-blacklist".to_string(),
                title: "Blacklisted releases".to_string(),
                match &*entries.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-release-blacklist-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No blacklist entries yet."
                                }
                            }
                        } else {
                            let rows = rows.clone();
                            rsx! {
                                div { class: "overflow-x-auto",
                                    table { class: "table",
                                        thead {
                                            tr {
                                                th { "Kind" }
                                                th { "Pattern" }
                                                th { "Reason" }
                                                th { "Added" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-release-blacklist-rows",
                                            for row in rows.into_iter() {
                                                EntryRowView {
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
                        div { class: "alert alert-error", "Failed to load blacklist: {err}" }
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
struct EntryRowProps {
    row: BlacklistEntryRow,
    on_changed: Callback<()>,
}

#[component]
fn EntryRowView(props: EntryRowProps) -> Element {
    let mut acting = use_signal(|| false);
    let id_for_delete = props.row.id.clone();
    let on_changed = props.on_changed;

    let delete = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        let id = id_for_delete.clone();
        spawn(async move {
            let _ = delete_blacklist_entry(id).await;
            on_changed.call(());
            acting.set(false);
        });
    };

    let added = props
        .row
        .inserted_at
        .clone()
        .unwrap_or_else(|| "—".to_owned());
    let reason = props.row.reason.clone().unwrap_or_else(|| "—".to_owned());

    rsx! {
        tr {
            td { class: "capitalize", "{props.row.kind}" }
            td { class: "font-mono text-xs", "{props.row.pattern}" }
            td { class: "text-sm", "{reason}" }
            td { class: "text-xs", "{added}" }
            td { class: "text-right whitespace-nowrap",
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
    let mut kind = use_signal(|| "title".to_owned());
    let mut pattern = use_signal(String::new);
    let mut reason = use_signal(String::new);
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
        let payload = NewBlacklistEntry {
            kind: kind.read().clone(),
            pattern: pattern.read().clone(),
            reason: {
                let s = reason.read().clone();
                if s.is_empty() {
                    None
                } else {
                    Some(s)
                }
            },
        };
        let on_close = props.on_close;
        let on_created = props.on_created;
        spawn(async move {
            match create_blacklist_entry(payload).await {
                Ok(_) => {
                    pattern.set(String::new());
                    reason.set(String::new());
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
            id: "admin-release-blacklist-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add blacklist entry" },
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
                name: "kind".to_string(),
                r#type: "select".to_string(),
                label: "Kind".to_string(),
                value: "{kind}",
                options: kind_options,
                oninput: move |evt: FormEvent| kind.set(evt.value()),
            }
            Input {
                name: "pattern".to_string(),
                label: "Pattern".to_string(),
                value: "{pattern}",
                placeholder: Some("*CAM* or infohash".to_string()),
                oninput: move |evt: FormEvent| pattern.set(evt.value()),
                required: true,
            }
            Input {
                name: "reason".to_string(),
                label: "Reason (optional)".to_string(),
                value: "{reason}",
                oninput: move |evt: FormEvent| reason.set(evt.value()),
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}
