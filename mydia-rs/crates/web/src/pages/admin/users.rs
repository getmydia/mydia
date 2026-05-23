//! Admin → Users page.
//!
//! Phoenix counterpart: `MydiaWeb.AdminUsersLive.Index`. Lists every
//! user, lets the admin create one with a password they pick, change
//! a user's role, and delete users (except themselves).
//!
//! Phoenix's "generate random password / show once" mode plus the
//! `validate_*` change events aren't ported in U28 — both would be
//! follow-ups to the password-reset modal. The create form here uses
//! the operator-provided password directly; that's enough to admit a
//! new user, and the operator can rotate via SSH / CLI for now.

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonSize, ButtonVariant, Input, Modal, ModalSize};
use crate::server_fns::admin::users::{
    create_user, delete_user, list_users, update_user_role, NewUser, RoleUpdate, UserRow,
    VALID_ROLES,
};

const ROLE_FILTERS: &[(&str, &str)] = &[
    ("all", "All"),
    ("admin", "Admins"),
    ("user", "Users"),
    ("readonly", "Read-only"),
    ("guest", "Guests"),
];

#[component]
pub fn Users() -> Element {
    let filter_role = use_signal(|| "all".to_owned());
    let mut reload_token = use_signal(|| 0_u64);
    let users = use_resource(move || {
        let _ = reload_token.read();
        async move { list_users().await }
    });
    let show_create = use_signal(|| false);

    let on_select_filter = {
        let mut filter_role = filter_role;
        move |value: String| filter_role.set(value)
    };

    rsx! {
        div { class: "max-w-5xl mx-auto",
            AdminPageHeader {
                title: "Users".to_string(),
                subtitle: Some(
                    "Local accounts and OIDC-linked identities on this instance.".to_string(),
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
                        "Add user"
                    }
                },
            }

            div { class: "mb-4",
                FilterBar {
                    current: filter_role.read().clone(),
                    options: ROLE_FILTERS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_select_filter,
                }
            }

            section { class: "card bg-base-100 shadow",
                div { class: "card-body",
                    match &*users.read_unchecked() {
                        Some(Ok(rows)) => {
                            let filter = filter_role.read().clone();
                            let filtered: Vec<UserRow> = rows
                                .iter()
                                .filter(|r| filter == "all" || r.role == filter)
                                .cloned()
                                .collect();
                            if filtered.is_empty() {
                                rsx! {
                                    div { id: "admin-users-empty", class: "text-sm text-base-content/60 py-12 text-center",
                                        "No users match the current filter."
                                    }
                                }
                            } else {
                                rsx! {
                                    div { class: "overflow-x-auto",
                                        table { class: "table",
                                            thead {
                                                tr {
                                                    th { "User" }
                                                    th { "Role" }
                                                    th { "Last login" }
                                                    th { class: "text-right", "Actions" }
                                                }
                                            }
                                            tbody { id: "admin-users-rows",
                                                for row in filtered.into_iter() {
                                                    UserRowView {
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
                            div { class: "alert alert-error", "Failed to load users: {err}" }
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

        CreateUserModal {
            open: *show_create.read(),
            on_close: {
                let mut show_create = show_create;
                EventHandler::new(move |()| show_create.set(false))
            },
            on_created: move |()| {
                reload_token.with_mut(|t| *t += 1);
            },
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct UserRowProps {
    row: UserRow,
    on_changed: Callback<()>,
}

#[component]
fn UserRowView(props: UserRowProps) -> Element {
    let mut show_role_modal = use_signal(|| false);
    let mut show_delete_modal = use_signal(|| false);

    let display_name = props
        .row
        .username
        .clone()
        .or_else(|| props.row.email.clone())
        .unwrap_or_else(|| props.row.id.clone());
    let last_login = props
        .row
        .last_login_at
        .clone()
        .unwrap_or_else(|| "Never".to_owned());

    rsx! {
        tr {
            td {
                div { class: "font-medium", "{display_name}" }
                if let Some(email) = props.row.email.as_ref() {
                    div { class: "text-xs text-base-content/60", "{email}" }
                }
                if props.row.is_oidc {
                    span { class: "badge badge-ghost badge-xs mt-1", "OIDC" }
                }
            }
            td { class: "capitalize", "{props.row.role}" }
            td { class: "text-sm", "{last_login}" }
            td { class: "text-right whitespace-nowrap",
                Button {
                    variant: ButtonVariant::Outline,
                    size: ButtonSize::Sm,
                    onclick: move |_| show_role_modal.set(true),
                    "Change role"
                }
                span { class: "mx-1" }
                Button {
                    variant: ButtonVariant::Error,
                    size: ButtonSize::Sm,
                    onclick: move |_| show_delete_modal.set(true),
                    "Delete"
                }
            }
        }

        RoleModal {
            id: props.row.id.clone(),
            current_role: props.row.role.clone(),
            display_name: display_name.clone(),
            open: *show_role_modal.read(),
            on_close: EventHandler::new(move |()| show_role_modal.set(false)),
            on_changed: props.on_changed,
        }

        DeleteUserModal {
            id: props.row.id.clone(),
            display_name: display_name,
            open: *show_delete_modal.read(),
            on_close: EventHandler::new(move |()| show_delete_modal.set(false)),
            on_changed: props.on_changed,
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct CreateUserModalProps {
    open: bool,
    on_close: EventHandler<()>,
    on_created: EventHandler<()>,
}

#[component]
fn CreateUserModal(props: CreateUserModalProps) -> Element {
    let mut username = use_signal(String::new);
    let mut email = use_signal(String::new);
    let mut password = use_signal(String::new);
    let mut role = use_signal(|| "guest".to_owned());
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);

    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let payload = NewUser {
            username: username.read().clone(),
            email: email.read().clone(),
            password: password.read().clone(),
            role: role.read().clone(),
        };
        let on_created = props.on_created;
        let on_close = props.on_close;
        spawn(async move {
            match create_user(payload).await {
                Ok(_) => {
                    username.set(String::new());
                    email.set(String::new());
                    password.set(String::new());
                    on_created.call(());
                    on_close.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let role_options: Vec<(String, String)> = VALID_ROLES
        .iter()
        .map(|r| {
            let mut label = (*r).to_owned();
            if let Some(first) = label.get_mut(..1) {
                first.make_ascii_uppercase();
            }
            ((*r).to_owned(), label)
        })
        .collect();

    rsx! {
        Modal {
            id: "admin-users-create".to_string(),
            open: props.open,
            size: ModalSize::Md,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Add user" },
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
                name: "username".to_string(),
                label: "Username".to_string(),
                value: "{username}",
                oninput: move |evt: FormEvent| username.set(evt.value()),
                required: true,
            }
            Input {
                name: "email".to_string(),
                r#type: "email".to_string(),
                label: "Email".to_string(),
                value: "{email}",
                oninput: move |evt: FormEvent| email.set(evt.value()),
                required: true,
            }
            Input {
                name: "password".to_string(),
                r#type: "password".to_string(),
                label: "Initial password (>= 8 chars)".to_string(),
                value: "{password}",
                oninput: move |evt: FormEvent| password.set(evt.value()),
                required: true,
            }
            Input {
                name: "role".to_string(),
                r#type: "select".to_string(),
                label: "Role".to_string(),
                value: "{role}",
                options: role_options,
                oninput: move |evt: FormEvent| role.set(evt.value()),
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct RoleModalProps {
    id: String,
    current_role: String,
    display_name: String,
    open: bool,
    on_close: EventHandler<()>,
    on_changed: Callback<()>,
}

#[component]
fn RoleModal(props: RoleModalProps) -> Element {
    let mut role = use_signal(|| props.current_role.clone());
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);

    let id_for_submit = props.id.clone();

    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let payload = RoleUpdate {
            id: id_for_submit.clone(),
            role: role.read().clone(),
        };
        let on_close = props.on_close;
        let on_changed = props.on_changed;
        spawn(async move {
            match update_user_role(payload).await {
                Ok(_) => {
                    on_changed.call(());
                    on_close.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    let role_options: Vec<(String, String)> = VALID_ROLES
        .iter()
        .map(|r| ((*r).to_owned(), (*r).to_owned()))
        .collect();

    rsx! {
        Modal {
            id: format!("admin-users-role-{}", props.id),
            open: props.open,
            size: ModalSize::Sm,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Change role" },
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
                    "Save"
                }
            },
            p { class: "text-sm mb-2",
                "Update the role for "
                strong { "{props.display_name}" }
                "."
            }
            Input {
                name: "role".to_string(),
                r#type: "select".to_string(),
                label: "Role".to_string(),
                value: "{role}",
                options: role_options,
                oninput: move |evt: FormEvent| role.set(evt.value()),
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct DeleteUserModalProps {
    id: String,
    display_name: String,
    open: bool,
    on_close: EventHandler<()>,
    on_changed: Callback<()>,
}

#[component]
fn DeleteUserModal(props: DeleteUserModalProps) -> Element {
    let mut acting = use_signal(|| false);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let id_for_submit = props.id.clone();

    let submit = move |_| {
        if *acting.read() {
            return;
        }
        acting.set(true);
        error.set(None);
        let id = id_for_submit.clone();
        let on_close = props.on_close;
        let on_changed = props.on_changed;
        spawn(async move {
            match delete_user(id).await {
                Ok(()) => {
                    on_changed.call(());
                    on_close.call(());
                }
                Err(err) => error.set(Some(err.to_string())),
            }
            acting.set(false);
        });
    };

    rsx! {
        Modal {
            id: format!("admin-users-delete-{}", props.id),
            open: props.open,
            size: ModalSize::Sm,
            on_close: move |()| props.on_close.call(()),
            title: rsx! { "Delete user" },
            actions: rsx! {
                Button {
                    variant: ButtonVariant::Ghost,
                    onclick: move |_| props.on_close.call(()),
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
                "Permanently delete "
                strong { "{props.display_name}" }
                "? Their requests stay on the books but the account cannot be restored."
            }
            if let Some(err) = error.read().clone() {
                div { class: "mt-2 text-sm text-error", "{err}" }
            }
        }
    }
}
