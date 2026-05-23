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

use dioxus::document;
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
    // Resolve the current user server-side so SSR has the answer
    // baked into the HTML before it ships. `use_server_future` is
    // the load-bearing primitive here — `use_resource` does not
    // suspend during SSR, so its `None` initial value would force
    // the page to render an empty loading shell that never resolves
    // in the cargo-watch dev pipeline (no wasm bundle to take over).
    //
    // We collapse Err into None so the "no session" and "session
    // lookup failed" branches share one redirect path. Both should
    // bounce to /login; rendering a separate error card would only
    // be useful with a wasm client we don't currently ship.
    let user = use_server_future(|| async move { current_user().await.ok().flatten() })?;
    let nav = navigator();

    // `Resource<T>::read()` exposes a `ReadableRef<'_, Option<T>>` —
    // the outer Option signals "is the future resolved yet?". The `?`
    // above already guaranteed it is, so the outer `Some` is always
    // present here; we flatten to drop it, leaving the Option<AuthAck>
    // that means "is there a logged-in user?".
    let authenticated_user: Option<AuthAck> = user.read().clone().flatten();
    let Some(authenticated_user) = authenticated_user else {
        // Anonymous request. We emit BOTH a `<meta http-equiv=
        // "refresh">` for the SSR-only dev pipeline AND a
        // navigator push for the wasm-hydrated path. The meta
        // refresh wins instantly when wasm isn't present (which
        // is the case in the cargo-watch dev loop — `dx tools
        // assets` only ships CSS, not the wasm bundle), while
        // the nav.push gives smooth client-side routing once
        // hydration lands. Either way the user reaches /login;
        // login is a full-document transition anyway, so the
        // meta-refresh approach is correct semantically.
        nav.push(Route::Login {});
        return rsx! {
            document::Meta {
                http_equiv: "refresh",
                content: "0;url=/login",
            }
            div { class: "min-h-screen bg-base-200 flex items-center justify-center",
                span { class: "loading loading-spinner loading-md" }
            }
        };
    };

    let AuthAck { username, role, .. } = authenticated_user;
    let current_user_label = format!(
        "{} ({})",
        username.unwrap_or_else(|| "user".to_owned()),
        role
    );

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
                        to: Route::Dashboard {},
                        class: "text-xl font-bold tracking-tight hover:text-primary transition-colors",
                        "mydia"
                    }
                }
                nav { class: "flex-1 overflow-y-auto px-2 py-2",
                    ul { class: "menu menu-md",
                        li {
                            Link { to: Route::Dashboard {},
                                Icon { name: "home", class: "w-5 h-5" }
                                "Dashboard"
                            }
                        }
                        li {
                            Link {
                                to: Route::Discover {},
                                Icon { name: "sparkles", class: "w-5 h-5" }
                                "Discover"
                            }
                        }
                        li {
                            Link {
                                to: Route::Movies {},
                                Icon { name: "film", class: "w-5 h-5" }
                                "Movies"
                            }
                        }
                        li {
                            Link {
                                to: Route::TvShows {},
                                Icon { name: "tv", class: "w-5 h-5" }
                                "TV Shows"
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
