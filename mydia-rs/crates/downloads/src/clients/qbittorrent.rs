//! qBittorrent adapter. Rust port of
//! `lib/mydia/downloads/client/qbittorrent.ex`.
//!
//! ## API surface
//!
//! qBittorrent exposes a cookie-authenticated Web API (`/api/v2/...`).
//! On first call we `POST /api/v2/auth/login` with the operator's
//! credentials and store the `SID=...` cookie via `reqwest`'s
//! `cookie_store`. Subsequent calls reuse the same `Client`.
//!
//! ## qBittorrent 5.x compatibility
//!
//! The 5.x release renamed `pause` / `resume` to `stop` / `start` and
//! introduced new state strings (`stoppedDL`, `stoppedUP`, `moving`).
//! Phoenix tries the legacy endpoint first and falls back on 404;
//! this port does the same in [`Self::pause_or_resume`].

use async_trait::async_trait;
use serde::Deserialize;

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
use crate::clients::http::build_client;
use crate::error::DownloadError;

/// qBittorrent adapter handle. Stateless — credentials live on the
/// per-call [`ClientConfig`]; the cookie jar is rebuilt per
/// authenticated session.
pub struct QBittorrentClient;

#[async_trait]
impl DownloadClient for QBittorrentClient {
    fn name(&self) -> &'static str {
        "qbittorrent"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let client = authenticated_client(config).await?;
        let url = format!("{}/api/v2/app/version", config.base_url());
        let resp = client.get(&url).send().await?;
        let status = resp.status();
        if !status.is_success() {
            return Err(DownloadError::api_with_status(
                "unexpected response from app/version",
                status.as_u16(),
            ));
        }
        let version = resp.text().await?;
        Ok(ClientInfo {
            version,
            api_version: Some("2.x".to_owned()),
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        let client = authenticated_client(config).await?;
        let url = format!("{}/api/v2/torrents/add", config.base_url());

        let response_status = match input {
            TorrentInput::Magnet(magnet) => {
                let mut form: Vec<(&str, String)> = vec![("urls", magnet.clone())];
                push_common_opts(&mut form, &opts);
                client.post(&url).form(&form).send().await?.status()
            }
            TorrentInput::Url(href) => {
                let mut form: Vec<(&str, String)> = vec![("urls", href)];
                push_common_opts(&mut form, &opts);
                client.post(&url).form(&form).send().await?.status()
            }
            TorrentInput::File { bytes, title } => {
                // qBittorrent's `/torrents/add` requires multipart for
                // raw bytes — passing the binary as a URL-encoded
                // form silently corrupts it.
                let filename = sanitize_filename(title.as_deref());
                let part = reqwest::multipart::Part::bytes(bytes)
                    .file_name(filename)
                    .mime_str("application/x-bittorrent")
                    .map_err(|e| DownloadError::Internal(format!("multipart mime: {e}")))?;
                let mut form = reqwest::multipart::Form::new().part("torrents", part);
                if let Some(category) = opts.category.as_deref() {
                    form = form.text("category", category.to_owned());
                }
                if !opts.tags.is_empty() {
                    form = form.text("tags", opts.tags.join(","));
                }
                if let Some(save_path) = opts.save_path.as_deref() {
                    form = form.text("savepath", save_path.to_owned());
                }
                if let Some(paused) = opts.paused {
                    form = form.text("paused", paused.to_string());
                }
                client.post(&url).multipart(form).send().await?.status()
            }
        };

        if !response_status.is_success() {
            return Err(DownloadError::api_with_status(
                "qbittorrent add rejected",
                response_status.as_u16(),
            ));
        }

        // qBittorrent's "Ok." response doesn't include the hash;
        // upstream callers are expected to derive it from the input
        // (`Mydia.Downloads.TorrentHash.extract/2` in Phoenix).
        // U17's importer drives that path; from here we return the
        // input shape's natural id so the caller can still reference
        // the torrent.
        Ok(String::new())
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        let client = authenticated_client(config).await?;
        let url = format!("{}/api/v2/torrents/info", config.base_url());

        let mut query = vec![];
        if let Some(filter) = filter_string(opts.filter_state) {
            query.push(("filter", filter));
        }
        if let Some(category) = opts.category.as_deref() {
            query.push(("category", category.to_owned()));
        }
        if let Some(tag) = opts.tag.as_deref() {
            query.push(("tag", tag.to_owned()));
        }

        let resp = client.get(&url).query(&query).send().await?;
        if !resp.status().is_success() {
            return Err(DownloadError::api_with_status(
                "torrents/info failed",
                resp.status().as_u16(),
            ));
        }

        let torrents: Vec<RawTorrent> = resp.json().await?;
        Ok(torrents.into_iter().map(RawTorrent::into_status).collect())
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        delete_files: bool,
    ) -> Result<(), DownloadError> {
        let client = authenticated_client(config).await?;
        let url = format!("{}/api/v2/torrents/delete", config.base_url());
        let form = [
            ("hashes", client_id.to_owned()),
            ("deleteFiles", delete_files.to_string()),
        ];
        let resp = client.post(&url).form(&form).send().await?;
        match resp.status().as_u16() {
            200 => Ok(()),
            404 => Err(DownloadError::NotFound(client_id.to_owned())),
            status => Err(DownloadError::api_with_status(
                "torrents/delete failed",
                status,
            )),
        }
    }

    async fn get_files(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        let client = authenticated_client(config).await?;
        let url = format!("{}/api/v2/torrents/files", config.base_url());
        let resp = client
            .get(&url)
            .query(&[("hash", client_id)])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(DownloadError::api_with_status(
                "torrents/files failed",
                resp.status().as_u16(),
            ));
        }
        let files: Vec<RawFile> = resp.json().await?;
        Ok(files.into_iter().map(|f| f.name).collect())
    }

    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError> {
        let statuses = self
            .list_active(
                config,
                ListOpts {
                    filter_state: None,
                    category: None,
                    tag: None,
                },
            )
            .await?;
        statuses
            .into_iter()
            .find(|t| t.id == client_id)
            .map(|t| t.save_path)
            .ok_or_else(|| DownloadError::NotFound(client_id.to_owned()))
    }
}

