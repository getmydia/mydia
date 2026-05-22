//! `/setup` — first-time admin user setup page.
//!
//! Mirrors `MydiaWeb.FirstTimeSetupLive.Index`. Only usable when the
//! DB is empty (the server fn rejects otherwise, and the page also
//! bounces to `/login` if it detects setup is no longer required).
//!
//! Random-password mode is deferred to U24.b — the operator
//! provides a password themselves at U24.a. This is the simpler
//! single-mode case the Phoenix `LiveView` treats as default.

use dioxus::document;
use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant, Input};
use crate::routes::Route;
use crate::server_fns::auth::{setup_admin, setup_required, SetupPayload};

#[component]
pub fn Setup() -> Element {
    let username = use_signal(String::new);
    let email = use_signal(String::new);
    let password = use_signal(String::new);
    let password_confirm = use_signal(String::new);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut submitting = use_signal(|| false);
    let nav = navigator();

    // If users already exist, /setup is closed — bounce to /login.
    // Both nav.push and a meta-refresh fire (see AppShell for the
    // dev-mode SSR-only rationale).
    let setup_state = use_resource(|| async move { setup_required().await });
    let setup_closed = matches!(&*setup_state.read_unchecked(), Some(Ok(false)));
    if setup_closed {
        nav.push(Route::Login {});
    }

    let submit = move |evt: FormEvent| {
        evt.prevent_default();
        if *submitting.read() {
            return;
        }
        let pw = password.read().clone();
        let pw_confirm = password_confirm.read().clone();
        if pw != pw_confirm {
            error.set(Some("Passwords do not match".to_owned()));
            return;
        }
        submitting.set(true);
        error.set(None);
        let payload = SetupPayload {
            username: username.read().clone(),
            email: email.read().clone(),
            password: pw,
        };
        spawn(async move {
            match setup_admin(payload).await {
                Ok(_ack) => {
                    nav.push(Route::Dashboard {});
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                }
            }
            submitting.set(false);
        });
    };

    rsx! {
        if setup_closed {
            document::Meta {
                http_equiv: "refresh",
                content: "0;url=/login",
            }
        }
        div { class: "card bg-base-100 shadow-xl",
            div { class: "card-body",
                h1 { class: "card-title text-2xl", "Welcome to mydia" }
                p { class: "text-sm text-base-content/70",
                    "No users exist yet. Create the initial admin account to get started."
                }

                form {
                    id: "setup-form",
                    onsubmit: submit,
                    class: "flex flex-col gap-3 mt-2",
                    Input {
                        name: "username".to_string(),
                        label: "Username".to_string(),
                        value: "{username}",
                        required: true,
                        placeholder: "admin".to_string(),
                    }
                    Input {
                        name: "email".to_string(),
                        label: "Email".to_string(),
                        r#type: "email".to_string(),
                        value: "{email}",
                        required: true,
                    }
                    Input {
                        name: "password".to_string(),
                        label: "Password (min 8 chars)".to_string(),
                        r#type: "password".to_string(),
                        value: "{password}",
                        required: true,
                    }
                    Input {
                        name: "password_confirm".to_string(),
                        label: "Confirm password".to_string(),
                        r#type: "password".to_string(),
                        value: "{password_confirm}",
                        required: true,
                    }
                    if let Some(err) = error.read().clone() {
                        div { class: "text-sm text-error", "{err}" }
                    }
                    Button {
                        variant: ButtonVariant::Primary,
                        disabled: *submitting.read(),
                        "Create admin account"
                    }
                }
            }
        }
    }
}
