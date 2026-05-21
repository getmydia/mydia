//! Blackhole adapter. Rust port of
//! `lib/mydia/downloads/client/blackhole.ex`.
//!
//! Phoenix's blackhole is a filesystem-only client: dropping a
//! `.torrent` / `.nzb` into a watch folder hands the work off to an
//! external process (seedbox, Sonarr/Radarr blackhole hooks). Once
//! the external process finishes, the bytes appear under the
//! `completed_folder` and the importer picks them up. The Rust port
//! preserves that flow — no remote API call, just `tokio::fs` writes
//! to the configured directories.

use std::path::{Path, PathBuf};

use async_trait::async_trait;
use sha1::{Digest, Sha1};

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
use crate::error::DownloadError;

const TORRENT_EXTENSION: &str = "torrent";

pub struct BlackholeClient;

#[async_trait]
impl DownloadClient for BlackholeClient {
    fn name(&self) -> &'static str {
        "blackhole"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let (watch, completed) = folders(config)?;
        validate_dir(&watch, true).await?;
        validate_dir(&completed, false).await?;
        Ok(ClientInfo {
            version: "1.0.0".into(),
            api_version: Some("filesystem".into()),
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        let (watch, _) = folders(config)?;
        let target_dir = match opts.category.as_deref() {
            Some(cat)
                if !cat.is_empty()
                    && config
                        .options
                        .get("use_category_subfolders")
                        .is_some_and(|v| v == "true") =>
            {
                watch.join(cat)
            }
            _ => watch,
        };
        tokio::fs::create_dir_all(&target_dir)
            .await
            .map_err(|e| DownloadError::fs(target_dir.clone(), e))?;

        let (bytes, hash) = match input {
            TorrentInput::File { bytes, title: _ } => {
                let hash = hex_sha1(&bytes);
                (bytes, hash)
            }
            TorrentInput::Magnet(magnet) => {
                // Magnet links land as a `.magnet` text file so the
                // external runner can pick them up — most real-world
                // operators wire qbittorrent or transmission as the
                // remote, not blackhole, for magnets; we still keep
                // the path so the adapter is fully symmetric.
                let hash = hex_sha1(magnet.as_bytes());
                (magnet.into_bytes(), hash)
            }
            TorrentInput::Url(url) => {
                return Err(DownloadError::InvalidTorrent(format!(
                    "blackhole adapter expects bytes or magnet, got URL: {url}"
                )));
            }
        };
        let filename = format!("{hash}.{TORRENT_EXTENSION}");
        let path = target_dir.join(&filename);
        tokio::fs::write(&path, &bytes)
            .await
            .map_err(|e| DownloadError::fs(path.clone(), e))?;
        Ok(hash)
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        _opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        let (watch, completed) = folders(config)?;
        let mut out = Vec::new();
        if let Ok(mut iter) = tokio::fs::read_dir(&watch).await {
            while let Ok(Some(entry)) = iter.next_entry().await {
                let path = entry.path();
                if path
                    .extension()
                    .and_then(|e| e.to_str())
                    .is_some_and(|e| e.eq_ignore_ascii_case(TORRENT_EXTENSION))
                {
                    let id = path
                        .file_stem()
                        .and_then(|s| s.to_str())
                        .unwrap_or("")
                        .to_owned();
                    out.push(DownloadStatus::skeletal(
                        id,
                        path.file_name()
                            .and_then(|n| n.to_str())
                            .unwrap_or("")
                            .to_owned(),
                        DownloadState::Downloading,
                    ));
                }
            }
        }
        if let Ok(mut iter) = tokio::fs::read_dir(&completed).await {
            while let Ok(Some(entry)) = iter.next_entry().await {
                let path = entry.path();
                let id = path
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("")
                    .to_owned();
                let mut status = DownloadStatus::skeletal(id.clone(), id, DownloadState::Completed);
                status.progress = 100.0;
                status.save_path = path.to_string_lossy().into_owned();
                out.push(status);
            }
        }
        Ok(out)
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        delete_files: bool,
    ) -> Result<(), DownloadError> {
        let (watch, completed) = folders(config)?;
        // Remove the .torrent from the watch folder.
        let stub = watch.join(format!("{client_id}.{TORRENT_EXTENSION}"));
        let _ = tokio::fs::remove_file(&stub).await; // best-effort
        if delete_files {
            let completed_path = completed.join(client_id);
            let _ = tokio::fs::remove_dir_all(&completed_path).await;
        }
        Ok(())
    }

    async fn get_files(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        let (_, completed) = folders(config)?;
        let dir = completed.join(client_id);
        let mut out = Vec::new();
        if let Ok(mut iter) = tokio::fs::read_dir(&dir).await {
            while let Ok(Some(entry)) = iter.next_entry().await {
                if let Some(name) = entry.file_name().to_str() {
                    out.push(name.to_owned());
                }
            }
        }
        Ok(out)
    }

    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError> {
        let (_, completed) = folders(config)?;
        let path = completed.join(client_id);
        if tokio::fs::metadata(&path).await.is_ok() {
            Ok(path.to_string_lossy().into_owned())
        } else {
            Err(DownloadError::NotFound(client_id.to_owned()))
        }
    }
}

fn folders(config: &ClientConfig) -> Result<(PathBuf, PathBuf), DownloadError> {
    let watch = config
        .options
        .get("watch_folder")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| DownloadError::InvalidConfig("blackhole: watch_folder required".into()))?;
    let completed = config
        .options
        .get("completed_folder")
        .filter(|s| !s.is_empty())
        .ok_or_else(|| {
            DownloadError::InvalidConfig("blackhole: completed_folder required".into())
        })?;
    Ok((PathBuf::from(watch), PathBuf::from(completed)))
}

async fn validate_dir(path: &Path, expect_writable: bool) -> Result<(), DownloadError> {
    let metadata = tokio::fs::metadata(path)
        .await
        .map_err(|e| DownloadError::fs(path.to_path_buf(), e))?;
    if !metadata.is_dir() {
        return Err(DownloadError::InvalidConfig(format!(
            "blackhole: {} is not a directory",
            path.display()
        )));
    }
    if expect_writable {
        let probe = path.join(".mydia-blackhole-probe");
        match tokio::fs::write(&probe, b"").await {
            Ok(()) => {
                let _ = tokio::fs::remove_file(&probe).await;
                Ok(())
            }
            Err(e) => Err(DownloadError::fs(path.to_path_buf(), e)),
        }
    } else {
        Ok(())
    }
}

fn hex_sha1(data: &[u8]) -> String {
    use std::fmt::Write;
    let mut hasher = Sha1::new();
    hasher.update(data);
    let digest = hasher.finalize();
    let mut out = String::with_capacity(40);
    for byte in digest {
        // `write!` against a `String` is infallible; the discard
        // matches what clippy's `format_push_string` lint expects.
        let _ = write!(out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_sha1_is_40_hex_chars() {
        let hash = hex_sha1(b"hello world");
        assert_eq!(hash.len(), 40);
        assert!(hash.chars().all(|c| c.is_ascii_hexdigit()));
        // Known SHA-1 for "hello world".
        assert_eq!(hash, "2aae6c35c94fcfb415dbe95f408b9ce91ee846ed");
    }
}
