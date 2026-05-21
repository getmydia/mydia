//! Global node ID encoding and decoding.
//!
//! Port of `lib/mydia_web/schema/resolvers/node_id.ex`. The plan note that
//! global IDs are base64-encoded does not match what Phoenix actually
//! emits: `node_id.ex` returns plain colon-delimited strings like
//! `"movie:42"` and `"season:abc-uuid:3"`. The "byte-for-byte match"
//! verification clause is load-bearing, so this module emits the same
//! plain-text form. Tests pin the exact byte sequence against the
//! Phoenix shape.
//!
//! Five node kinds are encoded:
//!
//! | Kind          | Prefix     | Shape                                |
//! |---------------|-----------|--------------------------------------|
//! | Movie         | `movie:`   | `movie:<id>`                         |
//! | TV Show       | `show:`    | `show:<id>`                          |
//! | Episode       | `episode:` | `episode:<id>`                       |
//! | Library Path  | `library:` | `library:<id>`                       |
//! | Season        | `season:`  | `season:<show_id>:<season_number>`   |
//!
//! The Phoenix port accepts either integer or UUID/string IDs. Integer
//! IDs decode to `NodeRef::Int`; anything else decodes to `NodeRef::Str`.

use std::fmt;

/// Identifier carried inside a node ID.
///
/// Phoenix decodes purely-integer IDs into integers (for legacy auto-
/// increment tables) and everything else into strings (UUIDs).
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum NodeRef {
    Int(i64),
    Str(String),
}

impl fmt::Display for NodeRef {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            NodeRef::Int(n) => write!(f, "{n}"),
            NodeRef::Str(s) => f.write_str(s),
        }
    }
}

impl From<i64> for NodeRef {
    fn from(value: i64) -> Self {
        NodeRef::Int(value)
    }
}

impl From<String> for NodeRef {
    fn from(value: String) -> Self {
        NodeRef::Str(value)
    }
}

impl<'a> From<&'a str> for NodeRef {
    fn from(value: &'a str) -> Self {
        NodeRef::Str(value.to_owned())
    }
}

impl From<uuid::Uuid> for NodeRef {
    fn from(value: uuid::Uuid) -> Self {
        NodeRef::Str(value.to_string())
    }
}

/// Decoded node identity.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeId {
    Movie(NodeRef),
    TvShow(NodeRef),
    Episode(NodeRef),
    LibraryPath(NodeRef),
    Season {
        show_id: NodeRef,
        season_number: i32,
    },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
#[error("invalid node id")]
pub struct InvalidNodeId;

impl NodeId {
    /// Stable type tag — the prefix that appears in the encoded form.
    pub fn type_tag(&self) -> &'static str {
        match self {
            NodeId::Movie(_) => "movie",
            NodeId::TvShow(_) => "show",
            NodeId::Episode(_) => "episode",
            NodeId::LibraryPath(_) => "library",
            NodeId::Season { .. } => "season",
        }
    }

    /// Encode to the byte-equivalent Absinthe form.
    pub fn encode(&self) -> String {
        match self {
            NodeId::Movie(id) => format!("movie:{id}"),
            NodeId::TvShow(id) => format!("show:{id}"),
            NodeId::Episode(id) => format!("episode:{id}"),
            NodeId::LibraryPath(id) => format!("library:{id}"),
            NodeId::Season {
                show_id,
                season_number,
            } => format!("season:{show_id}:{season_number}"),
        }
    }

    /// Decode a global ID string. Returns [`InvalidNodeId`] on any
    /// malformed input. The grammar is strict: unknown prefixes,
    /// empty IDs, or unparseable season numbers all reject.
    pub fn decode(raw: &str) -> Result<Self, InvalidNodeId> {
        let (prefix, rest) = raw.split_once(':').ok_or(InvalidNodeId)?;

        match prefix {
            "movie" => Ok(NodeId::Movie(parse_ref(rest)?)),
            "show" => Ok(NodeId::TvShow(parse_ref(rest)?)),
            "episode" => Ok(NodeId::Episode(parse_ref(rest)?)),
            "library" => Ok(NodeId::LibraryPath(parse_ref(rest)?)),
            "season" => {
                let (show_id_raw, season_raw) = rest.split_once(':').ok_or(InvalidNodeId)?;
                let show_id = parse_ref(show_id_raw)?;
                let season_number = season_raw.parse::<i32>().map_err(|_| InvalidNodeId)?;
                Ok(NodeId::Season {
                    show_id,
                    season_number,
                })
            }
            _ => Err(InvalidNodeId),
        }
    }
}

impl fmt::Display for NodeId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.encode())
    }
}

