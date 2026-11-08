//! `Range: bytes=` parsing for the loopback stream server.
//!
//! Only a single range is supported, which is all mpv and ffmpeg send.

/// One byte range from a `Range` header, not yet checked against a size.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ByteRange {
    /// `bytes=a-`
    From(u64),
    /// `bytes=a-b`, inclusive.
    FromTo(u64, u64),
    /// `bytes=-n`, the last `n` bytes.
    Suffix(u64),
}

/// Parse a `Range` header value. Anything other than one `bytes=` range is
/// `None`, which the server treats as no `Range` header at all (RFC 9110
/// lets a server ignore a range it does not understand).
pub fn parse_range(header: &str) -> Option<ByteRange> {
    let spec = header.trim().strip_prefix("bytes=")?.trim();
    if spec.contains(',') {
        return None;
    }
    let (first, last) = spec.split_once('-')?;
    let (first, last) = (first.trim(), last.trim());
    match (first.is_empty(), last.is_empty()) {
        (true, true) => None,
        (true, false) => Some(ByteRange::Suffix(digits(last)?)),
        (false, true) => Some(ByteRange::From(digits(first)?)),
        (false, false) => {
            let (a, b) = (digits(first)?, digits(last)?);
            (a <= b).then_some(ByteRange::FromTo(a, b))
        }
    }
}

/// A plain decimal number (`u64::from_str` would also take a leading `+`).
fn digits(s: &str) -> Option<u64> {
    if s.bytes().all(|b| b.is_ascii_digit()) {
        s.parse().ok()
    } else {
        None
    }
}

impl ByteRange {
    /// The inclusive `(first, last)` byte positions this range selects in a
    /// file of `size` bytes, or `None` when it is unsatisfiable.
    pub fn resolve(self, size: u64) -> Option<(u64, u64)> {
        let last_byte = size.checked_sub(1)?;
        match self {
            Self::From(a) => (a < size).then_some((a, last_byte)),
            Self::FromTo(a, b) => (a < size).then_some((a, b.min(last_byte))),
            Self::Suffix(0) => None,
            Self::Suffix(n) => Some((size - n.min(size), last_byte)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn open_ended_range() {
        assert_eq!(parse_range("bytes=0-"), Some(ByteRange::From(0)));
    }

    #[test]
    fn closed_range() {
        assert_eq!(parse_range("bytes=10-19"), Some(ByteRange::FromTo(10, 19)));
    }

    #[test]
    fn suffix_range() {
        assert_eq!(parse_range("bytes=-500"), Some(ByteRange::Suffix(500)));
    }

    #[test]
    fn rejects_what_it_does_not_support() {
        for h in [
            "bytes=0-1,5-9",
            "items=0-1",
            "bytes=x-",
            "bytes=-",
            "bytes=5-2",
            "bytes=",
        ] {
            assert_eq!(parse_range(h), None, "{h}");
        }
    }

    #[test]
    fn resolves_against_size() {
        assert_eq!(ByteRange::From(0).resolve(100), Some((0, 99)));
        assert_eq!(ByteRange::From(100).resolve(100), None);
        assert_eq!(ByteRange::FromTo(10, 500).resolve(100), Some((10, 99)));
        assert_eq!(ByteRange::FromTo(100, 200).resolve(100), None);
        assert_eq!(ByteRange::Suffix(10).resolve(100), Some((90, 99)));
        assert_eq!(ByteRange::Suffix(500).resolve(100), Some((0, 99)));
        assert_eq!(ByteRange::Suffix(0).resolve(100), None);
        assert_eq!(ByteRange::Suffix(10).resolve(0), None);
    }
}
