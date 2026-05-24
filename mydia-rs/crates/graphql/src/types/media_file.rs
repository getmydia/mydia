//! Media file — port of `lib/mydia_web/schema/common_types.ex:15-51`.
//!
//! The Phoenix type computes `stream_url` and `direct_play_url` as
//! `/api/v1/stream/file/<id>` strings (plus a `strategy=DIRECT_PLAY`
//! query string for the direct-play variant). The `subtitles` field
//! delegates to `SubtitleResolver.list_subtitles/3` — that resolver
//! ports in U14, so for U10 the `subtitles` field is omitted and
//! lands alongside the subtitles port.
//!
//! `direct_play_supported` is hardcoded to `true` on the Phoenix side
//! (TODO: "implement based on client capabilities") — mirrored here.

use async_graphql::{ComplexObject, SimpleObject};

use crate::node_id::{NodeId, NodeRef};
use crate::types::SubtitleTrack;

#[derive(Debug, Clone, SimpleObject)]
#[graphql(name = "MediaFile", complex)]
pub struct MediaFile {
    /// Underlying DB row ID — kept separately from the GraphQL
    /// `id` field because Absinthe emits raw UUIDs for media files
    /// (no node-id wrapping), so we expose the plain UUID string.
    pub id: String,
    pub resolution: Option<String>,
    pub codec: Option<String>,
    pub audio_codec: Option<String>,
    pub hdr_format: Option<String>,
    pub size: Option<i64>,
    pub bitrate: Option<i64>,
}

#[ComplexObject]
impl MediaFile {
    /// Whether the file can be direct-played. Phoenix hardcodes
    /// `true` pending client-capabilities work.
    async fn direct_play_supported(&self) -> bool {
        true
    }

    /// Streaming URL — `/api/v1/stream/file/<id>`.
    async fn stream_url(&self) -> String {
        format!("/api/v1/stream/file/{}", self.id)
    }

    /// Direct play URL.
    async fn direct_play_url(&self) -> String {
        format!("/api/v1/stream/file/{}?strategy=DIRECT_PLAY", self.id)
    }

    /// Available subtitle tracks (embedded + external). U21 lights up
    /// the real extractor; U14 returns an empty list so the schema
    /// contract holds for the parity replay harness.
    async fn subtitles(&self) -> Vec<SubtitleTrack> {
        Vec::new()
    }
}

impl MediaFile {
    /// Build from the row model. The Rust DB model stores UUID as
    /// `UuidText`; the GraphQL surface emits the plain hyphenated
    /// hex form. `bitrate` is `i32` in the entity (matches Postgres'
    /// `integer`) and surfaced as `i64` in the GraphQL schema.
    pub fn from_row(row: &mydia_rs_entities::media_files::Model) -> Self {
        Self {
            id: row.id.0.to_string(),
            resolution: row.resolution.clone(),
            codec: row.codec.clone(),
            audio_codec: row.audio_codec.clone(),
            hdr_format: row.hdr_format.clone(),
            size: row.size,
            bitrate: row.bitrate.map(i64::from),
        }
    }

    /// Encode this file's global node ID for the rare cases where it
    /// appears as a Node interface implementor. Phoenix doesn't
    /// expose `MediaFile` through the Node interface today, but the
    /// helper keeps the encoding consistent if that changes.
    pub fn node_id(&self) -> String {
        NodeId::Movie(NodeRef::Str(self.id.clone())).encode()
    }
}