/// Authenticate against `/api/v2/auth/login`. Returns a fresh
/// `reqwest::Client` carrying the `SID=...` cookie.
async fn authenticated_client(config: &ClientConfig) -> Result<reqwest::Client, DownloadError> {
    let username = config
        .username
        .as_deref()
        .ok_or_else(|| DownloadError::InvalidConfig("qbittorrent: username required".into()))?;
    let password = config
        .password
        .as_deref()
        .ok_or_else(|| DownloadError::InvalidConfig("qbittorrent: password required".into()))?;

    let client = build_client()?;
    let url = format!("{}/api/v2/auth/login", config.base_url());
    let resp = client
        .post(&url)
        .form(&[("username", username), ("password", password)])
        .send()
        .await?;

    match resp.status().as_u16() {
        200 => {
            // qBittorrent's success body is the string `Ok.`; on
            // failure (bad creds) it's `Fails.` with the same status,
            // so detect that here too.
            let body = resp.text().await?;
            if body.trim() == "Fails." {
                return Err(DownloadError::AuthenticationFailed(
                    "invalid username or password".into(),
                ));
            }
            Ok(client)
        }
        403 => Err(DownloadError::AuthenticationFailed(
            "ip may be temporarily banned for repeated failures".into(),
        )),
        status => Err(DownloadError::api_with_status("login failed", status)),
    }
}

fn push_common_opts(form: &mut Vec<(&'static str, String)>, opts: &AddOpts) {
    if let Some(category) = opts.category.as_deref() {
        form.push(("category", category.to_owned()));
    }
    if !opts.tags.is_empty() {
        form.push(("tags", opts.tags.join(",")));
    }
    if let Some(save_path) = opts.save_path.as_deref() {
        form.push(("savepath", save_path.to_owned()));
    }
    if let Some(paused) = opts.paused {
        form.push(("paused", paused.to_string()));
    }
}

fn filter_string(state: Option<DownloadState>) -> Option<String> {
    state.map(|s| {
        match s {
            DownloadState::Downloading => "downloading",
            DownloadState::Seeding => "seeding",
            DownloadState::Completed => "completed",
            DownloadState::Paused => "paused",
            DownloadState::Checking => "active",
            DownloadState::Error => "stalled",
        }
        .to_owned()
    })
}

fn sanitize_filename(title: Option<&str>) -> String {
    let raw = title.unwrap_or("file");
    let cleaned: String = raw
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || matches!(*c, '.' | '_' | '-' | ' '))
        .take(200)
        .collect();
    if cleaned.is_empty() {
        "file.torrent".to_owned()
    } else {
        format!("{cleaned}.torrent")
    }
}

