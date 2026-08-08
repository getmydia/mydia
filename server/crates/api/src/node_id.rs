//! Global node ids, matching lib/mydia_web/schema/resolvers/node_id.ex.
//!
//! Only the `node` query uses these. Every type's own `id` field is its raw
//! row id, which is what `movie(id:)` and friends take.

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NodeRef {
    Movie(String),
    TvShow(String),
    Episode(String),
    LibraryPath(String),
    Season { show_id: String, season_number: i64 },
}

pub fn decode(raw: &str) -> Option<NodeRef> {
    let (prefix, rest) = raw.split_once(':')?;

    if rest.is_empty() {
        return None;
    }

    let node = match prefix {
        "movie" => NodeRef::Movie(rest.to_string()),
        "show" => NodeRef::TvShow(rest.to_string()),
        "episode" => NodeRef::Episode(rest.to_string()),
        "library" => NodeRef::LibraryPath(rest.to_string()),
        "season" => {
            let (show_id, season_number) = rest.rsplit_once(':')?;

            if show_id.is_empty() {
                return None;
            }

            NodeRef::Season {
                show_id: show_id.to_string(),
                season_number: season_number.parse().ok()?,
            }
        }
        _ => return None,
    };

    Some(node)
}

#[cfg(test)]
mod tests {
    use super::{decode, NodeRef};

    #[test]
    fn every_prefix_from_the_elixir_encoder_decodes() {
        assert!(matches!(decode("movie:abc"), Some(NodeRef::Movie(id)) if id == "abc"));
        assert!(matches!(decode("show:abc"), Some(NodeRef::TvShow(id)) if id == "abc"));
        assert!(matches!(decode("episode:abc"), Some(NodeRef::Episode(id)) if id == "abc"));
        assert!(matches!(decode("library:abc"), Some(NodeRef::LibraryPath(id)) if id == "abc"));
    }

    #[test]
    fn a_season_carries_its_show_and_number() {
        let decoded = decode("season:abc:2");

        assert!(matches!(
            decoded,
            Some(NodeRef::Season { show_id, season_number }) if show_id == "abc" && season_number == 2
        ));
    }

    #[test]
    fn a_uuid_survives_the_prefix() {
        let uuid = "3f1b9a4e-2c7d-4f52-9a11-8d2e6c0b7f31";

        assert!(matches!(decode(&format!("movie:{uuid}")), Some(NodeRef::Movie(id)) if id == uuid));
    }

    #[test]
    fn an_unknown_prefix_is_none() {
        assert!(decode("collection:abc").is_none());
        assert!(decode("abc").is_none());
        assert!(decode("").is_none());
    }

    #[test]
    fn a_season_without_a_number_is_none() {
        assert!(decode("season:abc").is_none());
        assert!(decode("season:abc:notanumber").is_none());
    }

    #[test]
    fn an_empty_id_is_none() {
        assert!(decode("movie:").is_none());
    }
}
