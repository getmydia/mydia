//! Request-media page — guest-facing search → submit request flow.
//!
//! Phoenix counterpart: `MydiaWeb.RequestMediaLive.Index`. The page is
//! mounted at `/request/movie` and `/request/series`; both share the
//! search + select + submit shape but bind `media_type` differently.
//!
//! Difference vs `add_media.rs`: the operator role can add to the
//! library directly; the guest role asks for the item, the admin
//! reviews. The submission writes a `media_requests` row that the
//! admin-side `/admin/requests` page surfaces.

use std::collections::HashSet;

use dioxus::prelude::*;

use crate::components::admin::AdminPageHeader;
use crate::components::core::{Button, ButtonVariant, Input};
use crate::components::request_form::CandidateCard;
use crate::server_fns::add_media::{search_metadata, AddMediaCandidate, SearchQuery};
use crate::server_fns::requests::{create_request, CreateRequest};

#[component]
pub fn RequestMovie() -> Element {
    rsx! { RequestMedia { media_type: "movie".to_string() } }
}

#[component]
pub fn RequestSeries() -> Element {
    rsx! { RequestMedia { media_type: "tv_show".to_string() } }
}

#[derive(Props, Clone, PartialEq, Eq)]
struct RequestMediaProps {
    media_type: String,
}

#[component]
fn RequestMedia(props: RequestMediaProps) -> Element {
    let media_type = props.media_type.clone();
    let query = use_signal(String::new);
    let mut submitted_query = use_signal(String::new);
    let busy_id = use_signal::<Option<String>>(|| None);
    let requested: Signal<HashSet<String>> = use_signal(HashSet::new);
    let last_error = use_signal::<Option<String>>(|| None);

    let mt_for_resource = media_type.clone();
    let results = use_resource(move || {
        let q = submitted_query.read().clone();
        let mt = mt_for_resource.clone();
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

    let on_query_input = {
        let mut query = query;
        move |evt: FormEvent| query.set(evt.value())
    };

    let on_submit_search = move |evt: FormEvent| {
        evt.prevent_default();
        submitted_query.set(query.read().clone());
    };

    let mt_for_submit = media_type.clone();
    let on_request = {
        let mut busy_id = busy_id;
        let mut requested = requested;
        let mut last_error = last_error;
        Callback::new(move |c: AddMediaCandidate| {
            if busy_id.read().is_some() {
                return;
            }
            busy_id.set(Some(c.external_id.clone()));
            last_error.set(None);
            let payload = CreateRequest {
                media_type: mt_for_submit.clone(),
                title: c.title.clone(),
                original_title: c.original_title.clone(),
                year: c.year,
                tmdb_id: c.external_id.parse().ok(),
                tvdb_id: None,
                imdb_id: None,
                requester_notes: None,
            };
            spawn(async move {
                match create_request(payload).await {
                    Ok(_ack) => {
                        requested.with_mut(|s| {
                            s.insert(c.external_id.clone());
                        });
                    }
                    Err(err) => last_error.set(Some(err.to_string())),
                }
                busy_id.set(None);
            });
        })
    };

    let title_label = if media_type == "tv_show" {
        "Request a TV show"
    } else {
        "Request a movie"
    };
    let subtitle = if media_type == "tv_show" {
        "Search for a series; the admin will review your request."
    } else {
        "Search for a movie; the admin will review your request."
    };

    rsx! {
        div { class: "max-w-4xl mx-auto",
            AdminPageHeader {
                title: title_label.to_string(),
                subtitle: Some(subtitle.to_string()),
                actions: None,
            }

            form {
                id: "request-media-search",
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
                        div { id: "request-media-empty", class: "text-sm text-base-content/60 py-12 text-center",
                            "Enter a title above to start a request."
                        }
                    },
                    Some(Ok(items)) if items.is_empty() => rsx! {
                        div { class: "text-sm text-base-content/60 py-12 text-center",
                            "No results for that query."
                        }
                    },
                    Some(Ok(items)) => {
                        let busy = busy_id.read().clone();
                        let already = requested.read().clone();
                        rsx! {
                            for candidate in items.iter().cloned() {
                                CandidateCard {
                                    key: "{candidate.provider}-{candidate.external_id}",
                                    candidate: candidate.clone(),
                                    cta_label: "Request".to_string(),
                                    on_cta: on_request,
                                    busy: busy.as_deref() == Some(candidate.external_id.as_str()),
                                    already_added: already.contains(&candidate.external_id),
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
                            "Enter a title above to start a request."
                        }
                    },
                }
            }
        }
    }
}
