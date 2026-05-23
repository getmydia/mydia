//! Admin → Configuration → Quality profiles page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminQualityProfilesLive` plus
//! `MydiaWeb.AdminQualityProfilesLive.Components`. The Phoenix surface
//! supports a forms-driving-forms shape — a profile is an ordered
//! list of quality cutoffs (resolution strings) where order
//! determines priority.
//!
//! U28 follow-up ships full CRUD against the core fields the Phoenix
//! changeset enforces (name + description + ordered qualities). The
//! deeper `quality_standards` map (codec preferences, bitrate ranges,
//! ...) round-trips on the server but doesn't yet have a UI editor —
//! that's a strict follow-up because the standards map alone is the
//! size of a small admin page on its own.
//!
//! Order of cutoff items is real semantics, not cosmetic: the first
//! item in the list is the highest-priority quality, so reordering
//! changes which release wins when the auto-grabber picks. The page
//! header notes this so operators understand the up/down arrows.

use std::rc::Rc;

use dioxus::prelude::*;

use crate::components::admin::{ConfigSection, ItemRenderer, OrderedItemList};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::quality_profiles::{
    create_quality_profile, delete_quality_profile, get_quality_profile, list_quality_profiles,
    update_quality_profile, NewQualityProfile, QualityProfileRow, UpdateQualityProfile,
    VALID_RESOLUTIONS,
};

