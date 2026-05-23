//! Request-form helpers shared between the add-media and request-media
//! flows.
//!
//! Phoenix counterpart: the metadata-search list + result card layout
//! in `lib/mydia_web/live/request_media_live/index.html.heex` and
//! `lib/mydia_web/live/add_media_live/index.html.heex`. The two pages
//! render very similar cards — title, year, poster, overview, action
//! button — with a different CTA per surface (Add to library / Request).
//!
//! The card component is intentionally CTA-agnostic; the page passes
//! the button label and the callback for the click.

use dioxus::prelude::*;

use crate::components::core::{Button, ButtonSize, ButtonVariant};
use crate::server_fns::add_media::AddMediaCandidate;

#[derive(Props, Clone, PartialEq)]
pub struct CandidateCardProps {
    pub candidate: AddMediaCandidate,
    pub cta_label: String,
    /// Called with the candidate when the operator clicks the CTA.
    pub on_cta: Callback<AddMediaCandidate>,
    /// True when this candidate is currently being submitted — disables
    /// the CTA and shows a spinner.
    #[props(default)]
    pub busy: bool,
    /// True if the candidate has already been added (Phoenix: present
    /// in the `requested_items` `MapSet`).
    #[props(default)]
    pub already_added: bool,
}

#[component]
pub fn CandidateCard(props: CandidateCardProps) -> Element {
    let c = props.candidate.clone();
    let on_cta = props.on_cta;
    let cta_for_click = c.clone();

    let year = c.year.map(|y| y.to_string());
    let media_type_label = match c.media_type.as_str() {
        "movie" => "Movie",
        "tv_show" => "TV",
        other => other,
    };

    rsx! {
        div { class: "card card-side bg-base-100 shadow-sm border border-base-content/5",
            // Poster column — fixed width, placeholder when missing.
            if let Some(path) = c.poster_path.as_ref() {
                figure { class: "w-24 shrink-0",
                    img {
                        src: "https://image.tmdb.org/t/p/w200{path}",
                        alt: "{c.title}",
                        class: "object-cover w-full h-full",
                    }
                }
            } else {
                figure { class: "w-24 shrink-0 bg-base-200 flex items-center justify-center text-xs text-base-content/40",
                    "No poster"
                }
            }
            div { class: "card-body p-4 gap-1",
                div { class: "flex items-center gap-2 flex-wrap",
                    h3 { class: "card-title text-base", "{c.title}" }
                    span { class: "badge badge-ghost badge-sm", "{media_type_label}" }
                    if let Some(year) = year.as_deref() {
                        span { class: "text-xs text-base-content/60", "{year}" }
                    }
                }
                if let Some(overview) = c.overview.as_deref() {
                    p { class: "text-xs text-base-content/70 line-clamp-2", "{overview}" }
                }
                div { class: "card-actions mt-1 justify-end",
                    if props.already_added {
                        span { class: "badge badge-success", "Added" }
                    } else {
                        Button {
                            variant: ButtonVariant::Primary,
                            size: ButtonSize::Sm,
                            disabled: props.busy,
                            loading: props.busy,
                            onclick: move |_| on_cta.call(cta_for_click.clone()),
                            "{props.cta_label}"
                        }
                    }
                }
            }
        }
    }
}
