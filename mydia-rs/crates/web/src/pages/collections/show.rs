//! `/collections/:id` — detail view of a single collection.
//!
//! Headline (name, description, type badge, item count) plus a grid
//! of member media items. Manual collections render their items from
//! the join table; smart collections render an explainer because the
//! `SmartRules.execute_query!` engine isn't ported in the Rust port.

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;
use crate::server_fns::collections::{
    get_collection_detail, list_collection_items, CollectionDetail, CollectionMember,
};

const TMDB_POSTER_BASE: &str = "https://image.tmdb.org/t/p/w342";

#[derive(Props, Clone, PartialEq, Eq)]
pub struct CollectionShowProps {
    pub id: String,
}

#[component]
pub fn CollectionShow(props: CollectionShowProps) -> Element {
    let id = props.id.clone();
    let id_for_detail = id.clone();
    let detail = use_resource(move || {
        let id = id_for_detail.clone();
        async move { get_collection_detail(id).await }
    });
    let id_for_items = id.clone();
    let items = use_resource(move || {
        let id = id_for_items.clone();
        async move { list_collection_items(id).await }
    });

    let detail_snap = detail.read_unchecked();
    let detail_err: Option<String> = match detail_snap.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    let detail_view: Option<CollectionDetail> = match detail_snap.as_ref() {
        Some(Ok(d)) => Some(d.clone()),
        _ => None,
    };
    let detail_loading = detail_snap.is_none();
    drop(detail_snap);

    let items_snap = items.read_unchecked();
    let items_view: Vec<CollectionMember> = match items_snap.as_ref() {
        Some(Ok(rows)) => rows.clone(),
        _ => Vec::new(),
    };
    let items_loading = items_snap.is_none();
    let items_err: Option<String> = match items_snap.as_ref() {
        Some(Err(err)) => Some(err.to_string()),
        _ => None,
    };
    drop(items_snap);

    rsx! {
        div { class: "max-w-7xl mx-auto",
            div { class: "mb-4",
                Link { to: Route::Collections {},
                    class: "btn btn-ghost btn-sm gap-1",
                    Icon { name: "arrow-left".to_string(), class: "w-4 h-4".to_string() }
                    "Back to collections"
                }
            }

            if detail_loading {
                div { class: "flex justify-center py-12",
                    span { class: "loading loading-spinner loading-lg" }
                }
            } else if let Some(err) = detail_err {
                div { class: "alert alert-error", span { "Failed to load collection: {err}" } }
            } else if let Some(detail) = detail_view {
                CollectionHeader { detail: detail.clone() }

                if detail.kind == "smart" {
                    SmartPlaceholder {}
                } else if items_loading && items_view.is_empty() {
                    div { class: "flex justify-center py-12",
                        span { class: "loading loading-spinner loading-md" }
                    }
                } else if let Some(err) = items_err {
                    div { class: "alert alert-error mb-4",
                        span { "Failed to load items: {err}" }
                    }
                } else if items_view.is_empty() {
                    EmptyState {}
                } else {
                    div { id: "collection-items",
                        class: "grid gap-3 md:gap-4 grid-cols-2 sm:grid-cols-3 md:grid-cols-4 lg:grid-cols-5 xl:grid-cols-6",
                        for item in items_view {
                            MemberCard { key: "{item.id}", item: item }
                        }
                    }
                }
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct CollectionHeaderProps {
    detail: CollectionDetail,
}

#[component]
fn CollectionHeader(props: CollectionHeaderProps) -> Element {
    let detail = props.detail;
    let count_label = if detail.item_count == 1 {
        "1 item".to_owned()
    } else {
        format!("{} items", detail.item_count)
    };
    rsx! {
        header { id: "collection-header",
            class: "flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between mb-6",
            div { class: "flex-1 min-w-0",
                div { class: "flex items-center gap-2 flex-wrap",
                    h1 { class: "text-2xl font-bold truncate", "{detail.name}" }
                    if detail.kind == "smart" {
                        span { class: "badge badge-secondary badge-sm",
                            Icon { name: "sparkles".to_string(), class: "w-3 h-3 mr-1".to_string() }
                            "Smart"
                        }
                    } else {
                        span { class: "badge badge-primary badge-sm",
                            Icon { name: "folder".to_string(), class: "w-3 h-3 mr-1".to_string() }
                            "Manual"
                        }
                    }
                    if detail.is_system {
                        span { class: "badge badge-ghost badge-sm",
                            Icon { name: "star".to_string(), class: "w-3 h-3 mr-1".to_string() }
                            "System"
                        }
                    }
                    if detail.visibility == "shared" {
                        span { class: "badge badge-ghost badge-sm", "Shared" }
                    }
                }
                if let Some(desc) = detail.description.as_deref() {
                    p { class: "text-sm text-base-content/70 mt-1", "{desc}" }
                }
            }
            div { class: "text-sm text-base-content/60 whitespace-nowrap",
                "{count_label}"
            }
        }
    }
}

#[derive(Props, Clone, PartialEq)]
struct MemberCardProps {
    item: CollectionMember,
}

#[component]
fn MemberCard(props: MemberCardProps) -> Element {
    let item = props.item;
    let poster_url = item
        .poster_path
        .as_deref()
        .map(|p| format!("{TMDB_POSTER_BASE}{p}"));
    let year_label = item.year.map(|y| format!("{y}")).unwrap_or_default();
    let target = Route::MediaShow {
        id: item.id.clone(),
    };

    rsx! {
        Link { to: target, class: "block group",
            div { class: "card card-compact bg-base-100 shadow-md overflow-hidden hover:shadow-2xl transition-shadow",
                figure { class: "aspect-[2/3] bg-base-300 relative overflow-hidden",
                    if let Some(url) = poster_url {
                        img {
                            src: "{url}",
                            alt: "{item.title}",
                            class: "w-full h-full object-cover group-hover:scale-105 transition-transform duration-300",
                            loading: "lazy",
                        }
                    } else {
                        div { class: "w-full h-full flex items-center justify-center text-base-content/40 text-xs",
                            "No poster"
                        }
                    }
                }
                div { class: "card-body",
                    h3 { class: "card-title text-sm leading-snug line-clamp-2", "{item.title}" }
                    div { class: "flex items-center justify-between text-xs opacity-70",
                        span { "{year_label}" }
                    }
                }
            }
        }
    }
}

#[component]
fn EmptyState() -> Element {
    rsx! {
        div { id: "collection-empty",
            class: "flex flex-col items-center justify-center py-16",
            Icon {
                name: "film".to_string(),
                class: "w-16 h-16 text-base-content/30 mb-4".to_string(),
            }
            h3 { class: "text-xl font-semibold text-base-content/70 mb-2",
                "No items yet"
            }
            p { class: "text-base-content/50 text-center max-w-md",
                "Add movies or TV shows to this collection from the Phoenix UI during the cutover window."
            }
        }
    }
}

#[component]
fn SmartPlaceholder() -> Element {
    rsx! {
        div { id: "collection-smart-placeholder",
            class: "flex flex-col items-center justify-center py-16",
            Icon {
                name: "sparkles".to_string(),
                class: "w-16 h-16 text-base-content/30 mb-4".to_string(),
            }
            h3 { class: "text-xl font-semibold text-base-content/70 mb-2",
                "Smart rules engine pending"
            }
            p { class: "text-base-content/50 text-center max-w-md",
                "This is a smart collection. The Rust port hasn't ported the rules engine yet — manage it from the Phoenix UI for now."
            }
        }
    }
}
