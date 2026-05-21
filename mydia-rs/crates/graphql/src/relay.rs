//! Relay cursor helpers.
//!
//! mydia's Phoenix resolvers emit cursors as
//! `Base.encode64("cursor:#{offset}")` — NOT the Absinthe-Relay
//! default `arrayconnection:<offset>` shape. The Flutter player
//! round-trips these cursors as opaque strings, so the parity-replay
//! harness in U13 will surface any drift in the byte sequence.
//! `offset_cursor` here emits the exact shape Phoenix does.
//!
//! `id_cursor` exists for keyset-style cursors where the cursor
//! position is the last-seen node's global ID. No Phoenix resolver
//! uses this today, but discovery rails (U10) and search (U11) may
//! switch to it as scale grows.

use base64::{engine::general_purpose::STANDARD, Engine as _};

const OFFSET_PREFIX: &str = "cursor:";

/// Encode an offset cursor in the shape Phoenix's `BrowseResolver`
/// emits — base64 of `cursor:<offset>`. Pinning the prefix to
/// `cursor:` (not Absinthe-Relay's default `arrayconnection:`) is
/// what makes player-saved cursors round-trip across the two
/// backends.
pub fn offset_cursor(offset: usize) -> String {
    STANDARD.encode(format!("{OFFSET_PREFIX}{offset}"))
}

/// Decode an offset cursor produced by [`offset_cursor`]. Returns
/// `None` for malformed cursors (matching Phoenix's behavior of
/// treating malformed cursors as "no cursor / start at zero" —
/// callers translate `None` to 0).
pub fn decode_offset_cursor(raw: &str) -> Option<usize> {
    let bytes = STANDARD.decode(raw).ok()?;
    let s = std::str::from_utf8(&bytes).ok()?;
    let offset = s.strip_prefix(OFFSET_PREFIX)?;
    offset.parse::<usize>().ok()
}

/// Encode a node-ID cursor — base64 of the underlying global ID
/// string. Used for keyset-style cursors.
pub fn id_cursor(node_id: &str) -> String {
    STANDARD.encode(node_id)
}

/// Decode a node-ID cursor produced by [`id_cursor`].
pub fn decode_id_cursor(raw: &str) -> Option<String> {
    let bytes = STANDARD.decode(raw).ok()?;
    String::from_utf8(bytes).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn offset_cursor_round_trip() {
        let encoded = offset_cursor(42);
        assert_eq!(decode_offset_cursor(&encoded), Some(42));
    }

    #[test]
    fn offset_cursor_matches_phoenix_byte_shape() {
        // Phoenix: `Base.encode64("cursor:0")` produces `Y3Vyc29yOjA=`.
        // Pin the byte sequence for offset 0 (smallest) and 99 (with
        // multi-digit numerals).
        assert_eq!(offset_cursor(0), "Y3Vyc29yOjA=");
        assert_eq!(offset_cursor(99), "Y3Vyc29yOjk5");
    }

    #[test]
    fn id_cursor_round_trip() {
        let encoded = id_cursor("movie:42");
        assert_eq!(decode_id_cursor(&encoded), Some("movie:42".to_owned()));
    }

    #[test]
    fn decode_offset_cursor_rejects_garbage() {
        assert_eq!(decode_offset_cursor("not-base64!"), None);
    }

    #[test]
    fn decode_offset_cursor_rejects_wrong_prefix() {
        let encoded = STANDARD.encode("arrayconnection:0");
        assert_eq!(decode_offset_cursor(&encoded), None);
    }
}
