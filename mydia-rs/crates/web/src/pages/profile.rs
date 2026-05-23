//! `/profile` — user profile and account settings (U24.d).
//!
//! Mirrors `MydiaWeb.ProfileLive.Index` core surfaces: the profile
//! form (display name + avatar URL — same mutable fields as
//! Phoenix's `User.profile_changeset/2`) and a password-change modal
//! that calls `Accounts.change_password/4` analogue.
//!
//! Theme picker, Trakt OAuth device-flow, and avatar upload are
//! deferred — they each need their own table backing port. The
//! "Account" card still shows the relevant fields (auth type, last
//! login) so operators can confirm their identity surface at a glance.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonVariant, Input};
use crate::server_fns::profile::{
    change_password, current_profile, update_profile, PasswordChangePayload, ProfilePayload,
    ProfileView,
};

#[component]
pub fn Profile() -> Element {
    let mut profile_resource = use_resource(|| async move { current_profile().await });

    rsx! {
        div { class: "flex flex-col gap-6 max-w-3xl",
            match &*profile_resource.read_unchecked() {
                None => rsx! {
                    div { class: "card bg-base-100 shadow-md",
                        div { class: "card-body",
                            span { class: "loading loading-spinner loading-md" }
                        }
                    }
                },
                Some(Err(err)) => rsx! {
                    div { class: "alert alert-error", "Failed to load profile: {err}" }
                },
                Some(Ok(profile)) => rsx! {
                    AccountSummary { profile: profile.clone() }
                    ProfileForm { profile: profile.clone(), on_saved: move || profile_resource.restart() }
                    if !profile.is_oidc {
                        PasswordCard {}
                    } else {
                        OidcPasswordHint {}
                    }
                },
            }
        }
    }
}

#[component]
fn AccountSummary(profile: ProfileView) -> Element {
    let auth_type = if profile.is_oidc {
        "OpenID Connect (SSO)"
    } else {
        "Local"
    };
    let last_login = profile.last_login_at.as_deref().unwrap_or("Never");

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-xl", "Account" }
                dl { class: "grid grid-cols-[max-content_1fr] gap-x-4 gap-y-2 text-sm",
                    dt { class: "opacity-60", "Username" }
                    dd { {profile.username.clone().unwrap_or_else(|| "—".into())} }
                    dt { class: "opacity-60", "Email" }
                    dd { {profile.email.clone().unwrap_or_else(|| "—".into())} }
                    dt { class: "opacity-60", "Role" }
                    dd { class: "uppercase tracking-wide text-xs", {profile.role.clone()} }
                    dt { class: "opacity-60", "Auth type" }
                    dd { {auth_type} }
                    dt { class: "opacity-60", "Last login" }
                    dd { {last_login} }
                }
            }
        }
    }
}