fn parse_ref(raw: &str) -> Result<NodeRef, InvalidNodeId> {
    if raw.is_empty() {
        return Err(InvalidNodeId);
    }

    // Mirror Phoenix's `Integer.parse(id_str)` with the empty-rest
    // check: a string is treated as integer ID only when it parses
    // cleanly with no trailing garbage. Otherwise it's an opaque
    // string (UUID, slug, etc.).
    if let Ok(n) = raw.parse::<i64>() {
        // Reject leading-zero shapes Phoenix's Integer.parse would
        // accept but that aren't normalized for round-trip equality.
        // `Integer.parse("007")` returns `{7, ""}`, so re-emit
        // matches `7` — Phoenix's encoder also stringifies the int
        // before formatting, so this is consistent with Absinthe.
        Ok(NodeRef::Int(n))
    } else {
        Ok(NodeRef::Str(raw.to_owned()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encode_movie_integer_id() {
        // Matches Phoenix `MydiaWeb.Schema.Resolvers.NodeId.encode(:movie, 42)`.
        assert_eq!(NodeId::Movie(NodeRef::Int(42)).encode(), "movie:42");
    }

    #[test]
    fn encode_movie_uuid_id() {
        let raw = "0186fa3d-9d57-7c1a-8c2e-1b0c5e6f7a8b";
        assert_eq!(
            NodeId::Movie(NodeRef::Str(raw.to_owned())).encode(),
            "movie:0186fa3d-9d57-7c1a-8c2e-1b0c5e6f7a8b"
        );
    }

    #[test]
    fn encode_tv_show_uses_show_prefix() {
        // Phoenix:  encode(:tv_show, id) → "show:#{id}".
        assert_eq!(NodeId::TvShow(NodeRef::Int(7)).encode(), "show:7");
    }

    #[test]
    fn encode_episode() {
        assert_eq!(NodeId::Episode(NodeRef::Int(99)).encode(), "episode:99");
    }

    #[test]
    fn encode_library_path() {
        assert_eq!(NodeId::LibraryPath(NodeRef::Int(3)).encode(), "library:3");
    }

    #[test]
    fn encode_season_uses_show_id_and_season_number() {
        assert_eq!(
            NodeId::Season {
                show_id: NodeRef::Int(11),
                season_number: 5,
            }
            .encode(),
            "season:11:5"
        );
    }

    #[test]
    fn encode_season_with_uuid_show_id() {
        assert_eq!(
            NodeId::Season {
                show_id: NodeRef::Str("abc-uuid".to_owned()),
                season_number: 2,
            }
            .encode(),
            "season:abc-uuid:2"
        );
    }

    #[test]
    fn decode_movie_integer() {
        assert_eq!(
            NodeId::decode("movie:42").unwrap(),
            NodeId::Movie(NodeRef::Int(42))
        );
    }

    #[test]
    fn decode_movie_uuid() {
        let raw = "movie:0186fa3d-9d57-7c1a-8c2e-1b0c5e6f7a8b";
        assert_eq!(
            NodeId::decode(raw).unwrap(),
            NodeId::Movie(NodeRef::Str(
                "0186fa3d-9d57-7c1a-8c2e-1b0c5e6f7a8b".to_owned()
            ))
        );
    }

    #[test]
    fn decode_tv_show() {
        assert_eq!(
            NodeId::decode("show:7").unwrap(),
            NodeId::TvShow(NodeRef::Int(7))
        );
    }

    #[test]
    fn decode_season_integer_show_id() {
        assert_eq!(
            NodeId::decode("season:11:5").unwrap(),
            NodeId::Season {
                show_id: NodeRef::Int(11),
                season_number: 5,
            }
        );
    }

    #[test]
    fn decode_season_uuid_show_id() {
        assert_eq!(
            NodeId::decode("season:abc-uuid:2").unwrap(),
            NodeId::Season {
                show_id: NodeRef::Str("abc-uuid".to_owned()),
                season_number: 2,
            }
        );
    }

    #[test]
    fn decode_rejects_unknown_prefix() {
        assert_eq!(NodeId::decode("widget:1"), Err(InvalidNodeId));
    }

    #[test]
    fn decode_rejects_missing_colon() {
        assert_eq!(NodeId::decode("movie42"), Err(InvalidNodeId));
    }

    #[test]
    fn decode_rejects_empty_id() {
        // Phoenix `parse_id("")` returns `:error`; same here.
        assert_eq!(NodeId::decode("movie:"), Err(InvalidNodeId));
    }

    #[test]
    fn decode_rejects_season_missing_number() {
        assert_eq!(NodeId::decode("season:11"), Err(InvalidNodeId));
    }

    #[test]
    fn decode_rejects_season_non_integer_number() {
        assert_eq!(NodeId::decode("season:11:foo"), Err(InvalidNodeId));
    }

    #[test]
    fn round_trip_integer() {
        let original = NodeId::Movie(NodeRef::Int(42));
        let encoded = original.encode();
        let decoded = NodeId::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn round_trip_uuid() {
        let original = NodeId::Episode(NodeRef::Str("uuid-1234".to_owned()));
        let encoded = original.encode();
        let decoded = NodeId::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn round_trip_season() {
        let original = NodeId::Season {
            show_id: NodeRef::Str("uuid-show".to_owned()),
            season_number: 9,
        };
        let encoded = original.encode();
        let decoded = NodeId::decode(&encoded).unwrap();
        assert_eq!(decoded, original);
    }

    #[test]
    fn type_tags_stable() {
        assert_eq!(NodeId::Movie(NodeRef::Int(1)).type_tag(), "movie");
        assert_eq!(NodeId::TvShow(NodeRef::Int(1)).type_tag(), "show");
        assert_eq!(NodeId::Episode(NodeRef::Int(1)).type_tag(), "episode");
        assert_eq!(NodeId::LibraryPath(NodeRef::Int(1)).type_tag(), "library");
        assert_eq!(
            NodeId::Season {
                show_id: NodeRef::Int(1),
                season_number: 0
            }
            .type_tag(),
            "season"
        );
    }
}
