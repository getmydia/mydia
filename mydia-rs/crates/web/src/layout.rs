//! Top-level layout component.
//!
//! Structural mirror of `lib/mydia_web/components/layouts.ex`'s `app/1`
//! — `DaisyUI` drawer with `lg:drawer-open`, a mobile navbar with a
//! hamburger toggle, a sidebar with library/admin sections, and a
//! content area that renders the active route via `Outlet::<Route>`.
//!
//! Navigation data (movie/tv/downloads counts, current user, etc.)
//! flows through here in later units via context providers populated
//! by the U24 auth boundary. U22 ships an inert sidebar so the chrome
//! is visible on the hello page without depending on data plumbing
//! that isn't wired yet.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;
use crate::server_fns::auth::{current_user, AuthAck};

/// Thin auth-page layout — centered card on a muted background.
/// Used by `/login` and `/setup` so unauthenticated visitors aren't
/// bounced by the [`AppShell`] guard.
#[component]
pub fn AuthShell() -> Element {
    rsx! {
        div { class: "min-h-screen bg-base-200 flex items-center justify-center p-4",
            div { class: "w-full max-w-md",
                Outlet::<Route> {}
            }
        }
    }
}

#[component]
pub fn AppShell() -> Element {
    // Resolve the current user (server-fn round trip). On SSR this
    // runs once; on hydration the resource also reruns client-side
    // and surfaces the same answer. When the resource resolves to
    // `None` the guard navigates to /login.
    let user = use_resource(|| async move { current_user().await });
    let nav = navigator();

    match &*user.read_unchecked() {
        Some(Ok(Some(_))) => {
            // happy path — render the chrome below
        }
        Some(Ok(None)) => {
            // Anonymous request. Push to /login; the navigator runs
            // on the client only, so SSR still produces the chrome
            // (the wasm hydration triggers the bounce).
            nav.push(Route::Login {});
            return rsx! {
                div { class: "min-h-screen bg-base-200 flex items-center justify-center",
                    span { class: "loading loading-spinner loading-md" }
                }
            };
        }
        Some(Err(err)) => {
            // server-fn failed. Best we can do is show a generic
            // error rather than a stuck spinner — operators reload
            // or open the dev console for the underlying cause.
            return rsx! {
                div { class: "min-h-screen bg-base-200 flex items-center justify-center",
                    div { class: "alert alert-error max-w-md",
                        span { "Could not load session: {err}" }
                    }
                }
            };
        }
        None => {
            return rsx! {
                div { class: "min-h-screen bg-base-200 flex items-center justify-center",
                    span { class: "loading loading-spinner loading-md" }
                }
            };
        }
    }

    let current_user_label = match &*user.read_unchecked() {
        Some(Ok(Some(AuthAck { username, role, .. }))) => format!(
            "{} ({})",
            username.clone().unwrap_or_else(|| "user".to_owned()),
            role
        ),
        _ => String::new(),
    };

    rsx! {
        div { class: "drawer lg:drawer-open",
            input { id: "main-drawer", r#type: "checkbox", class: "drawer-toggle" }

            // Content column — mobile navbar + main outlet
            div { class: "drawer-content flex flex-col",
                MobileNavbar { user_label: current_user_label.clone() }
                main { class: "flex-1 p-4 lg:p-8 min-h-screen bg-base-200",
                    Outlet::<Route> {}
                }
            }

            // Sidebar — visible at lg+, drawer on mobile
            Sidebar { user_label: current_user_label }
        }
    }
}

#[component]
fn MobileNavbar(user_label: String) -> Element {
    rsx! {
        header { class: "lg:hidden navbar bg-base-300 border-b border-base-content/10",
            div { class: "flex-none",
                label {
                    r#for: "main-drawer",
                    class: "btn btn-square btn-ghost",
                    aria_label: "Open menu",
                    Icon { name: "menu", class: "w-6 h-6" }
                }
            }
            div { class: "flex-1 px-2 font-semibold", "mydia" }
            if !user_label.is_empty() {
                div { class: "text-xs opacity-60 pr-2", "{user_label}" }
            }
        }
    }
}

#[component]
fn Sidebar(user_label: String) -> Element {
    let nav = navigator();
    let on_logout = move |_| {
        spawn(async move {
            if let Err(err) = crate::server_fns::auth::logout().await {
                tracing::warn!(%err, "logout failed");
            }
            // Push to /login regardless — even a failed server fn
            // (network blip, expired cookie) should land the operator
            // on the login screen rather than a half-state.
            nav.push(Route::Login {});
        });
    };

    rsx! {
        div { class: "drawer-side z-30",
            label {
                r#for: "main-drawer",
                aria_label: "close sidebar",
                class: "drawer-overlay"
            }
            aside { class: "min-h-full w-64 bg-base-300 text-base-content border-r border-base-content/10 flex flex-col",
                div { class: "px-4 py-4 border-b border-base-content/10",
                    Link {
                        to: Route::Home {},
                        class: "text-xl font-bold tracking-tight hover:text-primary transition-colors",
                        "mydia"
                    }
                }
                nav { class: "flex-1 overflow-y-auto px-2 py-2",
                    ul { class: "menu menu-md",
                        li {
                            Link { to: Route::Home {},
                                Icon { name: "home", class: "w-5 h-5" }
                                "Home"
                            }
                        }
                        li {
                            Link {
                                to: Route::Hello { name: "world".into() },
                                Icon { name: "sparkles", class: "w-5 h-5" }
                                "Hello"
                            }
                        }
                        li {
                            Link {
                                to: Route::LibraryPaths {},
                                Icon { name: "home", class: "w-5 h-5" }
                                "Library paths"
                            }
                        }
                        li {
                            Link {
                                to: Route::Profile {},
                                Icon { name: "user", class: "w-5 h-5" }
                                "Profile"
                            }
                        }
                    }
                }
                div { class: "px-4 py-3 border-t border-base-content/10 flex flex-col gap-2",
                    if !user_label.is_empty() {
                        span { class: "text-xs opacity-60", "{user_label}" }
                    }
                    button {
                        r#type: "button",
                        class: "btn btn-ghost btn-sm justify-start",
                        onclick: on_logout,
                        Icon { name: "x-mark", class: "w-4 h-4" }
                        "Log out"
                    }
                }
            }
        }
    }
}
