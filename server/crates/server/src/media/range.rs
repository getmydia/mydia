//! Port of MydiaWeb.Api.RangeHelper.
//!
//! Single ranges only, which is what the Elixir helper supports and what
//! every video player this serves actually sends.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Range {
    /// Inclusive on both ends, matching the HTTP header and the Elixir
    /// helper's `{:ok, start, end_pos}`.
    Satisfiable { start: u64, end: u64 },
    /// No header at all. Serve the whole file with a 200.
    Absent,
    /// A header we cannot honour. Serve a 416.
    Unsatisfiable,
}

pub fn parse(header: Option<&str>, size: u64) -> Range {
    let Some(header) = header.filter(|h| !h.is_empty()) else {
        return Range::Absent;
    };

    let Some(("bytes", spec)) = header.split_once('=') else {
        return Range::Unsatisfiable;
    };

    // range_helper.ex:41-64 splits on "-" and rejects anything that is not
    // exactly two parts, which excludes multi-range requests too.
    let Some((start, end)) = spec.split_once('-') else {
        return Range::Unsatisfiable;
    };

    let Ok(start) = start.parse::<u64>() else {
        return Range::Unsatisfiable;
    };

    if end.is_empty() {
        return if start < size {
            Range::Satisfiable {
                start,
                end: size - 1,
            }
        } else {
            Range::Unsatisfiable
        };
    }

    match end.parse::<u64>() {
        Ok(end) if start <= end && end < size => Range::Satisfiable { start, end },
        _ => Range::Unsatisfiable,
    }
}

/// range_helper.ex:104-121.
pub fn mime_for(path: &str) -> &'static str {
    let ext = path.rsplit_once('.').map(|(_, e)| e.to_lowercase());

    match ext.as_deref() {
        Some("mp4") => "video/mp4",
        Some("m4v") => "video/x-m4v",
        Some("mkv") => "video/x-matroska",
        Some("avi") => "video/x-msvideo",
        Some("webm") => "video/webm",
        Some("mov") => "video/quicktime",
        Some("wmv") => "video/x-ms-wmv",
        Some("flv") => "video/x-flv",
        Some("ts") => "video/mp2t",
        _ => "video/mp4",
    }
}

#[cfg(test)]
mod tests {
    use super::{parse, Range};

    #[test]
    fn a_closed_range_is_parsed_inclusively() {
        assert_eq!(
            parse(Some("bytes=0-499"), 1000),
            Range::Satisfiable { start: 0, end: 499 }
        );
    }

    #[test]
    fn an_open_ended_range_runs_to_the_last_byte() {
        assert_eq!(
            parse(Some("bytes=500-"), 1000),
            Range::Satisfiable {
                start: 500,
                end: 999
            }
        );
    }

    #[test]
    fn a_missing_header_is_absent_not_unsatisfiable() {
        // range_helper.ex:27 and stream_controller.ex:443. The distinction is
        // the difference between a 200 and a 416.
        assert_eq!(parse(None, 1000), Range::Absent);
        assert_eq!(parse(Some(""), 1000), Range::Absent);
    }

    #[test]
    fn a_malformed_or_out_of_bounds_range_is_unsatisfiable() {
        assert_eq!(parse(Some("bytes=invalid"), 1000), Range::Unsatisfiable);
        assert_eq!(parse(Some("items=0-10"), 1000), Range::Unsatisfiable);
        // Start beyond the file.
        assert_eq!(parse(Some("bytes=1000-"), 1000), Range::Unsatisfiable);
        // End beyond the file. range_helper.ex:58 requires end < size.
        assert_eq!(parse(Some("bytes=0-1000"), 1000), Range::Unsatisfiable);
        // Backwards.
        assert_eq!(parse(Some("bytes=500-100"), 1000), Range::Unsatisfiable);
    }

    #[test]
    fn multi_range_requests_are_not_supported() {
        // range_helper.ex only ever handles a single range.
        assert_eq!(
            parse(Some("bytes=0-99,200-299"), 1000),
            Range::Unsatisfiable
        );
    }
}
