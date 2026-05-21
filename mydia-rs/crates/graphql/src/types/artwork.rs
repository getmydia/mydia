//! Artwork URLs — port of `lib/mydia_web/schema/common_types.ex:8-13`.
//!
//! All three fields are derived from metadata blobs (TMDB/TVDB image
//! paths). The resolver in U10.c populates them via the metadata
//! provider's `ImageUrl` helpers; for now the type is plain `SimpleObject`
//! so list-level queries can return artwork structs constructed
//! directly.

use async_graphql::SimpleObject;

#[derive(Debug, Clone, Default, SimpleObject)]
#[graphql(name = "Artwork")]
pub struct Artwork {
    pub poster_url: Option<String>,
    pub backdrop_url: Option<String>,
    pub thumbnail_url: Option<String>,
}
