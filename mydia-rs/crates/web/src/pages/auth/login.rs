//! `/login` — password login page.
//!
//! On mount, the page checks whether any users exist (via
//! [`setup_required`]). If the DB is empty, it bounces to `/setup`
//! so the operator can create the initial admin instead of staring
//! at a useless login form.
//!
//! OIDC button is rendered disabled at U24.a; U24.b wires the PKCE
//! redirect.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant, Input};
use crate::routes::Route;
use crate::server_fns::auth::{login_with_password, setup_required, LoginPayload};

#[component]
pub fn Login() -> Element {
    let username = use_signal(String::new);
    let password = use_signal(String::new);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut submitting = use_signal(|| false);
    let nav = navigator();

    // Bounce to /setup if the DB is empty (no admin yet).
    let setup_state = use_resource(|| async move { setup_required().await });
    if let Some(Ok(true)) = &*setup_state.read_unchecked() {
        nav.push(Route::Setup {});
    }

    let submit = move |evt: FormEvent| {
        evt.prevent_default();
        if *submitting.read() {
            return;
        }
        submitting.set(true);
        error.set(None);
        let payload = LoginPayload {
            username: username.read().clone(),
            password: password.read().clone(),
        };
        spawn(async move {
            match login_with_password(payload).await {
                Ok(_ack) => {
                    nav.push(Route::Home {});
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                }
            }
            submitting.set(false);
        });
    };

    rsx! {
        div { class: "card bg-base-100 shadow-xl",
            div { class: "card-body",
                h1 { class: "card-title text-2xl", "Sign in to mydia" }
                p { class: "text-sm text-base-content/70",
                    "Enter your username and password."
                }

                form {
                    id: "login-form",
                    onsubmit: submit,
                    class: "flex flex-col gap-3 mt-2",
                    Input {
                        name: "username".to_string(),
                        label: "Username".to_string(),
                        value: "{username}",
                        required: true,
                    }
                    Input {
                        name: "password".to_string(),
                        label: "Password".to_string(),
                        r#type: "password".to_string(),
                        value: "{password}",
                        required: true,
                    }
                    if let Some(err) = error.read().clone() {
                        div { class: "text-sm text-error", "{err}" }
                    }
                    Button {
                        variant: ButtonVariant::Primary,
                        disabled: *submitting.read(),
                        "Sign in"
                    }
                }

                div { class: "divider text-xs opacity-50", "OR" }
                button {
                    r#type: "button",
                    class: "btn btn-outline btn-disabled",
                    title: "OIDC sign-in lands in U24.b",
                    "Sign in with OIDC (coming soon)"
                }
            }
        }
    }
}
