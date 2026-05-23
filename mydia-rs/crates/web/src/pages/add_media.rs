//! Add-media page — search metadata, pick a candidate, add to library.
//!
//! Phoenix counterpart: `MydiaWeb.AddMediaLive.Index`. The full flow
//! is (a) operator types a query, (b) the page debounces and hits the
//! metadata-relay, (c) results render as cards, (d) clicking "Add"
//! creates a `media_items` row and queues a metadata-sync job. The
//! Rust port keeps a, b (without debounce — explicit submit), c, and
//! d minus the metadata-sync job dispatch (deferred — see the
//! `server_fns/add_media.rs` TODO).
//!
//! Operators can pick a quality profile from a dropdown before adding;
//! the selection writes to `media_items.quality_profile_id` (FK to
//! `quality_profiles`). The dropdown is optional — Phoenix accepts the
//! field as null and the rest of the pipeline defaults to the default
//! profile when unset. Quality profiles are not scoped by media type
//! in the schema; the picker lists every profile.

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::components::admin::{AdminPageHeader, FilterBar, FilterOption};
use crate::components::core::{Button, ButtonVariant, Input};
use crate::components::request_form::CandidateCard;
use crate::server_fns::add_media::{
    add_media_to_library, list_quality_profile_options, search_metadata, AddMediaCandidate,
    AddMediaSelection, SearchQuery,
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
    let mut quality_profile_id: Signal<Option<String>> = use_signal(|| None);

    let quality_profiles = use_resource(|| async move { list_quality_profile_options().await });

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
        let qp_signal = quality_profile_id;
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
                quality_profile_id: qp_signal.read().clone(),
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
                class: "flex gap-2 mb-3",
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

            div { id: "add-media-quality-profile", class: "mb-6",
                match &*quality_profiles.read_unchecked() {
                    Some(Ok(options)) if options.is_empty() => rsx! {
                        div { class: "text-xs text-base-content/60",
                            "No quality profiles configured — items added without one fall back to the default."
                        }
                    },
                    Some(Ok(options)) => {
                        let select_options: Vec<(String, String)> = options
                            .iter()
                            .map(|opt| (opt.id.clone(), opt.name.clone()))
                            .collect();
                        let current = quality_profile_id.read().clone().unwrap_or_default();
                        rsx! {
                            Input {
                                name: "quality_profile_id".to_string(),
                                r#type: "select".to_string(),
                                label: "Quality profile".to_string(),
                                value: "{current}",
                                options: select_options,
                                prompt: Some("Use default".to_string()),
                                oninput: move |evt: FormEvent| {
                                    let v = evt.value();
                                    if v.is_empty() {
                                        quality_profile_id.set(None);
                                    } else {
                                        quality_profile_id.set(Some(v));
                                    }
                                },
                            }
                        }
                    }
                    Some(Err(_)) => rsx! {
                        div { class: "text-xs text-warning",
                            "Could not load quality profiles; items added without one fall back to the default."
                        }
                    },
                    None => rsx! {
                        div { class: "text-xs text-base-content/60",
                            "Loading quality profiles..."
                        }
                    },
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
