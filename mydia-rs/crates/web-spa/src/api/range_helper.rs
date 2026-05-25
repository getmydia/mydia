//! HTTP `Range:` parsing + content-range formatting + MIME inference.
//!
//! Port of `lib/mydia_web/controllers/api/range_helper.ex`. The Flutter
//! player issues `Range: bytes=0-` on stream start, then refined
//! ranges (`Range: bytes=<start>-<end>`) on seek. Parsing the wire
//! format here lets every streaming handler funnel through the same
//! validation and return a typed result.
//!
//! Behavior parity vs the Phoenix module:
//!   - `bytes=START-END`: returns `Ok((start, end))` when `0 <= start
//!     <= end < file_size`, else `Err`.
//!   - `bytes=START-`: returns `Ok((start, file_size - 1))` when
//!     `start >= 0 && start < file_size`, else `Err`.
//!   - Empty / `None` / malformed header: returns `Err`. Callers fall
//!     back to a `200 OK` (full body) on `None` and a `416 Range Not
//!     Satisfiable` on malformed values (matching Phoenix).
//!
//! Multi-range requests (`bytes=0-99,200-299`) are intentionally not
//! supported — the Phoenix surface never did, and the player never
//! issues them.

use std::path::Path;

/// Outcome of [`parse_range_header`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RangeOutcome {
    /// `[start, end]` inclusive, both within `[0, file_size)`.
    Range { start: u64, end: u64 },
    /// Header was malformed, out of bounds, or named a unit other than
    /// `bytes`. Callers respond with `416 Range Not Satisfiable`.
    Invalid,
}

/// Parse a `Range:` header value against the file size. See the
/// module docs for the supported forms. `header` is the raw header
/// value as received over the wire, e.g. `"bytes=0-499"` or
/// `"bytes=500-"`. The file size is the resource's total length in
/// bytes; an empty file (`file_size == 0`) always yields
/// [`RangeOutcome::Invalid`] for any non-empty header.
#[must_use]
pub fn parse_range_header(header: &str, file_size: u64) -> RangeOutcome {
    let Some(spec) = header.strip_prefix("bytes=") else {
        return RangeOutcome::Invalid;
    };

    // Reject multi-range requests outright — Phoenix only ever
    // returned the first part, and the player never sends them.
    if spec.contains(',') {
        return RangeOutcome::Invalid;
    }

    let Some((start_str, end_str)) = spec.split_once('-') else {
        return RangeOutcome::Invalid;
    };

    match (start_str.parse::<u64>(), end_str) {
        (Ok(start), "") => {
            if file_size == 0 || start >= file_size {
                RangeOutcome::Invalid
            } else {
                RangeOutcome::Range {
                    start,
                    end: file_size - 1,
                }
            }
        }
        (Ok(start), end) => match end.parse::<u64>() {
            Ok(end) if start <= end && end < file_size => RangeOutcome::Range { start, end },
            _ => RangeOutcome::Invalid,
        },
        _ => RangeOutcome::Invalid,
    }
}

/// Compute `(offset, length)` from an inclusive `[start, end]` range.
/// `length = end - start + 1`. Used to drive the `Content-Length`
/// header and the `tokio::fs::File::seek` + take-N-bytes pipeline.
#[must_use]
pub fn calculate_range(start: u64, end: u64) -> (u64, u64) {
    debug_assert!(start <= end, "calculate_range: start > end");
    (start, end - start + 1)
}

/// Format a `Content-Range` header value as `bytes <start>-<end>/<total>`.
#[must_use]
pub fn format_content_range(start: u64, end: u64, total: u64) -> String {
    format!("bytes {start}-{end}/{total}")
}

/// Best-guess MIME type for a video container by file extension.
/// Phoenix's helper covers the same 8 extensions; the fallback is
/// `video/mp4` to mirror its `_ -> "video/mp4"` arm. Non-video
/// containers fall through to that default — operators rarely serve
/// audio from the stream endpoints, and the Flutter player ignores
/// the response Content-Type when the container is one it can probe.
#[must_use]
pub fn get_mime_type(path: &Path) -> &'static str {
    let ext = path
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();

    // The default arm matches the explicit `"mp4"` body intentionally;
    // it falls back to `video/mp4` for unknown extensions because the
    // Phoenix helper does the same and the Flutter player probes the
    // container regardless of the response Content-Type.
    #[allow(clippy::match_same_arms)]
    match ext.as_str() {
        "mp4" => "video/mp4",
        "m4v" => "video/x-m4v",
        "mkv" => "video/x-matroska",
        "avi" => "video/x-msvideo",
        "webm" => "video/webm",
        "mov" => "video/quicktime",
        "wmv" => "video/x-ms-wmv",
        "flv" => "video/x-flv",
        "ts" => "video/mp2t",
        _ => "video/mp4",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_explicit_range() {
        assert_eq!(
            parse_range_header("bytes=0-499", 1000),
            RangeOutcome::Range { start: 0, end: 499 }
        );
    }

    #[test]
    fn parses_open_ended_range() {
        assert_eq!(
            parse_range_header("bytes=500-", 1000),
            RangeOutcome::Range {
                start: 500,
                end: 999
            }
        );
    }

    #[test]
    fn rejects_unknown_unit() {
        assert_eq!(parse_range_header("kb=0-499", 1000), RangeOutcome::Invalid);
    }

    #[test]
    fn rejects_out_of_bounds_end() {
        assert_eq!(
            parse_range_header("bytes=0-9999", 1000),
            RangeOutcome::Invalid
        );
    }

    #[test]
    fn rejects_inverted_range() {
        assert_eq!(
            parse_range_header("bytes=500-100", 1000),
            RangeOutcome::Invalid
        );
    }

    #[test]
    fn rejects_garbage() {
        assert_eq!(
            parse_range_header("bytes=invalid", 1000),
            RangeOutcome::Invalid
        );
        assert_eq!(parse_range_header("", 1000), RangeOutcome::Invalid);
    }

    #[test]
    fn rejects_multi_range() {
        assert_eq!(
            parse_range_header("bytes=0-99,200-299", 1000),
            RangeOutcome::Invalid
        );
    }

    #[test]
    fn rejects_start_equal_to_file_size() {
        assert_eq!(
            parse_range_header("bytes=1000-", 1000),
            RangeOutcome::Invalid
        );
    }

    #[test]
    fn calculates_inclusive_length() {
        assert_eq!(calculate_range(0, 499), (0, 500));
        assert_eq!(calculate_range(500, 999), (500, 500));
    }

    #[test]
    fn formats_content_range() {
        assert_eq!(format_content_range(0, 499, 1000), "bytes 0-499/1000");
    }

    #[test]
    fn mime_type_matches_extension() {
        assert_eq!(get_mime_type(Path::new("/foo/bar.mp4")), "video/mp4");
        assert_eq!(get_mime_type(Path::new("/foo/bar.mkv")), "video/x-matroska");
        assert_eq!(get_mime_type(Path::new("/foo/bar.MKV")), "video/x-matroska");
        assert_eq!(get_mime_type(Path::new("/foo/bar.unknown")), "video/mp4");
        assert_eq!(get_mime_type(Path::new("/foo/bar")), "video/mp4");
    }
}
