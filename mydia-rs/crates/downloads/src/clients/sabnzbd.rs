//! `SABnzbd` adapter. Rust port of
//! `lib/mydia/downloads/client/sabnzbd.ex`.
//!
//! Auth is an API key passed as a query parameter (`?apikey=...`).
//! Endpoints are all under `<url_base>/api`, with the operation
//! selected by `?mode=...`. Adds use `addurl` (URL) or `addfile`
//! (multipart upload); status comes from `queue` + `history` polls.

use async_trait::async_trait;
use serde::Deserialize;

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
use crate::clients::http::build_client;
use crate::error::DownloadError;

pub struct SabnzbdClient;

#[async_trait]
impl DownloadClient for SabnzbdClient {
    fn name(&self) -> &'static str {
        "sabnzbd"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Nzb]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let api_key = require_api_key(config)?;
        let client = build_client()?;
        let url = format!("{}{}", config.base_url(), api_path(config));
        let resp = client
            .get(&url)
            .query(&[
                ("apikey", api_key.as_str()),
                ("output", "json"),
                ("mode", "version"),
            ])
            .send()
            .await?;
        if !resp.status().is_success() {
            return Err(DownloadError::api_with_status(
                "sabnzbd version failed",
                resp.status().as_u16(),
            ));
        }
        let body: serde_json::Value = resp.json().await?;
        let version = body
            .get("version")
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_owned();
        Ok(ClientInfo {
            version,
            api_version: Some("1.0".into()),
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        let api_key = require_api_key(config)?;
        let client = build_client()?;
        let url = format!("{}{}", config.base_url(), api_path(config));

        let body: serde_json::Value = match input {
            TorrentInput::Magnet(_) => {
                return Err(DownloadError::InvalidTorrent(
                    "sabnzbd does not accept magnet links (Usenet client)".into(),
                ));
            }
            TorrentInput::Url(url_str) => {
                let mut query = vec![
                    ("apikey", api_key.clone()),
                    ("output", "json".to_owned()),
                    ("mode", "addurl".to_owned()),
                    ("name", url_str),
                ];
                if let Some(category) = opts.category.as_deref() {
                    query.push(("cat", category.to_owned()));
                }
                if let Some(title) = opts.title.as_deref() {
                    query.push(("nzbname", title.to_owned()));
                }
                client.get(&url).query(&query).send().await?.json().await?
            }
            TorrentInput::File { bytes, title } => {
                let mut query = vec![
                    ("apikey", api_key.clone()),
                    ("output", "json".to_owned()),
                    ("mode", "addfile".to_owned()),
                ];
                if let Some(category) = opts.category.as_deref() {
                    query.push(("cat", category.to_owned()));
                }
                if let Some(title_str) = title.as_deref().or(opts.title.as_deref()) {
                    query.push(("nzbname", title_str.to_owned()));
                }
                let filename = title
                    .as_deref()
                    .or(opts.title.as_deref())
                    .map_or_else(|| "upload.nzb".to_owned(), |t| format!("{t}.nzb"));
                let part = reqwest::multipart::Part::bytes(bytes)
                    .file_name(filename)
                    .mime_str("application/x-nzb")
                    .map_err(|e| DownloadError::Internal(format!("nzb mime: {e}")))?;
                let form = reqwest::multipart::Form::new().part("nzbfile", part);
                client
                    .post(&url)
                    .query(&query)
                    .multipart(form)
                    .send()
                    .await?
                    .json()
                    .await?
            }
        };

        if body.get("status") == Some(&serde_json::Value::Bool(false)) {
            let message = body
                .get("error")
                .and_then(|v| v.as_str())
                .unwrap_or("sabnzbd rejected upload");
            return Err(DownloadError::api(message));
        }
        let nzo_id = body
            .get("nzo_ids")
            .and_then(|v| v.as_array())
            .and_then(|arr| arr.first())
            .and_then(|s| s.as_str())
            .ok_or_else(|| DownloadError::api("missing nzo_ids in sabnzbd response"))?;
        Ok(nzo_id.to_owned())
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        let queue = list_queue(config).await?;
        let history = list_history(config).await?;
        let mut all: Vec<DownloadStatus> = queue
            .into_iter()
            .chain(history)
            .map(RawSlot::into_status)
            .collect();
        if let Some(filter) = opts.filter_state {
            all.retain(|s| s.state == filter);
        }
        Ok(all)
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        delete_files: bool,
    ) -> Result<(), DownloadError> {
        let api_key = require_api_key(config)?;
        let client = build_client()?;
        let url = format!("{}{}", config.base_url(), api_path(config));
        let del = if delete_files { "1" } else { "0" };
        let queue_resp: serde_json::Value = client
            .get(&url)
            .query(&[
                ("apikey", api_key.as_str()),
                ("output", "json"),
                ("mode", "queue"),
                ("name", "delete"),
                ("value", client_id),
                ("del_files", del),
            ])
            .send()
            .await?
            .json()
            .await?;
        if queue_resp.get("status") == Some(&serde_json::Value::Bool(true)) {
            return Ok(());
        }
        // Fall back to history removal.
        let history_resp: serde_json::Value = client
            .get(&url)
            .query(&[
                ("apikey", api_key.as_str()),
                ("output", "json"),
                ("mode", "history"),
                ("name", "delete"),
                ("value", client_id),
                ("del_files", del),
            ])
            .send()
            .await?
            .json()
            .await?;
        if history_resp.get("status") == Some(&serde_json::Value::Bool(true)) {
            Ok(())
        } else {
            Err(DownloadError::NotFound(client_id.to_owned()))
        }
    }

    async fn get_files(
        &self,
        _config: &ClientConfig,
        _client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        // SABnzbd doesn't expose per-NZB file listings until after
        // post-processing; U17 reads the on-disk directory instead.
        Ok(vec![])
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
            .find(|s| s.id == client_id)
            .map(|s| s.save_path)
            .ok_or_else(|| DownloadError::NotFound(client_id.to_owned()))
    }
}

