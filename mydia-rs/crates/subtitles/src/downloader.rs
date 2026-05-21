//! Subtitle download pipeline.
//!
//! Port of `lib/mydia/subtitles/downloader.ex`. The downloader fetches
//! a subtitle file from a provider, optionally verifies it against an
//! expected hash, and writes the bytes next to the matching media
//! file. The actual file-system path planning lives in U17 (the
//! `SubtitleDownloader` worker); this module is the IO-free core that
//! workers call into.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use sha2::{Digest, Sha256};
use tokio::io::AsyncWriteExt;
use tracing::{debug, warn};

use crate::error::SubtitleError;
use crate::provider::{ProviderConfig, SubtitleProvider, SubtitleRef};

/// Outcome of a single download.
#[derive(Debug, Clone)]
pub struct DownloadedSubtitle {
    pub bytes: Vec<u8>,
    pub computed_hash: String,
    pub file_id: String,
    pub language: String,
    pub format: String,
}

/// In-memory download. Verifies hash if `expected_hash` is supplied.
pub async fn download_to_memory(
    provider: Arc<dyn SubtitleProvider>,
    config: &ProviderConfig,
    subtitle: &SubtitleRef,
    expected_hash: Option<&str>,
) -> Result<DownloadedSubtitle, SubtitleError> {
    debug!(file_id = %subtitle.file_id, "downloading subtitle");
    let bytes = provider.download(config, subtitle).await?;
    let computed = hex_digest(&bytes);
    if let Some(expected) = expected_hash {
        if !expected.is_empty() && expected != computed {
            warn!(
                file_id = %subtitle.file_id,
                expected,
                computed,
                "subtitle hash mismatch"
            );
            return Err(SubtitleError::hash_mismatch(format!(
                "expected {expected}, got {computed}"
            )));
        }
    }
    Ok(DownloadedSubtitle {
        bytes,
        computed_hash: computed,
        file_id: subtitle.file_id.clone(),
        language: subtitle.language.clone(),
        format: subtitle.format.clone(),
    })
}

/// Resolve the on-disk target path for a downloaded subtitle. The
/// convention matches the Phoenix downloader: `<basename>.<lang>.<ext>`
/// sibling to the media file.
#[must_use]
pub fn resolve_target_path(media_path: impl AsRef<Path>, language: &str, format: &str) -> PathBuf {
    let media = media_path.as_ref();
    let basename = media
        .file_stem()
        .map(|s| s.to_string_lossy().into_owned())
        .unwrap_or_else(|| "subtitle".to_owned());
    let dir = media.parent().map(PathBuf::from).unwrap_or_default();
    let filename = format!("{basename}.{language}.{format}");
    dir.join(filename)
}

/// Persist a downloaded subtitle to disk. Returns the final target path.
pub async fn write_to_disk(
    downloaded: &DownloadedSubtitle,
    media_path: impl AsRef<Path>,
) -> Result<PathBuf, SubtitleError> {
    let target = resolve_target_path(&media_path, &downloaded.language, &downloaded.format);
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent)
            .await
            .map_err(|err| SubtitleError::network(format!("creating subtitle dir: {err}")))?;
    }
    let mut f = tokio::fs::File::create(&target)
        .await
        .map_err(|err| SubtitleError::network(format!("opening subtitle file: {err}")))?;
    f.write_all(&downloaded.bytes)
        .await
        .map_err(|err| SubtitleError::network(format!("writing subtitle: {err}")))?;
    Ok(target)
}

/// SHA-256 hex digest used as the canonical subtitle fingerprint.
#[must_use]
pub fn hex_digest(bytes: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(bytes);
    let result = hasher.finalize();
    let mut s = String::with_capacity(64);
    for b in result {
        s.push_str(&format!("{b:02x}"));
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn target_path_is_basename_plus_language_plus_format() {
        let p = resolve_target_path("/movies/Matrix.mkv", "en", "srt");
        assert_eq!(p, PathBuf::from("/movies/Matrix.en.srt"));
    }

    #[test]
    fn hex_digest_is_64_hex_chars() {
        let d = hex_digest(b"hello");
        assert_eq!(d.len(), 64);
        assert!(d.chars().all(|c| c.is_ascii_hexdigit()));
    }
}
