//! `/login` — password login page.
//!
//! On mount, the page checks whether any users exist (via
//! [`setup_required`]). If the DB is empty, it bounces to `/setup`
//! so the operator can create the initial admin instead of staring
//! at a useless login form.
//!
//! OIDC button activates when [`oidc_available`] returns `true` —
//! mirrors the Phoenix `auth_controller.ex` `oidc_configured?/0`
//! gate. Clicking the button is a full-page GET to
//! `/auth/oidc/login`, NOT a server fn: the handler writes PKCE
//! state into the session and returns a 302 to the provider's
//! authorization URL.

use dioxus::document;
use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant, Input};
use crate::routes::Route;
use crate::server_fns::auth::{login_with_password, oidc_available, setup_required, LoginPayload};

#[component]
pub fn Login() -> Element {
    let mut username = use_signal(String::new);
    let mut password = use_signal(String::new);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut submitting = use_signal(|| false);
    let nav = navigator();

    // Bounce to /setup if the DB is empty (no admin yet). Both the
    // navigator push and the meta-refresh fire — see AppShell for the
    // rationale (SSR-only dev mode has no wasm to act on the
    // navigator).
    let setup_state = use_resource(|| async move { setup_required().await });
    let setup_needed = matches!(&*setup_state.read_unchecked(), Some(Ok(true)));
    if setup_needed {
        nav.push(Route::Setup {});
    }

    // Show the OIDC button only when the boot-time discovery
    // succeeded. None = still loading, Some(true) = render button,
    // Some(false) = hide entirely.
    let oidc_state = use_resource(|| async move { oidc_available().await });
    let show_oidc = matches!(&*oidc_state.read_unchecked(), Some(Ok(true)));

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
        if setup_needed {
            document::Meta {
                http_equiv: "refresh",
                content: "0;url=/setup",
            }
        }
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
                        oninput: move |e: FormEvent| username.set(e.value()),
                        required: true,
                    }
                    Input {
                        name: "password".to_string(),
                        label: "Password".to_string(),
                        r#type: "password".to_string(),
                        value: "{password}",
                        oninput: move |e: FormEvent| password.set(e.value()),
                        required: true,
                    }
                    if let Some(err) = error.read().clone() {
                        div { class: "text-sm text-error", "{err}" }
                    }
                    Button {
                        variant: ButtonVariant::Primary,
                        r#type: "submit".to_string(),
                        disabled: *submitting.read(),
                        "Sign in"
                    }
                }

                if show_oidc {
                    div { class: "divider text-xs opacity-50", "OR" }
                    // Plain anchor — full-page GET to the axum handler
                    // that writes PKCE state into the session before
                    // 302ing to the provider. A server fn would not
                    // be able to set redirect + cookies in one round
                    // trip the way this does.
                    a {
                        href: "/auth/oidc/login",
                        class: "btn btn-outline",
                        "Sign in with OIDC"
                    }
                }
            }
        }
    }
}