#[component]
pub fn QualityProfiles() -> Element {
    let mut reload_token = use_signal(|| 0_u64);
    let profiles = use_resource(move || {
        let _ = reload_token.read();
        async move { list_quality_profiles().await }
    });
    let show_create = use_signal(|| false);

    let on_changed: Callback<()> = Callback::new(move |()| reload_token.with_mut(|t| *t += 1));

    // Page-level header lives in `AdminConfigShell`. The instructional
    // note about ordering stays inline since it's load-bearing context
    // for the ↑ / ↓ reorder buttons below.
    rsx! {
        div { class: "max-w-5xl mx-auto",
            div { class: "flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between mb-4",
                p { class: "text-sm text-base-content/70 max-w-3xl",
                    "Ordered cutoff rules deciding which release qualities mydia accepts. \
                     Order is priority: the first cutoff is the most preferred quality, the \
                     last is the lowest acceptable. Use ↑ and ↓ to reorder."
                }
                div { class: "flex items-center gap-2",
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
                        "New profile"
                    }
                }
            }

            ConfigSection {
                id: "admin-quality-profiles".to_string(),
                title: "Profiles".to_string(),
                match &*profiles.read_unchecked() {
                    Some(Ok(rows)) => {
                        if rows.is_empty() {
                            rsx! {
                                div { id: "admin-quality-profiles-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                    "No quality profiles configured yet. Click New profile to create one."
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
                                                th { "Cutoff items" }
                                                th { "Created" }
                                                th { class: "text-right", "Actions" }
                                            }
                                        }
                                        tbody { id: "admin-quality-profiles-rows",
                                            for row in rows.into_iter() {
                                                ProfileRowView {
                                                    key: "{row.id}",
                                                    row: row,
                                                    on_changed: on_changed,
                                                }
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Failed to load profiles: {err}" }
                    },
                    None => rsx! {
                        div { class: "py-8 text-center",
                            span { class: "loading loading-spinner loading-md" }
                        }
                    },
                }
            }
        }

        ProfileModal {
            mode: ProfileModalMode::New,
            open: *show_create.read(),
            on_close: {
                let mut show_create = show_create;
                EventHandler::new(move |()| show_create.set(false))
            },
            on_saved: on_changed,
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ProfileRowProps {
    row: QualityProfileRow,
    on_changed: Callback<()>,
}

#[component]
fn ProfileRowView(props: ProfileRowProps) -> Element {
    let mut show_edit = use_signal(|| false);
    let mut show_delete = use_signal(|| false);
    let created = props
        .row
        .inserted_at
        .clone()
        .unwrap_or_else(|| "—".to_owned());

    let row_id = props.row.id.clone();
    let row_name = props.row.name.clone();

    rsx! {
        tr { id: "admin-quality-profiles-row-{props.row.id}",
            td { class: "font-medium", "{props.row.name}" }
            td { "{props.row.cutoff_count}" }
            td { class: "text-xs", "{created}" }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Outline,
                    size: ButtonSize::Sm,
                    onclick: move |_| show_edit.set(true),
                    "Edit"
                }
                span { class: "mx-1" }
                Button {
                    variant: ButtonVariant::Error,
                    size: ButtonSize::Sm,
                    onclick: move |_| show_delete.set(true),
                    "Delete"
                }
            }
        }

        ProfileModal {
            mode: ProfileModalMode::Edit { id: row_id.clone() },
            open: *show_edit.read(),
            on_close: EventHandler::new(move |()| show_edit.set(false)),
            on_saved: props.on_changed,
        }

        DeleteProfileModal {
            id: row_id,
            name: row_name,
            open: *show_delete.read(),
            on_close: EventHandler::new(move |()| show_delete.set(false)),
            on_changed: props.on_changed,
        }
    }
}

// ---------- Profile create / edit modal ----------

#[derive(Clone, PartialEq)]
enum ProfileModalMode {
    New,
    Edit { id: String },
}

#[derive(Props, Clone, PartialEq)]
struct ProfileModalProps {
    mode: ProfileModalMode,
    open: bool,
    on_close: EventHandler<()>,
    on_saved: Callback<()>,
}

#[component]
fn ProfileModal(props: ProfileModalProps) -> Element {
    let mut name = use_signal(String::new);
    let mut description = use_signal(String::new);
    let qualities: Signal<Vec<String>> = use_signal(Vec::new);
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut loaded_for: Signal<Option<String>> = use_signal(|| None);

    // When the modal opens in edit mode, fetch the existing detail
    // once per (id, open) transition and seed the form signals. The
    // `loaded_for` guard prevents re-fetching on every re-render.
    let open = props.open;
    let mode = props.mode.clone();
    use_effect(move || {
        if !open {
            // Reset whenever the modal closes so the next open starts
            // fresh.
            loaded_for.set(None);
            return;
        }
        match &mode {
            ProfileModalMode::New => {
                if loaded_for.read().as_deref() != Some("new") {
                    name.set(String::new());
                    description.set(String::new());
                    let mut qs = qualities;
                    qs.set(Vec::new());
                    error.set(None);
                    loaded_for.set(Some("new".to_owned()));
                }
            }
            ProfileModalMode::Edit { id } => {
                if loaded_for.read().as_deref() != Some(id.as_str()) {
                    let load_id = id.clone();
                    loaded_for.set(Some(id.clone()));
                    let mut qs = qualities;
                    spawn(async move {
                        match get_quality_profile(load_id).await {
                            Ok(detail) => {
                                name.set(detail.name);
                                description.set(detail.description.unwrap_or_default());
                                qs.set(detail.qualities);
                                error.set(None);
                            }
                            Err(err) => error.set(Some(err.to_string())),
                        }
                    });
                }
            }
        }
    });

    let modal_id = match &props.mode {
        ProfileModalMode::New => "admin-quality-profiles-create".to_owned(),
        ProfileModalMode::Edit { id } => format!("admin-quality-profiles-edit-{id}"),
    };
    let title = match &props.mode {
        ProfileModalMode::New => "New quality profile",
        ProfileModalMode::Edit { .. } => "Edit quality profile",
    };

    let mode_for_submit = props.mode.clone();
    let on_close_for_submit = props.on_close;
    let on_saved = props.on_saved;
    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let name_value = name.read().clone();
        let desc_value = description.read().clone();
        let qualities_value = qualities.read().clone();
        let mode = mode_for_submit.clone();
        spawn(async move {
            let desc_opt = if desc_value.trim().is_empty() {
                None
            } else {
                Some(desc_value)
            };
            let result = match mode {
                ProfileModalMode::New => create_quality_profile(NewQualityProfile {
                    name: name_value,
                    description: desc_opt,
                    qualities: qualities_value,
                })
                .await
                .map(|_| ()),
                ProfileModalMode::Edit { id } => update_quality_profile(UpdateQualityProfile {
                    id,
                    name: name_value,
                    description: desc_opt,
                    qualities: qualities_value,
                })
                .await
                .map(|_| ()),
            };
            match result {
                Ok(()) => {
                    on_saved.call(());
                    on_close_for_submit.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let id_prefix = format!("{modal_id}-qualities");
    let render_quality_row: ItemRenderer<String> = Rc::new(move |index, item| {
        let id = format!("admin-quality-profiles-quality-{index}");
        let options: Vec<(String, String)> = VALID_RESOLUTIONS
            .iter()
            .map(|r| ((*r).to_owned(), (*r).to_owned()))
            .collect();
        let current = item.clone();
        let mut qs = qualities;
        rsx! {
            Input {
                key: "{index}",
                name: id.clone(),
                id: id,
                r#type: "select".to_string(),
                value: "{current}",
                options: options,
                onchange: move |evt: FormEvent| {
                    let new_value = evt.value();
                    qs.with_mut(|v| {
                        if let Some(slot) = v.get_mut(index) {
                            *slot = new_value;
                        }
                    });
                },
            }
        }
    });

    let mut qs_for_add = qualities;
    let on_add_quality = EventHandler::new(move |()| {
        // Default to the first resolution that's not already in the
        // list, falling back to "1080p" so the new row is at least
        // semantically sensible.
        let next = qs_for_add.with(|current| {
            VALID_RESOLUTIONS
                .iter()
                .find(|r| !current.iter().any(|c| c == *r))
                .copied()
                .unwrap_or("1080p")
                .to_owned()
        });
        qs_for_add.with_mut(|v| v.push(next));
    });

    let on_close_for_close_btn = props.on_close;
    let on_close_for_modal = props.on_close;

    rsx! {
        Modal {
            id: modal_id.clone(),
            open: props.open,
            size: ModalSize::Lg,
            on_close: move |()| on_close_for_modal.call(()),
            title: rsx! { "{title}" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close_for_close_btn.call(()),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Primary,
                    onclick: submit,
                    loading: *acting.read(),
                    "Save profile"
                }
            },
            div { class: "flex flex-col gap-4",
                Input {
                    name: "name".to_string(),
                    id: format!("{modal_id}-name"),
                    label: "Name".to_string(),
                    value: "{name}",
                    oninput: move |evt: FormEvent| name.set(evt.value()),
                    required: true,
                }
                Input {
                    name: "description".to_string(),
                    id: format!("{modal_id}-description"),
                    r#type: "textarea".to_string(),
                    label: "Description (optional)".to_string(),
                    rows: 2,
                    value: "{description}",
                    oninput: move |evt: FormEvent| description.set(evt.value()),
                }
                div {
                    label { class: "label mb-1 text-sm font-medium text-base-content/80",
                        "Cutoff items"
                    }
                    OrderedItemList::<String> {
                        id_prefix: id_prefix,
                        items: qualities,
                        render_item: render_quality_row,
                        on_add: on_add_quality,
                        add_label: "Add cutoff".to_string(),
                        help: Some(
                            "First item is preferred; last is the lowest acceptable. \
                             Each resolution may only appear once."
                                .to_string(),
                        ),
                        empty_state: Some(rsx! {
                            "No cutoff items yet. Add one to start accepting releases."
                        }),
                    }
                }
                if let Some(err) = error.read().clone() {
                    div { id: "{modal_id}-error", class: "alert alert-error text-sm", "{err}" }
                }
            }
        }
    }
}

// ---------- Delete confirm modal ----------

#[derive(Props, Clone, PartialEq)]
struct DeleteProfileModalProps {
    id: String,
    name: String,
    open: bool,
    on_close: EventHandler<()>,
    on_changed: Callback<()>,
}

#[component]
fn DeleteProfileModal(props: DeleteProfileModalProps) -> Element {
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let id_for_submit = props.id.clone();

    let on_close_for_submit = props.on_close;
    let on_changed = props.on_changed;
    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let id = id_for_submit.clone();
        spawn(async move {
            match delete_quality_profile(id).await {
                Ok(()) => {
                    on_changed.call(());
                    on_close_for_submit.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let on_close_for_close_btn = props.on_close;
    let on_close_for_modal = props.on_close;

    rsx! {
        Modal {
            id: format!("admin-quality-profiles-delete-{}", props.id),
            open: props.open,
            size: ModalSize::Sm,
            on_close: move |()| on_close_for_modal.call(()),
            title: rsx! { "Delete quality profile" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| on_close_for_close_btn.call(()),
                    "Cancel"
                }
                Button {
                    variant: ButtonVariant::Error,
                    onclick: submit,
                    loading: *acting.read(),
                    "Delete"
                }
            },
            p { class: "text-sm",
                "Permanently delete the profile "
                strong { "{props.name}" }
                "? Media items currently using this profile will lose their assignment."
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}
