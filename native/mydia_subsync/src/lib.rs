//! NIF bindings for automatic subtitle re-sync.
//!
//! Two responsibilities, both wrapping a library rather than a binary:
//! `align` over `ilass`, and (added in a later task) `voice_spans` over
//! `webrtc-vad`. The real logic lives in the sibling modules so it can be unit
//! tested without an Erlang VM.

mod align;
mod vad;

/// Aligns a subtitle's cue spans against reference speech spans.
///
/// Both arguments are lists of `{start_ms, end_ms}`. Returns
/// `{offset_ms, score}`, where the score scales with the length of `list`.
///
/// Runs on a dirty scheduler: `align_nosplit` is documented as taking up to
/// roughly 300ms on feature-length input, far past the 1ms budget a normal NIF
/// may occupy.
#[rustler::nif(schedule = "DirtyCpu")]
fn align(reference: Vec<(i64, i64)>, list: Vec<(i64, i64)>) -> (i64, f64) {
    align::align_spans(&reference, &list)
}

/// Detects speech spans in raw s16le mono 8kHz PCM at `pcm_path`.
///
/// Returns a list of `{start_ms, end_ms}`. Runs on a dirty scheduler: this
/// reads and processes the whole audio track of a feature film.
#[rustler::nif(schedule = "DirtyCpu")]
fn voice_spans(pcm_path: String) -> Result<Vec<(i64, i64)>, String> {
    vad::voice_spans_from_pcm(&pcm_path)
}

rustler::init!("Elixir.Mydia.Subsync");
