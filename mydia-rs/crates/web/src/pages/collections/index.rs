//! `/collections` — list of collections accessible to the session user.
//!
//! Port of `MydiaWeb.CollectionLive.Index`'s read surface. The Phoenix
//! page also creates new collections via a modal with a smart-rules
//! builder; create / edit / delete affordances are deferred to
//! follow-ups because the smart-rules engine isn't ported. This page
//! lists what's already there, with a search filter and type filter,
//! and links each card to its detail page.

use dioxus::prelude::*;

use crate::components::admin::AdminPageHeader;
use crate::components::collection_card::CollectionCard;
use crate::components::core::Icon;
use crate::server_fns::collections::{list_collections, CollectionListItem, CollectionListQuery};

const KIND_FILTERS: &[(&str, &str)] =
    &[("", "All Types"), ("manual", "Manual"), ("smart", "Smart")];

#[component]
pub fn Collections() -> Element {
    let query = use_signal(CollectionListQuery::default);

    let q_clone = query;
    let resource = use_resource(move || async move {
        let q = q_clone.read().clone();
        list_collections(q).await
    });

    let snapshot = resource.read_unchecked();
    let load_error: Option<String> = match snapshot.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    let collections: Vec<CollectionListItem> = match snapshot.as_ref() {
        Some(Ok(rows)) => rows.clone(),
        _ => Vec::new(),
    };
    let is_loading = snapshot.is_none();
    drop(snapshot);

    let current_search = query.read().search.clone();
    let current_kind = query.read().kind.clone().unwrap_or_default();

    rsx! {
        div { class: "max-w-7xl mx-auto",
            AdminPageHeader {
                title: "Collections".to_string(),
                subtitle: Some(
                    "Organize your movies and shows into curated groups.".to_string(),
                ),
            }

            FilterRow {
                query: query,
                current_search: current_search,
                current_kind: current_kind,
            }

            if let Some(err) = load_error {
                div { class: "alert alert-error mb-4",
                    span { "Failed to load collections: {err}" }
                }
            }

            if is_loading && collections.is_empty() {
                div { class: "flex justify-center py-12",
                    span { class: "loading loading-spinner loading-lg" }
                }
            } else if collections.is_empty() {
                EmptyState {}
            } else {
                div { class: "grid gap-3 md:gap-4 grid-cols-1 sm:grid-cols-2 md:grid-cols-3 lg:grid-cols-4",
                    for item in collections {
                        CollectionCard {
                            key: "{item.id}",
                            item: item,
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct FilterRowProps {
    query: Signal<CollectionListQuery>,
    current_search: String,
    current_kind: String,
}

#[component]
fn FilterRow(props: FilterRowProps) -> Element {
    let mut query = props.query;
    let current_search = props.current_search;
    let current_kind = props.current_kind;

    let on_search = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        next.search = evt.value();
        query.set(next);
    };

    let on_kind = move |evt: Event<FormData>| {
        let mut next = query.read().clone();
        let v = evt.value();
        next.kind = if v.is_empty() { None } else { Some(v) };
        query.set(next);
    };

    rsx! {
        div {
            id: "collections-filter-row",
            class: "flex flex-col md:flex-row gap-3 md:gap-4 mb-4 md:mb-6",
            // Search input.
            div { class: "flex-1",
                input {
                    id: "collections-search",
                    r#type: "search",
                    name: "search",
                    class: "input input-bordered w-full",
                    placeholder: "Search collections…",
                    value: "{current_search}",
                    oninput: on_search,
                }
            }
            div { class: "join",
                select {
                    id: "collections-kind-filter",
                    class: "select select-bordered join-item",
                    value: "{current_kind}",
                    onchange: on_kind,
                    for (value, label) in KIND_FILTERS.iter() {
                        option { value: *value, "{label}" }
                    }
                }
            }
        }
    }
}

#[component]
fn EmptyState() -> Element {
    rsx! {
        div { id: "collections-empty",
            class: "flex flex-col items-center justify-center py-16",
            Icon {
                name: "folder".to_string(),
                class: "w-16 h-16 text-base-content/30 mb-4".to_string(),
            }
            h3 { class: "text-xl font-semibold text-base-content/70 mb-2",
                "No collections yet"
            }
            p { class: "text-base-content/50 text-center max-w-md",
                "Create a collection from the Phoenix UI to group movies and shows. The Rust UI surfaces what's already there."
            }
        }
    }
}
