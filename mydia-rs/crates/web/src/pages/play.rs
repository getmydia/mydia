//! `/play/:type/:id` — immersive playback page (U25.d).
//!
//! Read-path port of `MydiaWeb.PlaybackLive.Show`. The Phoenix flow:
//!
//!   1. Resolve the content (movie or episode) and its best media file.
//!   2. Render an immersive black-background page with a `<video>`
//!      element + custom controls + skip-intro/credits overlays + an
//!      up-next preview when the credits roll on a TV episode.
//!   3. Periodically POST playback progress so resume-from-position
//!      works on next launch.
//!
//! mydia-rs ships the read path and the page chrome here. The actual
//! streaming source — direct-play or HLS — needs the REST byte-range
//! endpoints under `/api/v1/stream/...` that U33 introduces. Until
//! then this page surfaces the resolved file metadata and an explicit
//! "playback wiring pending" notice; once U33 lands the swap is a
//! local change inside [`PlayerSurface`].

use dioxus::prelude::*;

use crate::components::core::Icon;
use crate::routes::Route;
use crate::server_fns::media::{resolve_playable, PlayableFile, PlayableSource};

#[component]
pub fn Play(kind: String, id: String) -> Element {
    let kind_for_fetch = kind.clone();
    let id_for_fetch = id.clone();
    let resolved = use_server_future(move || {
        let kind = kind_for_fetch.clone();
        let id = id_for_fetch.clone();
        async move { resolve_playable(kind, id).await }
    })?;

    let snapshot = resolved.read_unchecked().clone();
    let Some(result) = snapshot else {
        return rsx! {
            div { class: "min-h-screen bg-black flex items-center justify-center",
                span { class: "loading loading-spinner loading-lg text-white" }
            }
        };
    };

    let source = match result {
        Ok(s) => s,
        Err(err) => {
            return rsx! {
                div { class: "min-h-screen bg-black flex items-center justify-center p-4",
                    div { class: "alert alert-error max-w-md",
                        span { "Failed to resolve playback source: {err}" }
                    }
                }
            };
        }
    };

    let back = Route::MediaShow {
        id: source.parent_media_item_id.clone(),
    };

    rsx! {
        div { class: "fixed inset-0 bg-black text-white flex flex-col",
            // Top bar — back + title. Matches Phoenix's gradient overlay.
            div { class: "absolute top-0 left-0 right-0 z-10 bg-gradient-to-b from-black/80 to-transparent p-4 flex items-center gap-4",
                Link {
                    to: back,
                    class: "btn btn-ghost btn-circle text-white hover:bg-white/20",
                    Icon { name: "x-mark", class: "w-6 h-6" }
                }
                div { class: "flex-1 min-w-0",
                    h1 { class: "text-lg font-semibold truncate", "{source.title}" }
                    if !source.subtitle.is_empty() {
                        p { class: "text-white/70 text-sm truncate", "{source.subtitle}" }
                    }
                }
            }
            div { class: "flex-1 flex items-center justify-center p-4",
                PlayerSurface { source: source }
            }
        }
    }
}

#[component]
fn PlayerSurface(source: PlayableSource) -> Element {
    let Some(file) = source.media_file else {
        return rsx! {
            div { class: "max-w-md text-center flex flex-col gap-4",
                Icon { name: "exclamation-circle", class: "w-12 h-12 mx-auto opacity-70" }
                h2 { class: "text-xl font-semibold", "Nothing to play yet" }
                p { class: "text-sm text-white/70",
                    "No media files are available for this title locally. "
                    "Trigger a library scan or wait for the next download to complete."
                }
            }
        };
    };

    let resolution = file.resolution.as_deref().unwrap_or("—");
    let codec = file.codec.as_deref().unwrap_or("—");
    let audio = file.audio_codec.as_deref().unwrap_or("—");
    let duration = format_duration(file.duration_seconds);

    rsx! {
        div { class: "max-w-2xl w-full bg-base-100/5 border border-white/10 rounded-2xl p-6 flex flex-col gap-4",
            PlaceholderPlayer { file: file.clone() }
            div { class: "grid grid-cols-2 sm:grid-cols-4 gap-3 text-sm",
                MetaCell { label: "Resolution".to_string(), value: resolution.to_string() }
                MetaCell { label: "Video codec".to_string(), value: codec.to_string() }
                MetaCell { label: "Audio".to_string(), value: audio.to_string() }
                MetaCell { label: "Duration".to_string(), value: duration }
            }
            details { class: "text-xs text-white/60",
                summary { class: "cursor-pointer", "Source path" }
                code { class: "font-mono break-all", "{file.path}" }
            }
        }
    }
}

#[component]
fn PlaceholderPlayer(file: PlayableFile) -> Element {
    // U33 wires the actual streaming endpoint here — likely
    // `/api/v1/stream/<media-token>` for byte-range direct play, or
    // an HLS playlist URL when the codec needs transcoding. Until
    // then the page renders a static "wiring pending" panel so the
    // route exists and is reachable from the media detail page.
    let _ = file; // path/codec already surfaced in MetaCell + details below
    rsx! {
        div { class: "aspect-video w-full bg-black border border-white/10 rounded-lg flex flex-col items-center justify-center gap-3 text-center px-4",
            Icon { name: "film", class: "w-12 h-12 text-white/40" }
            h2 { class: "text-lg font-semibold", "Streaming wiring pending" }
            p { class: "text-sm text-white/60 max-w-md",
                "The file is resolved and visible below. Direct playback over the "
                "byte-range REST endpoint lands with U33; until then the player "
                "surface is a placeholder."
            }
        }
    }
}

#[component]
fn MetaCell(label: String, value: String) -> Element {
    rsx! {
        div { class: "bg-white/5 rounded-lg p-3",
            div { class: "text-xs uppercase tracking-wide text-white/50", "{label}" }
            div { class: "font-mono text-sm truncate", "{value}" }
        }
    }
}

fn format_duration(seconds: Option<f64>) -> String {
    let Some(s) = seconds else {
        return "—".to_owned();
    };
    let total = s.round() as i64;
    let hours = total / 3600;
    let minutes = (total % 3600) / 60;
    let secs = total % 60;
    if hours > 0 {
        format!("{hours}:{minutes:02}:{secs:02}")
    } else {
        format!("{minutes}:{secs:02}")
    }
}
