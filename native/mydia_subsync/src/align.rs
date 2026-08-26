//! Constant-offset subtitle alignment.
//!
//! `align_spans` is plain Rust with no Erlang types so it can be unit tested
//! directly. The NIF in `lib.rs` is a thin wrapper over it.

use alass_core::{align_nosplit, standard_scoring, NoProgressHandler, TimePoint, TimeSpan};

/// Aligns `list` against `reference` and returns `(offset_ms, score)`.
///
/// The score scales with the number of spans in `list`; callers normalize by
/// dividing by that length. An empty input on either side returns a zero
/// offset at zero score, which the caller's gate treats as no confidence.
///
/// Callers must check for that empty case before normalizing: the Elixir
/// wrapper divides by `length(list)` to get the normalized score, and
/// `0.0 / 0` raises `ArithmeticError` there regardless of the float
/// numerator. An empty `list` is exactly the input this function returns a
/// zero score for, so the two behaviors combine into a trap unless the
/// caller checks first.
///
/// `reference` and `list` carry caller-supplied millisecond timestamps that
/// pass straight through to `alass-core` with no range check. That library
/// sizes an internal buffer from `max_offset - min_offset` with no ceiling
/// (see `align_constant_delta` and `align_constant_delta_bucket_sort` in
/// `alass-core`'s `src/alass.rs`), so a single wildly out-of-range timestamp
/// forces a correspondingly large allocation. This runs on a dirty CPU
/// scheduler thread the BEAM cannot cancel once it starts, so callers must
/// validate or clamp timestamps to a sane bound derived from the media's
/// known duration before calling this function. This matters as soon as a
/// caller feeds in real subtitle-file content, since subtitle files are
/// untrusted input.
pub fn align_spans(reference: &[(i64, i64)], list: &[(i64, i64)]) -> (i64, f64) {
    let reference_spans = to_spans(reference);
    let list_spans = to_spans(list);

    if reference_spans.is_empty() || list_spans.is_empty() {
        return (0, 0.0);
    }

    let (delta, score) = align_nosplit(
        &reference_spans,
        &list_spans,
        standard_scoring,
        NoProgressHandler,
    );

    (i64::from(delta), score)
}

// `new_safe` orders the pair, so a cue stored end-before-start cannot panic here.
fn to_spans(pairs: &[(i64, i64)]) -> Vec<TimeSpan> {
    pairs
        .iter()
        .map(|&(start, end)| TimeSpan::new_safe(TimePoint::from(start), TimePoint::from(end)))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn evenly_spaced(count: i64) -> Vec<(i64, i64)> {
        (0..count).map(|i| (i * 7000, i * 7000 + 2000)).collect()
    }

    fn shifted(spans: &[(i64, i64)], by: i64) -> Vec<(i64, i64)> {
        spans.iter().map(|&(s, e)| (s + by, e + by)).collect()
    }

    fn normalized(score: f64, list: &[(i64, i64)]) -> f64 {
        score / list.len() as f64
    }

    #[test]
    fn recovers_an_exact_constant_shift() {
        let reference = evenly_spaced(40);
        let late = shifted(&reference, 2500);

        let (offset, score) = align_spans(&reference, &late);

        assert_eq!(offset, -2500);
        assert!(normalized(score, &late) > 0.9);
    }

    #[test]
    fn returns_zero_for_an_already_synced_track() {
        let reference = evenly_spaced(40);

        let (offset, score) = align_spans(&reference, &reference);

        assert_eq!(offset, 0);
        assert!(normalized(score, &reference) > 0.9);
    }

    #[test]
    fn scores_unrelated_content_low() {
        let reference = evenly_spaced(40);
        let unrelated: Vec<(i64, i64)> =
            (0..40).map(|i| (i * 3137 + 511, i * 3137 + 1200)).collect();

        let (_offset, score) = align_spans(&reference, &unrelated);

        assert!(normalized(score, &unrelated) < 0.5);
    }

    // The regression guard for the gate. A reference too sparse to match does
    // not error: it returns a confidently wrong offset. Only the score
    // distinguishes it, which is why the gate is mandatory rather than advisory.
    #[test]
    fn scores_a_sparse_reference_low_despite_a_large_offset() {
        let reference = evenly_spaced(40);
        let late = shifted(&reference, 2500);

        let (offset, score) = align_spans(&reference[..3], &late);

        assert!(offset.abs() > 10_000);
        assert!(normalized(score, &late) < 0.5);
    }

    #[test]
    fn returns_zero_score_for_empty_input() {
        assert_eq!(align_spans(&[], &evenly_spaced(4)), (0, 0.0));
        assert_eq!(align_spans(&evenly_spaced(4), &[]), (0, 0.0));
    }
}
