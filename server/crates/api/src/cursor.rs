//! Offset cursors, byte-identical to the Elixir server's
//! (browse_resolver.ex:220-231).
//!
//! Opaque to the client and cheap to compute. They are not stable across an
//! insert, which is the same tradeoff the Elixir server already makes.

use base64::Engine;

pub fn encode(offset: i64) -> String {
    base64::engine::general_purpose::STANDARD.encode(format!("cursor:{offset}"))
}

/// Returns the offset the cursor points at, or -1 when it cannot be read.
/// Callers add one, so an unreadable cursor starts the page at zero.
pub fn decode(cursor: &str) -> i64 {
    let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(cursor) else {
        return -1;
    };

    let Ok(text) = String::from_utf8(bytes) else {
        return -1;
    };

    text.strip_prefix("cursor:")
        .and_then(|offset| offset.parse().ok())
        .unwrap_or(-1)
}

#[cfg(test)]
mod tests {
    use super::{decode, encode};

    #[test]
    fn a_cursor_round_trips() {
        assert_eq!(decode(&encode(7)), 7);
    }

    #[test]
    fn the_encoding_matches_the_elixir_server() {
        // Base.encode64("cursor:0")
        assert_eq!(encode(0), "Y3Vyc29yOjA=");
    }

    #[test]
    fn an_unreadable_cursor_starts_from_the_beginning() {
        // decode + 1 == 0, matching browse_resolver.ex:224-231.
        assert_eq!(decode("not base64"), -1);
        assert_eq!(decode(""), -1);
    }

    #[test]
    fn a_cursor_with_the_wrong_prefix_starts_from_the_beginning() {
        use base64::Engine;
        let wrong = base64::engine::general_purpose::STANDARD.encode("offset:5");

        assert_eq!(decode(&wrong), -1);
    }
}