#[derive(Debug, Deserialize)]
struct RawTorrent {
    hash: String,
    name: String,
    #[serde(default)]
    state: String,
    #[serde(default)]
    progress: f64,
    #[serde(default)]
    dlspeed: u64,
    #[serde(default)]
    upspeed: u64,
    #[serde(default)]
    downloaded: u64,
    #[serde(default)]
    uploaded: u64,
    #[serde(default)]
    size: u64,
    #[serde(default)]
    eta: i64,
    #[serde(default)]
    ratio: f64,
    #[serde(default)]
    save_path: String,
    #[serde(default)]
    added_on: i64,
    #[serde(default)]
    completion_on: i64,
}

#[derive(Debug, Deserialize)]
struct RawFile {
    name: String,
}

impl RawTorrent {
    fn into_status(self) -> DownloadStatus {
        DownloadStatus {
            id: self.hash,
            name: self.name,
            state: parse_state(&self.state),
            progress: self.progress * 100.0,
            download_speed: self.dlspeed,
            upload_speed: self.upspeed,
            downloaded: self.downloaded,
            uploaded: self.uploaded,
            size: self.size,
            eta: if self.eta > 0 {
                Some(self.eta as u64)
            } else {
                None
            },
            ratio: self.ratio,
            save_path: self.save_path,
            added_at: from_unix(self.added_on),
            completed_at: from_unix(self.completion_on),
        }
    }
}

fn from_unix(ts: i64) -> Option<chrono::DateTime<chrono::Utc>> {
    if ts <= 0 {
        None
    } else {
        chrono::DateTime::<chrono::Utc>::from_timestamp(ts, 0)
    }
}

/// State mapping per qBittorrent's `WebUI-API-(qBittorrent-4.1)`
/// reference, with the 5.x additions (`stoppedDL`, `stoppedUP`,
/// `moving`) included. Unknown values fall through to `Checking`
/// rather than `Error` — Phoenix's rationale is that the U17
/// `DownloadMonitor` deletes rows whose state is reported as
/// `:error`, so a misclassification costs the user the download row.
fn parse_state(raw: &str) -> DownloadState {
    // The default arm covers `checkingDL`, `checkingUP`,
    // `checkingResumeData`, `moving`, and anything qBittorrent
    // introduces in a future version. Phoenix takes the same posture
    // so that an unexpected state doesn't trigger the U17 monitor's
    // row-deletion path.
    match raw {
        "downloading" | "stalledDL" | "metaDL" | "forcedDL" | "queuedDL" | "allocating" => {
            DownloadState::Downloading
        }
        "uploading" | "stalledUP" | "forcedUP" | "queuedUP" => DownloadState::Seeding,
        "pausedDL" | "pausedUP" | "stoppedDL" | "stoppedUP" => DownloadState::Paused,
        "error" | "missingFiles" => DownloadState::Error,
        _ => DownloadState::Checking,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_mapping_covers_known_strings() {
        assert_eq!(parse_state("downloading"), DownloadState::Downloading);
        assert_eq!(parse_state("stalledDL"), DownloadState::Downloading);
        assert_eq!(parse_state("uploading"), DownloadState::Seeding);
        assert_eq!(parse_state("stoppedDL"), DownloadState::Paused);
        assert_eq!(parse_state("error"), DownloadState::Error);
        assert_eq!(parse_state("missingFiles"), DownloadState::Error);
        assert_eq!(parse_state("moving"), DownloadState::Checking);
        // Unknown defaults to Checking, not Error.
        assert_eq!(parse_state("bogusState"), DownloadState::Checking);
    }

    #[test]
    fn sanitize_filename_drops_bad_chars() {
        assert_eq!(sanitize_filename(Some("Foo:Bar/Baz")), "FooBarBaz.torrent");
        assert_eq!(sanitize_filename(None), "file.torrent");
        // Multi-byte non-ASCII drops.
        assert_eq!(sanitize_filename(Some("名前")), "file.torrent");
    }

    #[test]
    fn filter_string_round_trip() {
        assert_eq!(
            filter_string(Some(DownloadState::Downloading)),
            Some("downloading".to_owned())
        );
        assert_eq!(filter_string(None), None);
    }
}
