//! `SubtitleProvider` trait.
//!
//! Rust port of the `Mydia.Subtitles.Provider` Elixir behaviour. The
//! U17 worker layer (`SubtitleDownloader`, `MovieDownloadSubtitles`)
//! takes `Arc<dyn SubtitleProvider>` so a single worker can serve any
//! provider (relay, OpenSubtitles, future providers).

use async_trait::async_trait;
use serde::{Deserialize, Serialize};

use crate::error::SubtitleError;
use crate::structs::{ProviderKind, QuotaInfo, SearchParams, SubtitleSearchResult};

/// Provider configuration. Mirrors the Elixir `provider/0` map shape;
/// credentials + options carry as JSON to stay shape-agnostic across
/// provider kinds.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ProviderConfig {
    pub id: String,
    pub user_id: Option<String>,
    pub name: String,
    pub r#type: ProviderKind,
    #[serde(default)]
    pub enabled: bool,
    pub priority: i32,
    /// Encrypted credentials in production; plaintext-shaped JSON in
    /// tests. The relay provider needs nothing; OpenSubtitles needs
    /// `api_key` (plus optionally `username`+`password`).
    #[serde(default)]
    pub credentials: serde_json::Value,
    #[serde(default)]
    pub options: serde_json::Value,
}

/// Reference to a subtitle file the caller wants to download. Returned
/// by [`SubtitleProvider::search`] in `SearchResult.file_id`; passed
/// back into [`SubtitleProvider::download`].
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SubtitleRef {
    pub file_id: String,
    pub language: String,
    pub format: String,
    #[serde(default)]
    pub subtitle_hash: String,
}

impl SubtitleRef {
    #[must_use]
    pub fn new(file_id: impl Into<String>, language: impl Into<String>) -> Self {
        Self {
            file_id: file_id.into(),
            language: language.into(),
            format: "srt".into(),
            subtitle_hash: String::new(),
        }
    }
}

/// Provider behaviour. Every implementation lives in this crate (or
/// downstream consumer crates may add their own).
#[async_trait]
pub trait SubtitleProvider: Send + Sync {
    /// Search for subtitles. The caller stores the result-stream
    /// returned by `params.file_hash` matches in the database so the
    /// repeat-download path can skip the upstream entirely.
    async fn search(
        &self,
        config: &ProviderConfig,
        params: &SearchParams,
    ) -> Result<Vec<SubtitleSearchResult>, SubtitleError>;

    /// Download a subtitle file and return the raw bytes. Format is
    /// determined by `SubtitleRef::format` (`srt`, `ass`, `vtt`).
    async fn download(
        &self,
        config: &ProviderConfig,
        subtitle: &SubtitleRef,
    ) -> Result<Vec<u8>, SubtitleError>;

    /// Quota state for the configured provider account.
    async fn quota_info(&self, config: &ProviderConfig) -> Result<QuotaInfo, SubtitleError>;

    /// Probe credentials + connectivity. Returns a free-form JSON
    /// payload that the admin UI surfaces verbatim.
    async fn validate_config(
        &self,
        config: &ProviderConfig,
    ) -> Result<serde_json::Value, SubtitleError>;
}
