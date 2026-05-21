//! Relay cursor helpers.
//!
//! async-graphql's [`async_graphql::connection`] module supplies the
//! Connection / Edge / PageInfo machinery. The cursor encoding it uses
//! by default is opaque, so this module exposes a thin compatibility
//! layer that emits cursors in the shape Absinthe Relay produces —
//! base64 of `arrayconnection:<offset>` for the common offset case,
//! base64 of the underlying ID for cursor-on-ID style connections.
//!
//! Cursor parity matters because the Flutter player ships paginated
//! browse queries with `after` cursors plucked from prior responses;
//! drifting the cursor encoding would break pagination silently mid-
//! session. The parity replay harness in U13 catches drift, but the
//! cheaper guarantee is to emit Absinthe's exact bytes here.

use base64::{engine::general_purpose::STANDARD, Engine as _};

/// Encode an opaque array-index cursor in the shape Absinthe Relay
/// emits for offset-paginated connections.
pub fn array_cursor(offset: usize) -> String {
    STANDARD.encode(format!("arrayconnection:{offset}"))
}

/// Decode an array-index cursor produced by [`array_cursor`].
pub fn decode_array_cursor(raw: &str) -> Option<usize> {
    let bytes = STANDARD.decode(raw).ok()?;
    let s = std::str::from_utf8(&bytes).ok()?;
    let offset = s.strip_prefix("arrayconnection:")?;
    offset.parse::<usize>().ok()
}

/// Encode a node-ID cursor — base64 of the underlying global ID
/// string. Use this for keyset-style cursors where the cursor
/// position is the last-seen node's global ID.
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
    fn array_cursor_round_trip() {
        let encoded = array_cursor(42);
        assert_eq!(decode_array_cursor(&encoded), Some(42));
    }

    #[test]
    fn array_cursor_matches_absinthe_relay_shape() {
        // Absinthe Relay's offset-cursor for offset=0 is the base64 of
        // the string "arrayconnection:0". Pin the byte sequence.
        assert_eq!(array_cursor(0), "YXJyYXljb25uZWN0aW9uOjA=");
    }

    #[test]
    fn array_cursor_offset_one() {
        assert_eq!(array_cursor(1), "YXJyYXljb25uZWN0aW9uOjE=");
    }

    #[test]
    fn id_cursor_round_trip() {
        let encoded = id_cursor("movie:42");
        assert_eq!(decode_id_cursor(&encoded), Some("movie:42".to_owned()));
    }

    #[test]
    fn decode_array_cursor_rejects_garbage() {
        assert_eq!(decode_array_cursor("not-base64!"), None);
    }

    #[test]
    fn decode_array_cursor_rejects_wrong_prefix() {
        // Decodes as valid base64 of "garbage:0" — should still reject
        // because the prefix isn't "arrayconnection:".
        let encoded = STANDARD.encode("garbage:0");
        assert_eq!(decode_array_cursor(&encoded), None);
    }
}