#[component]
fn ProfileForm(profile: ProfileView, on_saved: EventHandler<()>) -> Element {
    let mut display_name = use_signal(|| profile.display_name.clone().unwrap_or_default());
    let mut avatar_url = use_signal(|| profile.avatar_url.clone().unwrap_or_default());
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut info: Signal<Option<String>> = use_signal(|| None);
    let mut submitting = use_signal(|| false);

    let submit = move |evt: FormEvent| {
        evt.prevent_default();
        if *submitting.read() {
            return;
        }
        submitting.set(true);
        error.set(None);
        info.set(None);

        let payload = ProfilePayload {
            display_name: Some(display_name.read().clone()),
            avatar_url: Some(avatar_url.read().clone()),
        };
        spawn(async move {
            match update_profile(payload).await {
                Ok(_) => {
                    info.set(Some("Profile updated".into()));
                    on_saved.call(());
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                }
            }
            submitting.set(false);
        });
    };

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-xl", "Profile" }
                p { class: "text-sm text-base-content/70",
                    "Display name and avatar are the only fields editable here. To change other identity fields, an admin must update them via the admin users page."
                }

                form {
                    id: "profile-form",
                    onsubmit: submit,
                    class: "flex flex-col gap-3 mt-2",
                    Input {
                        name: "display_name".to_string(),
                        label: "Display name".to_string(),
                        value: "{display_name}",
                        oninput: move |e: FormEvent| display_name.set(e.value()),
                        placeholder: "Up to 100 characters".to_string(),
                    }
                    Input {
                        name: "avatar_url".to_string(),
                        label: "Avatar URL".to_string(),
                        r#type: "url".to_string(),
                        value: "{avatar_url}",
                        oninput: move |e: FormEvent| avatar_url.set(e.value()),
                        placeholder: "https://...".to_string(),
                    }
                    if let Some(err) = error.read().clone() {
                        div { class: "text-sm text-error", "{err}" }
                    }
                    if let Some(msg) = info.read().clone() {
                        div { class: "text-sm text-success", "{msg}" }
                    }
                    div { class: "card-actions justify-end",
                        Button {
                            variant: ButtonVariant::Primary,
                            r#type: "submit".to_string(),
                            disabled: *submitting.read(),
                            "Save"
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn PasswordCard() -> Element {
    let mut current_password = use_signal(String::new);
    let mut new_password = use_signal(String::new);
    let mut confirm_password = use_signal(String::new);
    let mut error: Signal<Option<String>> = use_signal(|| None);
    let mut info: Signal<Option<String>> = use_signal(|| None);
    let mut submitting = use_signal(|| false);

    // Cloned-into-closure handles let us read the signals from inside
    // the async block without dragging the signal's lifetime through
    // the FormEvent boundary.
    let mut cur = current_password;
    let mut new_ = new_password;
    let mut conf = confirm_password;

    let submit = move |evt: FormEvent| {
        evt.prevent_default();
        if *submitting.read() {
            return;
        }

        let payload = PasswordChangePayload {
            current_password: cur.read().clone(),
            new_password: new_.read().clone(),
            confirm_password: conf.read().clone(),
        };

        if payload.new_password != payload.confirm_password {
            error.set(Some("New passwords do not match".into()));
            return;
        }
        if payload.new_password.chars().count() < 8 {
            error.set(Some("New password must be at least 8 characters".into()));
            return;
        }

        submitting.set(true);
        error.set(None);
        info.set(None);

        spawn(async move {
            match change_password(payload).await {
                Ok(()) => {
                    info.set(Some("Password changed".into()));
                    cur.set(String::new());
                    new_.set(String::new());
                    conf.set(String::new());
                }
                Err(err) => {
                    error.set(Some(err.to_string()));
                }
            }
            submitting.set(false);
        });
    };

    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-xl", "Password" }
                p { class: "text-sm text-base-content/70",
                    "Choose a new password. You'll need to enter your current one to confirm."
                }

                form {
                    id: "password-form",
                    onsubmit: submit,
                    class: "flex flex-col gap-3 mt-2",
                    Input {
                        name: "current_password".to_string(),
                        label: "Current password".to_string(),
                        r#type: "password".to_string(),
                        value: "{current_password}",
                        oninput: move |e: FormEvent| current_password.set(e.value()),
                        required: true,
                    }
                    Input {
                        name: "new_password".to_string(),
                        label: "New password (min 8 chars)".to_string(),
                        r#type: "password".to_string(),
                        value: "{new_password}",
                        oninput: move |e: FormEvent| new_password.set(e.value()),
                        required: true,
                    }
                    Input {
                        name: "confirm_password".to_string(),
                        label: "Confirm new password".to_string(),
                        r#type: "password".to_string(),
                        value: "{confirm_password}",
                        oninput: move |e: FormEvent| confirm_password.set(e.value()),
                        required: true,
                    }
                    if let Some(err) = error.read().clone() {
                        div { class: "text-sm text-error", "{err}" }
                    }
                    if let Some(msg) = info.read().clone() {
                        div { class: "text-sm text-success", "{msg}" }
                    }
                    div { class: "card-actions justify-end",
                        Button {
                            variant: ButtonVariant::Primary,
                            r#type: "submit".to_string(),
                            disabled: *submitting.read(),
                            "Change password"
                        }
                    }
                }
            }
        }
    }
}

#[component]
fn OidcPasswordHint() -> Element {
    rsx! {
        div { class: "card bg-base-100 shadow-md",
            div { class: "card-body",
                h2 { class: "card-title text-xl", "Password" }
                div { class: "alert alert-info",
                    span {
                        "Your account is managed through Single Sign-On (OIDC). To change your password, use your identity provider."
                    }
                }
            }
        }
    }
}
