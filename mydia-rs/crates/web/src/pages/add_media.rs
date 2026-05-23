//! Add-media page — search metadata, pick a candidate, add to library.
//!
//! Phoenix counterpart: `MydiaWeb.AddMediaLive.Index`. The full flow
//! is (a) operator types a query, (b) the page debounces and hits the
//! metadata-relay, (c) results render as cards, (d) clicking "Add"
//! creates a `media_items` row and queues a metadata-sync job. The
//! Rust port keeps a, b (without debounce — explicit submit), c, and
//! d minus the metadata-sync job dispatch (deferred — see the
//! `server_fns/add_media.rs` TODO).

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonVariant, Input};
use crate::components::request_form::CandidateCard;
use crate::server_fns::add_media::{
    add_media_to_library, search_metadata, AddMediaCandidate, AddMediaSelection, SearchQuery,
};

const MEDIA_TYPE_OPTIONS: &[(&str, &str)] = &[("movie", "Movies"), ("tv_show", "TV Shows")];

#[component]
pub fn AddMedia() -> Element {
    let media_type = use_signal(|| "movie".to_owned());
    let query = use_signal(String::new);
    let mut submitted_query = use_signal(String::new);
    let busy_id = use_signal::<Option<String>>(|| None);
    let added: Signal<HashSet<String>> = use_signal(HashSet::new);
    let last_error = use_signal::<Option<String>>(|| None);

    let results = use_resource(move || {
        let q = submitted_query.read().clone();
        let mt = media_type.read().clone();
        async move {
            if q.trim().is_empty() {
                Ok(Vec::new())
            } else {
                search_metadata(SearchQuery {
                    query: q,
                    media_type: mt,
                })
                .await
            }
        }
    });

    let on_media_type = {
        let mut media_type = media_type;
        move |value: String| media_type.set(value)
    };

    let on_query_input = {
        let mut query = query;
        move |evt: FormEvent| query.set(evt.value())
    };

    let on_submit_search = move |evt: FormEvent| {
        evt.prevent_default();
        submitted_query.set(query.read().clone());
    };

    let on_add = {
        let mut busy_id = busy_id;
        let mut added = added;
        let mut last_error = last_error;
        Callback::new(move |c: AddMediaCandidate| {
            if busy_id.read().is_some() {
                return;
            }
            busy_id.set(Some(c.external_id.clone()));
            last_error.set(None);
            let selection = AddMediaSelection {
                provider: c.provider.clone(),
                external_id: c.external_id.clone(),
                title: c.title.clone(),
                media_type: c.media_type.clone(),
                year: c.year,
                quality_profile_id: None,
            };
            spawn(async move {
                match add_media_to_library(selection).await {
                    Ok(_ack) => {
                        added.with_mut(|s| {
                            s.insert(c.external_id.clone());
                        });
                    }
                    Err(err) => last_error.set(Some(err.to_string())),
                }
                busy_id.set(None);
            });
        })
    };

    rsx! {
        div { class: "max-w-4xl mx-auto",
            AdminPageHeader {
                title: "Add media".to_string(),
                subtitle: Some(
                    "Search for a movie or TV show by title and add it to your library.".to_string(),
                ),
                actions: None,
            }

            div { class: "mb-3",
                FilterBar {
                    current: media_type.read().clone(),
                    options: MEDIA_TYPE_OPTIONS
                        .iter()
                        .map(|(v, l)| FilterOption::new(*v, *l))
                        .collect(),
                    on_select: on_media_type,
                }
            }

            form {
                id: "add-media-search",
                class: "flex gap-2 mb-6",
                onsubmit: on_submit_search,
                div { class: "flex-1",
                    Input {
                        name: "query".to_string(),
                        placeholder: Some("Search by title…".to_string()),
                        value: "{query}",
                        oninput: on_query_input,
                    }
                }
                Button {
                    variant: ButtonVariant::Primary,
                    r#type: "submit".to_string(),
                    "Search"
                }
            }

            if let Some(err) = last_error.read().clone() {
                div { class: "alert alert-error mb-4", "{err}" }
            }

            section { class: "space-y-3",
                match &*results.read_unchecked() {
                    Some(Ok(items)) if items.is_empty() && submitted_query.read().is_empty() => rsx! {
                        div { id: "add-media-empty", class: "text-sm text-base-content/60 py-12 text-center",
                            "Enter a title above to search the metadata catalog."
                        }
                    },
                    Some(Ok(items)) if items.is_empty() => rsx! {
                        div { class: "text-sm text-base-content/60 py-12 text-center",
                            "No results for that query."
                        }
                    },
                    Some(Ok(items)) => {
                        let busy = busy_id.read().clone();
                        let already_added = added.read().clone();
                        rsx! {
                            for candidate in items.iter().cloned() {
                                CandidateCard {
                                    key: "{candidate.provider}-{candidate.external_id}",
                                    candidate: candidate.clone(),
                                    cta_label: "Add".to_string(),
                                    on_cta: on_add,
                                    busy: busy.as_deref() == Some(candidate.external_id.as_str()),
                                    already_added: already_added.contains(&candidate.external_id),
                                }
                            }
                        }
                    }
                    Some(Err(err)) => rsx! {
                        div { class: "alert alert-error", "Search failed: {err}" }
                    },
                    None if !submitted_query.read().is_empty() => rsx! {
                        div { class: "py-8 text-center",
                            span { class: "loading loading-spinner loading-md" }
                        }
                    },
                    None => rsx! {
                        div { class: "text-sm text-base-content/60 py-12 text-center",
                            "Enter a title above to search the metadata catalog."
                        }
                    },
                }
            }
        }
    }
}
