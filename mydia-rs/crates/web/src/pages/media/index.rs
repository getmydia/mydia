//! `/movies` and `/tv` — paginated grid of media items (U25.a).
//!
//! Port of `MydiaWeb.MediaLive.Index`. The Phoenix page carries
//! ~950 LOC of selection mode, batch actions, modals, and real-time
//! scan progress; U25.a establishes the read path (list + filter +
//! search + sort + paginate). U25.d aligns the page chrome (header,
//! actions, view-mode toggle, filter join, selection scaffolding)
//! with the Phoenix shape so the parity diff narrows. Bulk action
//! server fns and search debouncing land in follow-ups.

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonSize, ButtonVariant, Header, Icon};
use crate::components::media::{MediaCard, MediaListRow};
use crate::layout::LayoutData;
use crate::server_fns::auth::{current_user, AuthAck};
use crate::server_fns::media::{list_media, MediaListItem, MediaQuery, MediaSort, MonitoredFilter};

const SORT_OPTIONS: &[(&str, &str)] = &[
    ("title_asc", "Title (A-Z)"),
    ("title_desc", "Title (Z-A)"),
    ("year_desc", "Year (newest)"),
    ("year_asc", "Year (oldest)"),
    ("added_desc", "Recently added"),
    ("added_asc", "Oldest added"),
];

const QUALITY_OPTIONS: &[(&str, &str)] = &[
    ("", "All Quality"),
    ("720p", "720p"),
    ("1080p", "1080p"),
    ("2160p", "4K"),
];

#[derive(Clone, Copy, PartialEq, Eq, Default)]
enum ViewMode {
    #[default]
    Grid,
    List,
}

#[component]
pub fn Movies() -> Element {
    rsx! {
        MediaIndex {
            kind: "movie".to_string(),
            page_title: "Movies".to_string(),
        }
    }
}

#[component]
pub fn TvShows() -> Element {
    rsx! {
        MediaIndex {
            kind: "tv_show".to_string(),
            page_title: "TV Shows".to_string(),
        }
    }
}

