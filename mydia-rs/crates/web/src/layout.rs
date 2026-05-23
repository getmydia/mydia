//! Top-level layout component.
//!
//! Structural mirror of `lib/mydia_web/components/layouts.ex`'s `app/1`
//! — `DaisyUI` drawer with `lg:drawer-open`, a mobile navbar with a
//! hamburger toggle, a sectioned sidebar with Library / Management /
//! Administration / Requests groups, and a content area that renders
//! the active route via `Outlet::<Route>`.
//!
//! Navigation counts (movie / tv / downloads / requests) flow through
//! `LayoutData` — a context-style struct held in a signal. Today they
//! default to `None` (rendering no badge); the data-plumbing PR that
//! sources these from the DB will populate the signal at mount.
//!
//! Running jobs uses the same shape — stubbed empty for now, the live
//! `PubSub` feed lands later as part of the jobs surface.
//!
//! Role gating reads `AuthAck.role` straight off the session-resolved
//! user — `"admin"` reveals the Administration section, `"guest"` swaps
//! the Management section for Requests. Anything else gets the default
//! authenticated-user view.

use dioxus::document;
use dioxus::prelude::*;

use crate::components::core::{FlashGroup, FlashGroupProps, Icon};
use crate::routes::Route;
use crate::server_fns::auth::{current_user, AuthAck};

/// Side-channel for layout chrome state — counts the sidebar badges,
/// the running-jobs widget contents. Held in a signal at the [`AppShell`]
/// level; pages can update it via `use_context::<Signal<LayoutData>>`
/// when the data-plumbing PR lands.
#[derive(Clone, Default, PartialEq)]
pub struct LayoutData {
    pub movie_count: Option<i64>,
    pub tv_show_count: Option<i64>,
    pub downloads_count: Option<i64>,
    pub pending_requests_count: Option<i64>,
    pub running_jobs: Vec<String>,
}

/// Bootstrap script for theme persistence. Runs once on page load,
/// reads the stored preference (or falls back to the system media query),
/// and sets `data-theme` on the document root. Also exposes
/// `window.mydiaTheme` so the toggle buttons can flip the value
/// imperatively without a Dioxus signal round-trip.
const THEME_BOOTSTRAP_JS: &str = r"
(function() {
  if (typeof window === 'undefined') return;
  if (window.mydiaTheme) return;
  var STORAGE_KEY = 'mydia-theme';
  var THEMES = { SYSTEM: 'system', LIGHT: 'light', DARK: 'dark' };
  function resolved(theme) {
    if (theme === THEMES.SYSTEM) {
      try {
        return window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light';
      } catch (e) { return 'light'; }
    }
    return theme;
  }
  function apply(theme) {
    var root = document.documentElement;
    if (root) root.setAttribute('data-theme', resolved(theme));
    var indicator = document.querySelector('[data-theme-indicator]');
    if (indicator) {
      var index = theme === THEMES.LIGHT ? 1 : (theme === THEMES.DARK ? 2 : 0);
      indicator.style.left = (index * 33.3333) + '%';
    }
    document.querySelectorAll('[data-theme-button]').forEach(function(btn) {
      btn.setAttribute('data-active', btn.getAttribute('data-theme-button') === theme ? 'true' : 'false');
    });
  }
  function setTheme(theme) {
    try { localStorage.setItem(STORAGE_KEY, theme); } catch (e) {}
    apply(theme);
  }
  function current() {
    try { return localStorage.getItem(STORAGE_KEY) || THEMES.SYSTEM; } catch (e) { return THEMES.SYSTEM; }
  }
  window.mydiaTheme = { THEMES: THEMES, setTheme: setTheme, current: current };
  apply(current());
  try {
    window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function() {
      if (current() === THEMES.SYSTEM) apply(THEMES.SYSTEM);
    });
  } catch (e) {}
})();
";