fn require_api_key(config: &ClientConfig) -> Result<String, DownloadError> {
    config
        .api_key
        .clone()
        .ok_or_else(|| DownloadError::InvalidConfig("sabnzbd: api key required".into()))
}

fn api_path(config: &ClientConfig) -> String {
    let base = config.url_base.as_deref().unwrap_or("");
    format!("{base}/api")
}

async fn list_queue(config: &ClientConfig) -> Result<Vec<RawSlot>, DownloadError> {
    let api_key = require_api_key(config)?;
    let client = build_client()?;
    let url = format!("{}{}", config.base_url(), api_path(config));
    let resp = client
        .get(&url)
        .query(&[
            ("apikey", api_key.as_str()),
            ("output", "json"),
            ("mode", "queue"),
        ])
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(DownloadError::api_with_status(
            "sabnzbd queue failed",
            resp.status().as_u16(),
        ));
    }
    let body: serde_json::Value = resp.json().await?;
    let slots = body
        .get("queue")
        .and_then(|q| q.get("slots"))
        .and_then(|s| s.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(slots
        .into_iter()
        .filter_map(|s| serde_json::from_value(s).ok())
        .collect())
}

async fn list_history(config: &ClientConfig) -> Result<Vec<RawSlot>, DownloadError> {
    let api_key = require_api_key(config)?;
    let client = build_client()?;
    let url = format!("{}{}", config.base_url(), api_path(config));
    let resp = client
        .get(&url)
        .query(&[
            ("apikey", api_key.as_str()),
            ("output", "json"),
            ("mode", "history"),
            ("limit", "100"),
        ])
        .send()
        .await?;
    if !resp.status().is_success() {
        return Err(DownloadError::api_with_status(
            "sabnzbd history failed",
            resp.status().as_u16(),
        ));
    }
    let body: serde_json::Value = resp.json().await?;
    let slots = body
        .get("history")
        .and_then(|q| q.get("slots"))
        .and_then(|s| s.as_array())
        .cloned()
        .unwrap_or_default();
    Ok(slots
        .into_iter()
        .filter_map(|s| serde_json::from_value(s).ok())
        .collect())
}

#[derive(Debug, Deserialize)]
struct RawSlot {
    #[serde(default)]
    nzo_id: String,
    #[serde(default)]
    filename: String,
    #[serde(default)]
    status: String,
    #[serde(default)]
    percentage: String,
    #[serde(default)]
    bytes: String,
    #[serde(default)]
    storage: String,
}

impl RawSlot {
    fn into_status(self) -> DownloadStatus {
        let progress = self.percentage.parse::<f64>().unwrap_or(0.0);
        let size = self.bytes.parse::<u64>().unwrap_or(0);
        DownloadStatus {
            id: self.nzo_id,
            name: self.filename,
            state: parse_state(&self.status),
            progress,
            download_speed: 0,
            upload_speed: 0,
            downloaded: 0,
            uploaded: 0,
            size,
            eta: None,
            ratio: 0.0,
            save_path: self.storage,
            added_at: None,
            completed_at: None,
        }
    }
}

/// `SABnzbd` status strings -> internal states. Mirrors the Phoenix
/// `parse_state/1` heads.
fn parse_state(raw: &str) -> DownloadState {
    // Unrecognized states fall through to Checking rather than
    // Error — Phoenix takes the same posture so the U17 monitor
    // doesn't delete rows over a status name we haven't seen.
    match raw {
        "Downloading" | "Fetching" | "Queued" => DownloadState::Downloading,
        "Paused" => DownloadState::Paused,
        "Completed" => DownloadState::Completed,
        "Failed" => DownloadState::Error,
        _ => DownloadState::Checking,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state_strings_map() {
        assert_eq!(parse_state("Downloading"), DownloadState::Downloading);
        assert_eq!(parse_state("Paused"), DownloadState::Paused);
        assert_eq!(parse_state("Failed"), DownloadState::Error);
        assert_eq!(parse_state("Verifying"), DownloadState::Checking);
        assert_eq!(parse_state("UnknownState"), DownloadState::Checking);
    }

    #[test]
    fn parsed_slot_state_uses_status_field() {
        let slot = RawSlot {
            nzo_id: "SABnzbd_nzo_abc".into(),
            filename: "MyShow".into(),
            status: "Downloading".into(),
            percentage: "42.5".into(),
            bytes: "104857600".into(),
            storage: "/downloads/MyShow".into(),
        };
        let status = slot.into_status();
        assert_eq!(status.id, "SABnzbd_nzo_abc");
        assert_eq!(status.state, DownloadState::Downloading);
        assert!((status.progress - 42.5).abs() < f64::EPSILON);
        assert_eq!(status.size, 104_857_600);
    }
}