#[component]
fn MediaIndex(kind: String, page_title: String) -> Element {
    // Local UI state — filter query, view mode, selection mode.
    let mut query = use_signal(|| MediaQuery::new(&kind));
    // Quality filter — not yet wired into MediaQuery server-side, but
    // we keep the UI control so users see the same chrome as Phoenix.
    let quality_filter = use_signal(String::new);
    let view_mode = use_signal(ViewMode::default);
    let selection_mode = use_signal(|| false);
    let selected_ids: Signal<HashSet<String>> = use_signal(HashSet::new);
    // Re-scan affordance — Phoenix wires this to `trigger_rescan`. The
    // Rust port doesn't have the scan worker yet, so the button is a
    // visible no-op with a TODO marker.
    let scanning = use_signal(|| false);

    // Resolve the current user for role gating. We re-fetch here rather
    // than threading it through props so the page works regardless of
    // how it's mounted. `AuthAck.role` drives the admin/guest CTA split.
    let user_resource = use_server_future(|| async move { current_user().await.ok().flatten() })?;
    let user: Option<AuthAck> = user_resource.read().clone().flatten();
    let role = user.as_ref().map(|u| u.role.clone()).unwrap_or_default();
    let is_guest = role == "guest";
    // TODO(role-gating): the layout context doesn't yet expose role,
    // so we resolve via `current_user` here. Once `LayoutData` carries
    // role, drop the extra server call.

    // Accumulator pattern — first page replaces, later pages append.
    let mut accumulator: Signal<Vec<MediaListItem>> = use_signal(Vec::new);
    let mut current_total = use_signal(|| 0i64);
    let mut current_has_more = use_signal(|| false);

    let q_clone = query;
    let page_resource = use_resource(move || async move {
        let q = q_clone.read().clone();
        list_media(q).await
    });

    let q_for_effect = query;
    let resource_clone = page_resource;
    use_effect(move || {
        let snapshot = resource_clone.read_unchecked();
        let Some(Ok(page)) = snapshot.as_ref() else {
            return;
        };
        let page_clone = page.clone();
        let q = q_for_effect.read().clone();
        if q.page == 0 {
            accumulator.set(page_clone.items.clone());
        } else {
            let mut next = accumulator.read().clone();
            next.extend(page_clone.items.iter().cloned());
            accumulator.set(next);
        }
        current_total.set(page_clone.total);
        current_has_more.set(page_clone.has_more);
    });

    // Side-effect: push the total count into LayoutData so the sidebar
    // badge updates. Reading `current_total` inside the effect ties the
    // write to the count signal so subsequent page changes refresh the
    // badge.
    let mut layout = use_context::<Signal<LayoutData>>();
    let kind_for_layout = kind.clone();
    use_effect(move || {
        let total = *current_total.read();
        if total > 0 {
            let mut data = layout.read().clone();
            match kind_for_layout.as_str() {
                "movie" => data.movie_count = Some(total),
                "tv_show" => data.tv_show_count = Some(total),
                _ => {}
            }
            layout.set(data);
        }
    });

    let resource_snapshot = page_resource.read_unchecked();
    let is_loading = resource_snapshot.is_none();
    let load_error: Option<String> = match resource_snapshot.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    drop(resource_snapshot);

    let items_snapshot = accumulator.read().clone();
    let total = *current_total.read();
    let has_more = *current_has_more.read();
    let selection_count = selected_ids.read().len();
    let in_selection_mode = *selection_mode.read();
    let current_view = *view_mode.read();
    let has_active_filters = !query.read().search.is_empty()
        || query.read().monitored != MonitoredFilter::All
        || !quality_filter.read().is_empty();

    rsx! {
        div { class: "flex flex-col h-full",

            // ---- Header ----
            PageHeader {
                title: page_title.clone(),
                kind: kind.clone(),
                total: total,
                is_guest: is_guest,
                scanning: scanning,
                view_mode: view_mode,
                selection_mode: selection_mode,
                selection_count: selection_count,
                selected_ids: selected_ids,
            }

            // ---- Filter row ----
            FilterRow {
                query: query,
                quality_filter: quality_filter,
                kind: kind.clone(),
            }

            // ---- Error banner ----
            if let Some(err) = load_error {
                div { class: "alert alert-error mb-4",
                    span { "Failed to load: {err}" }
                }
            }

            // ---- Body: grid, list, empty state, or initial loader ----
            if items_snapshot.is_empty() && is_loading {
                div { class: "flex justify-center py-12",
                    span { class: "loading loading-spinner loading-lg" }
                }
            } else if items_snapshot.is_empty() {
                EmptyState {
                    kind: kind.clone(),
                    has_active_filters: has_active_filters,
                    on_clear: move |_| {
                        let mut next = query.read().clone();
                        next.search = String::new();
                        next.monitored = MonitoredFilter::All;
                        next.page = 0;
                        query.set(next);
                        quality_filter.clone().set(String::new());
                    },
                }
            } else {
                match current_view {
                    ViewMode::Grid => rsx! {
                        div { class: "grid gap-3 md:gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6",
                            for item in items_snapshot.iter().cloned() {
                                {
                                    let id = item.id.clone();
                                    let id_for_handler = id.clone();
                                    let selected = selected_ids.read().contains(&id);
                                    rsx! {
                                        MediaCard {
                                            key: "{id}",
                                            item: item,
                                            selection_mode: in_selection_mode,
                                            selected: selected,
                                            on_select: move |_| {
                                                let mut next = selected_ids.read().clone();
                                                if next.contains(&id_for_handler) {
                                                    next.remove(&id_for_handler);
                                                } else {
                                                    next.insert(id_for_handler.clone());
                                                }
                                                selected_ids.clone().set(next);
                                            },
                                        }
                                    }
                                }
                            }
                        }
                    },
                    ViewMode::List => rsx! {
                        div { class: "card bg-base-100 shadow-lg overflow-hidden",
                            // List header
                            div { class: "flex items-center bg-base-200 font-semibold text-sm px-4 py-3 border-b border-base-300",
                                div { class: "w-10 flex-shrink-0" }
                                div { class: "w-14 flex-shrink-0" }
                                div { class: "flex-1 min-w-0", "Title" }
                                div { class: "w-20 hidden md:block text-center flex-shrink-0", "Year" }
                                div { class: "w-28 hidden lg:block flex-shrink-0", "Status" }
                                div { class: "w-20 hidden lg:block text-center flex-shrink-0", "Quality" }
                            }
                            for item in items_snapshot.iter().cloned() {
                                {
                                    let id = item.id.clone();
                                    let id_for_handler = id.clone();
                                    let selected = selected_ids.read().contains(&id);
                                    rsx! {
                                        MediaListRow {
                                            key: "{id}",
                                            item: item,
                                            selection_mode: in_selection_mode,
                                            selected: selected,
                                            on_select: move |_| {
                                                let mut next = selected_ids.read().clone();
                                                if next.contains(&id_for_handler) {
                                                    next.remove(&id_for_handler);
                                                } else {
                                                    next.insert(id_for_handler.clone());
                                                }
                                                selected_ids.clone().set(next);
                                            },
                                        }
                                    }
                                }
                            }
                        }
                    },
                }
            }

            // ---- Load more / end indicator ----
            if has_more {
                div { class: "flex justify-center pt-4 pb-6",
                    Button {
                        variant: ButtonVariant::Outline,
                        disabled: is_loading,
                        loading: is_loading,
                        onclick: move |_| {
                            let mut next = query.read().clone();
                            next.page = next.page.saturating_add(1);
                            query.set(next);
                        },
                        if is_loading { "Loading…" } else { "Load more" }
                    }
                }
            } else if !items_snapshot.is_empty() {
                div { class: "text-center text-xs opacity-50 py-4",
                    "End of results"
                }
            }

            // ---- Bulk-action floating toolbar ----
            if in_selection_mode {
                BulkActionBar {
                    selected_count: selection_count,
                    selection_mode: selection_mode,
                    selected_ids: selected_ids,
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct PageHeaderProps {
    title: String,
    kind: String,
    total: i64,
    is_guest: bool,
    scanning: Signal<bool>,
    view_mode: Signal<ViewMode>,
    selection_mode: Signal<bool>,
    selection_count: usize,
    selected_ids: Signal<HashSet<String>>,
}

#[component]
fn PageHeader(props: PageHeaderProps) -> Element {
    let kind = props.kind.clone();
    let kind_for_add = kind.clone();
    let kind_for_request = kind.clone();
    let is_guest = props.is_guest;
    let scanning_signal = props.scanning;
    let is_scanning = *scanning_signal.read();
    let view_mode_signal = props.view_mode;
    let mut selection_mode = props.selection_mode;
    let mut selected_ids = props.selected_ids;
    let selection_count = props.selection_count;
    let in_selection_mode = *selection_mode.read();

    let total = props.total;
    let title = props.title.clone();

    // Add / Request route — Phoenix has /add/movie, /add/series,
    // /request/movie, /request/series. None of those routes exist on
    // the Rust side yet — we wire the buttons to no-op stubs and log
    // a TODO. Once the routes land, swap these for `Link { to: … }`.
    let add_label = if kind_for_add == "movie" {
        "Add Movie"
    } else {
        "Add Series"
    };
    let request_label = if kind_for_request == "movie" {
        "Request Movie"
    } else {
        "Request Series"
    };

    let actions = rsx! {
        div { class: "flex items-center gap-2 flex-wrap",

            // Selection mode toggle — visible when not already in
            // selection mode, lets the operator enter bulk-edit.
            if !in_selection_mode {
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    onclick: move |_| {
                        selection_mode.set(true);
                    },
                    Icon { name: "check".to_string(), class: "w-4 h-4".to_string() }
                    span { class: "hidden sm:inline ml-1", "Select" }
                }
            } else {
                Button {
                    variant: ButtonVariant::Ghost,
                    size: ButtonSize::Sm,
                    onclick: move |_| {
                        selection_mode.set(false);
                        selected_ids.set(HashSet::new());
                    },
                    Icon { name: "x-mark".to_string(), class: "w-4 h-4".to_string() }
                    span { class: "hidden sm:inline ml-1", "Done" }
                }
                span { class: "text-sm opacity-70 px-1", "{selection_count} selected" }
            }

            // Re-scan
            Button {
                variant: ButtonVariant::Ghost,
                size: ButtonSize::Sm,
                disabled: is_scanning,
                loading: is_scanning,
                onclick: move |_| {
                    // TODO(server-fn): wire trigger_rescan once the
                    // scan worker is ported. Today this is a no-op.
                    tracing::info!("rescan requested (stub)");
                },
                if !is_scanning {
                    Icon { name: "arrow-path".to_string(), class: "w-4 h-4".to_string() }
                }
                span { class: "hidden sm:inline ml-1",
                    if is_scanning { "Scanning…" } else { "Re-scan" }
                }
            }

            // Add or Request CTA
            if is_guest {
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Sm,
                    onclick: move |_| {
                        // TODO(routes): point at /request/movie or
                        // /request/series once those Routes exist.
                        tracing::info!("request flow requested (stub)");
                    },
                    Icon { name: "plus".to_string(), class: "w-4 h-4".to_string() }
                    span { class: "hidden sm:inline ml-1", "{request_label}" }
                }
            } else {
                Button {
                    variant: ButtonVariant::Primary,
                    size: ButtonSize::Sm,
                    onclick: move |_| {
                        // TODO(routes): point at /add/movie or
                        // /add/series once those Routes exist.
                        tracing::info!("add flow requested (stub)");
                    },
                    Icon { name: "plus".to_string(), class: "w-4 h-4".to_string() }
                    span { class: "hidden sm:inline ml-1", "{add_label}" }
                }
            }

            // Import (admin only)
            if !is_guest {
                Button {
                    variant: ButtonVariant::Secondary,
                    size: ButtonSize::Sm,
                    onclick: move |_| {
                        // TODO(routes): /import landing page.
                        tracing::info!("import flow requested (stub)");
                    },
                    Icon { name: "arrow-down-tray".to_string(), class: "w-4 h-4".to_string() }
                    span { class: "hidden sm:inline ml-1", "Import" }
                }
            }

            // View mode toggle — DaisyUI join group with two buttons.
            div { class: "join",
                ViewModeButton {
                    mode: ViewMode::Grid,
                    current: view_mode_signal,
                    icon: "photo".to_string(),
                    title: "Grid view".to_string(),
                }
                ViewModeButton {
                    mode: ViewMode::List,
                    current: view_mode_signal,
                    icon: "queue-list".to_string(),
                    title: "List view".to_string(),
                }
            }
        }
    };

    rsx! {
        div { class: "mb-4 md:mb-6",
            Header {
                title: title,
                subtitle: rsx! { "Browse and manage your media library — {total} total" },
                actions: actions,
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct ViewModeButtonProps {
    mode: ViewMode,
    current: Signal<ViewMode>,
    icon: String,
    title: String,
}

#[component]
fn ViewModeButton(props: ViewModeButtonProps) -> Element {
    let mut current = props.current;
    let mode = props.mode;
    let is_active = *current.read() == mode;
    let class = if is_active {
        "btn btn-sm join-item btn-primary"
    } else {
        "btn btn-sm join-item"
    };

    rsx! {
        button {
            r#type: "button",
            class: "{class}",
            title: "{props.title}",
            onclick: move |_| current.set(mode),
            Icon { name: props.icon, class: "w-4 h-4".to_string() }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct FilterRowProps {
    query: Signal<MediaQuery>,
    quality_filter: Signal<String>,
    kind: String,
}

#[component]
fn FilterRow(props: FilterRowProps) -> Element {
    let mut query = props.query;
    let mut quality_filter = props.quality_filter;
    let current_search = query.read().search.clone();
    let current_sort = query.read().sort;
    let current_monitored = query.read().monitored;
    let current_quality = quality_filter.read().clone();

    let on_search = move |evt: Event<FormData>| {
        // TODO(debounce): Phoenix uses phx-debounce="300" — wiring a
        // debounce here needs a use_future + cancel-on-change shape.
        // For now we re-fetch on every keystroke; this is fine on a
        // local network but warrants a debounce before production.
        let mut next = query.read().clone();
        next.search = evt.value();
        next.page = 0;
        query.set(next);
    };

    let on_sort = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.sort = MediaSort::parse(&evt.value());
        next.page = 0;
        query.set(next);
    };

    let on_monitored = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.monitored = MonitoredFilter::parse(&evt.value());
        next.page = 0;
        query.set(next);
    };

    let on_quality = move |evt: Event<FormData>| {
        // TODO(server-fn): MediaQuery doesn't expose `quality` yet, so
        // this select is presentational. Users see the chrome match
        // Phoenix, but filtering by quality requires extending
        // MediaQuery + the SQL path in server_fns/media.rs.
        quality_filter.set(evt.value());
    };

    let monitored_value = match current_monitored {
        MonitoredFilter::All => "all",
        MonitoredFilter::Monitored => "true",
        MonitoredFilter::Unmonitored => "false",
    };

    rsx! {
        div { class: "flex flex-col md:flex-row gap-3 md:gap-4 mb-4 md:mb-6",
            // Search input — flex-1 so it eats remaining width.
            div { class: "flex-1",
                input {
                    r#type: "search",
                    name: "search",
                    class: "input input-bordered w-full",
                    placeholder: "Search media…",
                    value: "{current_search}",
                    oninput: on_search,
                }
            }

            // Filter join group: monitored, quality, sort.
            div { class: "join",
                select {
                    class: "select select-bordered join-item",
                    value: "{monitored_value}",
                    onchange: on_monitored,
                    option { value: "all", "All Status" }
                    option { value: "true", "Monitored" }
                    option { value: "false", "Unmonitored" }
                }
                select {
                    class: "select select-bordered join-item",
                    value: "{current_quality}",
                    onchange: on_quality,
                    for (value, label) in QUALITY_OPTIONS.iter() {
                        option { value: *value, "{label}" }
                    }
                }
                select {
                    class: "select select-bordered join-item",
                    title: "Sort by",
                    value: "{current_sort.as_str()}",
                    onchange: on_sort,
                    for (value, label) in SORT_OPTIONS.iter() {
                        option { value: *value, "{label}" }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct EmptyStateProps {
    kind: String,
    has_active_filters: bool,
    on_clear: EventHandler<MouseEvent>,
}

#[component]
fn EmptyState(props: EmptyStateProps) -> Element {
    let icon_name = if props.kind == "tv_show" {
        "tv"
    } else {
        "film"
    };
    let message = if props.has_active_filters {
        "No media match the current filters."
    } else {
        "No media here yet. Add a library path and run a scan to import your collection."
    };

    rsx! {
        div { class: "flex flex-col items-center justify-center py-16",
            Icon {
                name: icon_name.to_string(),
                class: "w-16 h-16 text-base-content/30 mb-4".to_string(),
            }
            h3 { class: "text-xl font-semibold text-base-content/70 mb-2", "No media found" }
            p { class: "text-base-content/50 text-center max-w-md mb-4", "{message}" }
            if props.has_active_filters {
                Button {
                    variant: ButtonVariant::Outline,
                    size: ButtonSize::Sm,
                    onclick: move |evt| props.on_clear.call(evt),
                    "Clear filters"
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct BulkActionBarProps {
    selected_count: usize,
    selection_mode: Signal<bool>,
    selected_ids: Signal<HashSet<String>>,
}

#[component]
fn BulkActionBar(props: BulkActionBarProps) -> Element {
    let selected_count = props.selected_count;
    let mut selection_mode = props.selection_mode;
    let mut selected_ids = props.selected_ids;
    let has_selection = selected_count > 0;

    rsx! {
        div { class: "fixed bottom-6 left-1/2 -translate-x-1/2 z-50",
            div { class: "bg-base-100 shadow-2xl rounded-box border border-base-300 px-3 py-2",
                div { class: "flex items-center gap-2",
                    span { class: "text-sm font-medium tabular-nums px-2",
                        "{selected_count} selected"
                    }
                    div { class: "w-px h-6 bg-base-300" }

                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        disabled: !has_selection,
                        onclick: move |_| {
                            // TODO(server-fn): wire bulk monitor toggle.
                            tracing::info!("bulk monitor (stub)");
                        },
                        Icon { name: "star".to_string(), class: "w-4 h-4".to_string() }
                        span { class: "hidden sm:inline ml-1", "Monitor" }
                    }

                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        disabled: !has_selection,
                        onclick: move |_| {
                            // TODO(server-fn): wire bulk unmonitor.
                            tracing::info!("bulk unmonitor (stub)");
                        },
                        Icon { name: "star-solid".to_string(), class: "w-4 h-4".to_string() }
                        span { class: "hidden sm:inline ml-1", "Unmonitor" }
                    }

                    Button {
                        variant: ButtonVariant::Ghost,
                        size: ButtonSize::Sm,
                        disabled: !has_selection,
                        onclick: move |_| {
                            // TODO(server-fn): wire bulk delete with
                            // a confirmation modal.
                            tracing::info!("bulk delete (stub)");
                        },
                        Icon { name: "trash".to_string(), class: "w-4 h-4 text-error".to_string() }
                        span { class: "hidden sm:inline ml-1", "Remove" }
                    }

                    div { class: "w-px h-6 bg-base-300" }

                    Button {
                        variant: ButtonVariant::Primary,
                        size: ButtonSize::Sm,
                        onclick: move |_| {
                            selection_mode.set(false);
                            selected_ids.set(HashSet::new());
                        },
                        "Done"
                    }
                }
            }
        }
    }
}