/// Thin auth-page layout — centered card on a muted background.
/// Used by `/login` and `/setup` so unauthenticated visitors aren't
/// bounced by the [`AppShell`] guard.
#[component]
pub fn AuthShell() -> Element {
    rsx! {
        document::Script { {THEME_BOOTSTRAP_JS} }
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
    // baked into the HTML before it ships. See the historical comment
    // in this file's git history for the `use_server_future` vs
    // `use_resource` decision rationale.
    let user = use_server_future(|| async move { current_user().await.ok().flatten() })?;
    let nav = navigator();

    let authenticated_user: Option<AuthAck> = user.read().clone().flatten();
    let Some(authenticated_user) = authenticated_user else {
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

    // Stub layout data — counts / running jobs source from a future
    // PR. We expose it as a context so pages can populate it later
    // without changing this component's signature.
    let layout_data = use_context_provider(|| Signal::new(LayoutData::default()));
    let data = layout_data.read().clone();

    rsx! {
        document::Script { {THEME_BOOTSTRAP_JS} }
        div { class: "drawer lg:drawer-open",
            input { id: "main-drawer", r#type: "checkbox", class: "drawer-toggle" }

            // Content column — mobile navbar + main outlet + dock
            div { class: "drawer-content flex flex-col",
                MobileNavbar {}
                main { class: "flex-1 overflow-y-auto p-3 sm:p-4 md:p-6 lg:p-8 pb-20 lg:pb-8 min-h-screen bg-base-200",
                    Outlet::<Route> {}
                }
                MobileDock { user: authenticated_user.clone() }
            }

            // Sidebar — visible at lg+, drawer on mobile
            Sidebar {
                user: authenticated_user.clone(),
                data: data,
            }
        }

        // Flash group is mounted globally so any page/server-fn handler
        // can push toasts without re-mounting the toast container.
        // Sourcing flashes from a shared context is a follow-up; this
        // ships the positioning fix today.
        FlashGroup { ..FlashGroupProps { flashes: vec![] } }
    }
}

#[component]
fn MobileNavbar() -> Element {
    rsx! {
        header { class: "lg:hidden navbar bg-base-300 border-b border-base-content/10",
            div { class: "flex-none",
                label {
                    r#for: "main-drawer",
                    class: "btn btn-square btn-ghost",
                    aria_label: "Open menu",
                    Icon { name: "menu".to_string(), class: "w-6 h-6".to_string() }
                }
            }
            div { class: "flex-1 px-2",
                h1 { class: "text-xl font-bold", "Mydia" }
            }
            div { class: "flex-none",
                ThemeToggle { id: "theme-toggle-mobile".to_string() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct SidebarProps {
    user: AuthAck,
    data: LayoutData,
}

#[component]
fn Sidebar(props: SidebarProps) -> Element {
    let role = props.user.role.clone();
    let is_admin = role == "admin";
    let is_guest = role == "guest";
    let data = props.data.clone();

    // Standard authenticated user (non-guest) gets Library + Management
    // groups; guest gets Requests instead of Management. Admin layers
    // Administration on top of either path.
    rsx! {
        div { class: "drawer-side z-40",
            label {
                r#for: "main-drawer",
                aria_label: "close sidebar",
                class: "drawer-overlay",
            }
            aside { class: "flex flex-col w-64 min-h-full bg-base-300 text-base-content border-r border-base-content/10",
                // Header row — branding + Player CTA
                div { class: "p-4 border-b border-base-content/10",
                    div { class: "flex items-center justify-between",
                        Link {
                            to: Route::Dashboard {},
                            class: "flex items-center gap-2 hover:text-primary transition-colors",
                            div { class: "w-8 h-8 rounded-md bg-primary text-primary-content flex items-center justify-center font-bold",
                                "M"
                            }
                            h1 { class: "text-2xl font-bold", "Mydia" }
                        }
                    }
                }

                nav { class: "flex-1 overflow-y-auto",
                    ul { class: "menu w-full space-y-1 px-2 py-4",
                        // Library group — always visible
                        NavItem {
                            to: Route::Dashboard {},
                            icon: "home".to_string(),
                            label: "Dashboard".to_string(),
                        }
                        NavItem {
                            to: Route::Discover {},
                            icon: "sparkles".to_string(),
                            label: "Discover".to_string(),
                        }
                        NavItem {
                            to: Route::Movies {},
                            icon: "film".to_string(),
                            label: "Movies".to_string(),
                            badge: data.movie_count,
                        }
                        NavItem {
                            to: Route::TvShows {},
                            icon: "tv".to_string(),
                            label: "TV Shows".to_string(),
                            badge: data.tv_show_count,
                        }

                        if !is_guest {
                            SectionTitle { label: "Library".to_string() }
                            NavItem {
                                to: Route::Calendar {},
                                icon: "calendar".to_string(),
                                label: "Calendar".to_string(),
                            }
                            NavItem {
                                to: Route::Activity {},
                                icon: "clock".to_string(),
                                label: "Activity".to_string(),
                            }

                            SectionTitle { label: "Management".to_string() }
                            NavItem {
                                to: Route::Downloads {},
                                icon: "arrow-down-tray".to_string(),
                                label: "Downloads".to_string(),
                                badge: data.downloads_count,
                            }
                            NavItem {
                                to: Route::AddMedia {},
                                icon: "plus-circle".to_string(),
                                label: "Add media".to_string(),
                            }
                            NavItem {
                                to: Route::ImportMedia {},
                                icon: "arrow-down-on-square-stack".to_string(),
                                label: "Import library".to_string(),
                            }
                            NavItem {
                                to: Route::Search {},
                                icon: "magnifying-glass".to_string(),
                                label: "Search".to_string(),
                            }
                            NavItem {
                                to: Route::Collections {},
                                icon: "folder".to_string(),
                                label: "Collections".to_string(),
                            }
                        }

                        if is_admin {
                            SectionTitle { label: "Administration".to_string() }
                            NavItem {
                                to: Route::System {},
                                icon: "cog-6-tooth".to_string(),
                                label: "System".to_string(),
                            }
                            NavItem {
                                to: Route::Settings {},
                                icon: "cog-6-tooth".to_string(),
                                label: "Settings".to_string(),
                            }
                            NavItem {
                                to: Route::Users {},
                                icon: "users".to_string(),
                                label: "Users".to_string(),
                            }
                            NavItem {
                                to: Route::LibraryPaths {},
                                icon: "folder".to_string(),
                                label: "Library paths".to_string(),
                            }
                            NavItem {
                                to: Route::QualityProfiles {},
                                icon: "star".to_string(),
                                label: "Quality Profiles".to_string(),
                            }
                            NavItem {
                                to: Route::DownloadClients {},
                                icon: "arrow-down-tray".to_string(),
                                label: "Download Clients".to_string(),
                            }
                            NavItem {
                                to: Route::Indexers {},
                                icon: "magnifying-glass".to_string(),
                                label: "Indexers".to_string(),
                            }
                            NavItem {
                                to: Route::MediaServers {},
                                icon: "computer-desktop".to_string(),
                                label: "Media Servers".to_string(),
                            }
                            NavItem {
                                to: Route::RemoteAccess {},
                                icon: "signal".to_string(),
                                label: "Remote Access".to_string(),
                            }
                            NavItem {
                                to: Route::ImportLists {},
                                icon: "arrow-down-on-square-stack".to_string(),
                                label: "Import Lists".to_string(),
                            }
                            NavItem {
                                to: Route::ReleaseBlacklist {},
                                icon: "no-symbol".to_string(),
                                label: "Release Blacklist".to_string(),
                            }
                            NavItem {
                                to: Route::Jobs {},
                                icon: "queue-list".to_string(),
                                label: "Background Jobs".to_string(),
                            }
                            NavItem {
                                to: Route::Transcodes {},
                                icon: "film".to_string(),
                                label: "Transcodes".to_string(),
                            }
                            NavItem {
                                to: Route::Devices {},
                                icon: "user".to_string(),
                                label: "Devices".to_string(),
                            }
                            NavItem {
                                to: Route::Requests {},
                                icon: "inbox-stack".to_string(),
                                label: "Requests".to_string(),
                                badge: data.pending_requests_count,
                            }
                        }

                        if is_guest {
                            SectionTitle { label: "Requests".to_string() }
                            NavItem {
                                to: Route::RequestMovie {},
                                icon: "film".to_string(),
                                label: "Request Movie".to_string(),
                            }
                            NavItem {
                                to: Route::RequestSeries {},
                                icon: "tv".to_string(),
                                label: "Request Series".to_string(),
                            }
                            NavItem {
                                to: Route::MyRequests {},
                                icon: "queue-list".to_string(),
                                label: "My Requests".to_string(),
                            }
                        }
                    }
                }

                // Running jobs widget — stubbed today, populated via
                // LayoutData context once the jobs PubSub stream lands.
                if !data.running_jobs.is_empty() {
                    RunningJobsWidget { jobs: data.running_jobs.clone() }
                }

                // User menu + desktop theme toggle pinned at the bottom.
                UserMenu { user: props.user.clone() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct NavItemProps {
    to: Route,
    icon: String,
    label: String,
    #[props(default)]
    badge: Option<i64>,
}

#[component]
fn NavItem(props: NavItemProps) -> Element {
    rsx! {
        li {
            Link { to: props.to,
                Icon { name: props.icon, class: "w-5 h-5".to_string() }
                "{props.label}"
                if let Some(n) = props.badge {
                    if n > 0 {
                        span { class: "badge badge-sm", "{n}" }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct LinkPlaceholderProps {
    href: String,
    icon: String,
    label: String,
    #[props(default)]
    badge: Option<i64>,
    #[props(default = String::from("badge badge-sm"))]
    badge_class: String,
}

/// Plain `<a href>` for routes that don't have a Dioxus `Route` variant
/// yet. Renders the same chrome as [`NavItem`] so the sidebar looks
/// uniform; clicking falls back to a full-page navigation which the
/// server handles. Replace with `Link { to: Route::… }` when the
/// matching route lands.
#[component]
fn LinkPlaceholder(props: LinkPlaceholderProps) -> Element {
    rsx! {
        li {
            a { href: "{props.href}",
                Icon { name: props.icon, class: "w-5 h-5".to_string() }
                "{props.label}"
                if let Some(n) = props.badge {
                    if n > 0 {
                        span { class: "{props.badge_class}", "{n}" }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq, Eq)]
struct SectionTitleProps {
    label: String,
}

#[component]
fn SectionTitle(props: SectionTitleProps) -> Element {
    rsx! {
        li { class: "menu-title mt-4",
            span { "{props.label}" }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct RunningJobsWidgetProps {
    jobs: Vec<String>,
}

#[component]
fn RunningJobsWidget(props: RunningJobsWidgetProps) -> Element {
    let total = props.jobs.len();
    let visible: Vec<String> = props.jobs.iter().take(3).cloned().collect();
    let overflow = total.saturating_sub(visible.len());

    rsx! {
        div { class: "px-4 py-2 border-t border-base-content/10",
            div { class: "bg-base-200 rounded-lg p-2",
                div { class: "flex items-center gap-2 text-sm font-medium mb-1",
                    span { class: "loading loading-spinner loading-xs text-primary" }
                    span { "Running Jobs" }
                    span { class: "badge badge-primary badge-xs", "{total}" }
                }
                ul { class: "text-xs opacity-70 space-y-0.5 pl-5",
                    for job in visible.iter() {
                        li { class: "truncate", "{job}" }
                    }
                    if overflow > 0 {
                        li { class: "text-primary", "+{overflow} more..." }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct UserMenuProps {
    user: AuthAck,
}

#[component]
fn UserMenu(props: UserMenuProps) -> Element {
    let nav = navigator();
    let user = props.user.clone();
    let on_logout = move |_| {
        spawn(async move {
            if let Err(err) = crate::server_fns::auth::logout().await {
                tracing::warn!(%err, "logout failed");
            }
            nav.push(Route::Login {});
        });
    };

    let display_name = user
        .username
        .clone()
        .unwrap_or_else(|| user.user_id.clone());
    let initials = display_name
        .chars()
        .take(2)
        .collect::<String>()
        .to_uppercase();

    rsx! {
        div { class: "space-y-3 p-4 border-t border-base-300",
            div { class: "dropdown dropdown-top dropdown-end w-full",
                label {
                    tabindex: "0",
                    class: "btn btn-ghost w-full justify-start",
                    div { class: "avatar placeholder",
                        div { class: "bg-neutral text-neutral-content rounded-full w-8",
                            span { class: "text-xs", "{initials}" }
                        }
                    }
                    div { class: "flex-1 text-left",
                        div { class: "text-sm font-medium", "{display_name}" }
                        div { class: "text-xs opacity-60 capitalize", "{user.role}" }
                    }
                    Icon { name: "chevron-up".to_string(), class: "w-4 h-4".to_string() }
                }
                ul {
                    tabindex: "0",
                    class: "dropdown-content menu p-2 shadow-lg bg-base-200 rounded-box w-52 mb-2",
                    li {
                        Link { to: Route::Profile {},
                            Icon { name: "cog-6-tooth".to_string(), class: "w-4 h-4".to_string() }
                            "Settings"
                        }
                    }
                    li { class: "mt-2 border-t border-base-300 pt-2",
                        button {
                            r#type: "button",
                            class: "text-error",
                            onclick: on_logout,
                            Icon { name: "arrow-right-on-rectangle".to_string(), class: "w-4 h-4".to_string() }
                            "Logout"
                        }
                    }
                }
            }

            // Desktop theme toggle — mobile copy lives in MobileNavbar.
            div { class: "hidden lg:flex justify-center",
                ThemeToggle { id: "theme-toggle-sidebar".to_string() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq, Eq)]
struct ThemeToggleProps {
    #[props(default = String::from("theme-toggle"))]
    id: String,
}

/// Three-button toggle (System / Light / Dark) with a sliding indicator
/// pill. The buttons call into `window.mydiaTheme.setTheme(...)`, which
/// is defined by [`THEME_BOOTSTRAP_JS`] and persists the choice in
/// localStorage. Initial paint also runs through the bootstrap so the
/// indicator + `data-theme` are correct before Dioxus hydration.
#[component]
fn ThemeToggle(props: ThemeToggleProps) -> Element {
    let set_system = move |_| {
        document::eval("window.mydiaTheme && window.mydiaTheme.setTheme('system')");
    };
    let set_light = move |_| {
        document::eval("window.mydiaTheme && window.mydiaTheme.setTheme('light')");
    };
    let set_dark = move |_| {
        document::eval("window.mydiaTheme && window.mydiaTheme.setTheme('dark')");
    };

    rsx! {
        div {
            id: "{props.id}",
            class: "relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full",
            div {
                "data-theme-indicator": "true",
                class: "absolute w-1/3 h-full rounded-full border border-base-200 bg-base-100 brightness-200 transition-[left] duration-200",
                style: "left: 0",
            }
            button {
                r#type: "button",
                "data-theme-button": "system",
                class: "relative flex p-2 cursor-pointer w-1/3 justify-center z-10",
                title: "System theme",
                onclick: set_system,
                Icon { name: "computer-desktop".to_string(), class: "size-4 opacity-75 hover:opacity-100".to_string() }
            }
            button {
                r#type: "button",
                "data-theme-button": "light",
                class: "relative flex p-2 cursor-pointer w-1/3 justify-center z-10",
                title: "Light theme",
                onclick: set_light,
                Icon { name: "sun".to_string(), class: "size-4 opacity-75 hover:opacity-100".to_string() }
            }
            button {
                r#type: "button",
                "data-theme-button": "dark",
                class: "relative flex p-2 cursor-pointer w-1/3 justify-center z-10",
                title: "Dark theme",
                onclick: set_dark,
                Icon { name: "moon".to_string(), class: "size-4 opacity-75 hover:opacity-100".to_string() }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct MobileDockProps {
    user: AuthAck,
}

#[component]
fn MobileDock(props: MobileDockProps) -> Element {
    let is_guest = props.user.role == "guest";

    rsx! {
        nav {
            id: "mobile-dock",
            class: "lg:hidden fixed z-50 left-3 right-3 bottom-3 flex items-center justify-around rounded-2xl px-2 py-2 bg-base-100/60 backdrop-blur-3xl backdrop-saturate-150 border border-white/20 shadow-[0_8px_32px_rgba(0,0,0,0.12),inset_0_1px_0_rgba(255,255,255,0.2)]",

            DockLink {
                to: Route::Dashboard {},
                icon: "home".to_string(),
                label: "Home".to_string(),
            }
            DockLink {
                to: Route::Discover {},
                icon: "sparkles".to_string(),
                label: "Discover".to_string(),
            }

            if is_guest {
                DockLink {
                    to: Route::RequestMovie {},
                    icon: "film".to_string(),
                    label: "Request".to_string(),
                }
                DockLink {
                    to: Route::MyRequests {},
                    icon: "queue-list".to_string(),
                    label: "Requests".to_string(),
                }
            } else {
                DockLink {
                    to: Route::Movies {},
                    icon: "film".to_string(),
                    label: "Movies".to_string(),
                }
                DockLink {
                    to: Route::TvShows {},
                    icon: "tv".to_string(),
                    label: "TV".to_string(),
                }
                DockLink {
                    to: Route::Profile {},
                    icon: "user".to_string(),
                    label: "Profile".to_string(),
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct DockLinkProps {
    to: Route,
    icon: String,
    label: String,
}

#[component]
fn DockLink(props: DockLinkProps) -> Element {
    rsx! {
        Link {
            to: props.to,
            class: "flex flex-col items-center justify-center min-w-[52px] py-1.5 rounded-xl opacity-60 hover:opacity-100 transition-opacity",
            Icon { name: props.icon, class: "size-5".to_string() }
            span { class: "text-[10px] mt-0.5", "{props.label}" }
        }
    }
}
