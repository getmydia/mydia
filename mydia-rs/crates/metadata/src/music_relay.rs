//! Music metadata provider — port of
//! `lib/mydia/metadata/provider/music_relay.ex`.
//!
//! Talks to the metadata-relay's `/music/*` endpoints, which proxy
//! `MusicBrainz`, Cover Art Archive, and related services. The Elixir
//! source intentionally returns raw `body` maps (no struct shaping)
//! because U18's music story is still in flux; this port preserves
//! that by returning `serde_json::Value`. When U18's music structs
//! land (tracked in a separate unit), this module gets concrete return
//! types.

use crate::error::MetadataError;
use crate::http::HttpClient;
use crate::provider::ProviderConfig;

/// `MusicBrainz` / Cover Art Archive client. Stateless — instances are
/// safe to clone freely.
#[derive(Debug, Default, Clone)]
pub struct MusicRelay;

impl MusicRelay {
    /// Construct a new client.
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    /// Search artists by name.
    pub async fn search_artist(
        &self,
        config: &ProviderConfig,
        query: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let params = [("query", query.to_string()), ("type", "artist".to_string())];
        let client = HttpClient::new(config)?;
        let body = client.get_value("/music/search", &params, config).await?;
        Ok(body
            .get("artists")
            .cloned()
            .unwrap_or(serde_json::Value::Array(vec![])))
    }

    /// Search releases (albums / singles / etc.) by name.
    pub async fn search_release(
        &self,
        config: &ProviderConfig,
        query: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let params = [
            ("query", query.to_string()),
            ("type", "release".to_string()),
        ];
        let client = HttpClient::new(config)?;
        let body = client.get_value("/music/search", &params, config).await?;
        Ok(body
            .get("releases")
            .cloned()
            .unwrap_or(serde_json::Value::Array(vec![])))
    }

    /// Fetch a single artist by MBID.
    pub async fn get_artist(
        &self,
        config: &ProviderConfig,
        mbid: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let client = HttpClient::new(config)?;
        client
            .get_value(&format!("/music/artist/{mbid}"), &[], config)
            .await
    }

    /// Fetch a single release by MBID.
    pub async fn get_release(
        &self,
        config: &ProviderConfig,
        mbid: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let client = HttpClient::new(config)?;
        client
            .get_value(&format!("/music/release/{mbid}"), &[], config)
            .await
    }

    /// Fetch a release group by MBID.
    pub async fn get_release_group(
        &self,
        config: &ProviderConfig,
        mbid: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let client = HttpClient::new(config)?;
        client
            .get_value(&format!("/music/release-group/{mbid}"), &[], config)
            .await
    }

    /// Fetch a single recording by MBID.
    pub async fn get_recording(
        &self,
        config: &ProviderConfig,
        mbid: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let client = HttpClient::new(config)?;
        client
            .get_value(&format!("/music/recording/{mbid}"), &[], config)
            .await
    }

    /// Fetch cover art metadata for a release MBID.
    pub async fn get_cover_art(
        &self,
        config: &ProviderConfig,
        release_mbid: &str,
    ) -> Result<serde_json::Value, MetadataError> {
        let client = HttpClient::new(config)?;
        client
            .get_value(&format!("/music/cover/{release_mbid}"), &[], config)
            .await
    }
}
