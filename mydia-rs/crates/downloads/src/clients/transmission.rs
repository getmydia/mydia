//! Transmission adapter. Rust port of
//! `lib/mydia/downloads/client/transmission.ex`.
//!
//! ## CSRF protection
//!
//! Transmission's RPC requires an `X-Transmission-Session-Id` header.
//! When a request arrives without it (or with a stale one), the
//! server responds with `HTTP 409` and the correct session id in the
//! response headers; the client is expected to retry with that id
//! attached. The Rust port handles that in [`rpc_call`] with a
//! single one-shot retry — matching Phoenix's behaviour.
//!
//! Authentication is HTTP Basic. We let `reqwest::RequestBuilder`'s
//! `.basic_auth()` handle it; Transmission accepts the credentials
//! on every request without a separate login round-trip.

use std::sync::atomic::{AtomicU32, Ordering};

use async_trait::async_trait;
use base64::Engine;
use serde::Deserialize;
use serde_json::json;

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
use crate::clients::http::build_client;
use crate::error::DownloadError;

static TAG_COUNTER: AtomicU32 = AtomicU32::new(0);

/// Transmission adapter. Stateless apart from the global tag
/// counter; per-config credentials live on [`ClientConfig`].
pub struct TransmissionClient;

#[async_trait]
impl DownloadClient for TransmissionClient {
    fn name(&self) -> &'static str {
        "transmission"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let response = rpc_call(config, "session-get", json!({})).await?;
        let version = response
            .get("arguments")
            .and_then(|a| a.get("version"))
            .and_then(|v| v.as_str())
            .unwrap_or("unknown")
            .to_owned();
        let rpc_version = response
            .get("arguments")
            .and_then(|a| a.get("rpc-version"))
            .and_then(|v| v.as_str())
            .map(ToOwned::to_owned);
        Ok(ClientInfo {
            version,
            api_version: None,
            rpc_version,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        let mut args = serde_json::Map::new();
        match input {
            TorrentInput::Magnet(magnet) => {
                args.insert("filename".into(), json!(magnet));
            }
            TorrentInput::Url(url) => {
                args.insert("filename".into(), json!(url));
            }
            TorrentInput::File { bytes, .. } => {
                let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                args.insert("metainfo".into(), json!(encoded));
            }
        }
        if let Some(save_path) = opts.save_path.as_deref() {
            args.insert("download-dir".into(), json!(save_path));
        }
        if let Some(paused) = opts.paused {
            args.insert("paused".into(), json!(paused));
        }
        if !opts.tags.is_empty() {
            args.insert("labels".into(), json!(opts.tags));
        }

        let response = rpc_call(config, "torrent-add", json!(args)).await?;
        let result = response
            .get("result")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        if result != "success" {
            return Err(DownloadError::api(format!(
                "torrent-add: {result} ({response})"
            )));
        }
        // Either `torrent-added` (new) or `torrent-duplicate` (already
        // present) carries the hashString.
        let arguments = response
            .get("arguments")
            .ok_or_else(|| DownloadError::api("torrent-add success without arguments envelope"))?;
        let hash = arguments
            .get("torrent-added")
            .or_else(|| arguments.get("torrent-duplicate"))
            .and_then(|t| t.get("hashString"))
            .and_then(|h| h.as_str())
            .ok_or_else(|| DownloadError::api("torrent-add missing hashString"))?;
        Ok(hash.to_owned())
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        let fields = vec![
            "id",
            "hashString",
            "name",
            "status",
            "percentDone",
            "rateDownload",
            "rateUpload",
            "downloadedEver",
            "uploadedEver",
            "totalSize",
            "eta",
            "uploadRatio",
            "downloadDir",
            "addedDate",
            "doneDate",
            "labels",
        ];
        let response = rpc_call(config, "torrent-get", json!({ "fields": fields })).await?;
        let torrents = response
            .get("arguments")
            .and_then(|a| a.get("torrents"))
            .and_then(|t| t.as_array())
            .cloned()
            .unwrap_or_default();

        let mut statuses: Vec<DownloadStatus> = torrents
            .into_iter()
            .filter_map(|raw| serde_json::from_value::<RawTorrent>(raw).ok())
            .map(RawTorrent::into_status)
            .collect();

        if let Some(filter) = opts.filter_state {
            statuses.retain(|s| s.state == filter);
        }
        Ok(statuses)
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        delete_files: bool,
    ) -> Result<(), DownloadError> {
        let args = json!({
            "ids": [client_id],
            "delete-local-data": delete_files,
        });
        let response = rpc_call(config, "torrent-remove", args).await?;
        if response
            .get("result")
            .and_then(|v| v.as_str())
            .unwrap_or("")
            == "success"
        {
            Ok(())
        } else {
            Err(DownloadError::api(format!(
                "torrent-remove failed: {response}"
            )))
        }
    }

    async fn get_files(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        let response = rpc_call(
            config,
            "torrent-get",
            json!({
                "ids": [client_id],
                "fields": ["files"],
            }),
        )
        .await?;
        let files = response
            .get("arguments")
            .and_then(|a| a.get("torrents"))
            .and_then(|t| t.as_array())
            .and_then(|arr| arr.first())
            .and_then(|t| t.get("files"))
            .and_then(|f| f.as_array())
            .cloned()
            .unwrap_or_default();
        Ok(files
            .into_iter()
            .filter_map(|f| {
                f.get("name")
                    .and_then(|n| n.as_str())
                    .map(ToOwned::to_owned)
            })
            .collect())
    }

    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError> {
        let response = rpc_call(
            config,
            "torrent-get",
            json!({
                "ids": [client_id],
                "fields": ["downloadDir", "name"],
            }),
        )
        .await?;
        let torrent = response
            .get("arguments")
            .and_then(|a| a.get("torrents"))
            .and_then(|t| t.as_array())
            .and_then(|arr| arr.first())
            .cloned()
            .ok_or_else(|| DownloadError::NotFound(client_id.to_owned()))?;
        let download_dir = torrent
            .get("downloadDir")
            .and_then(|v| v.as_str())
            .unwrap_or("");
        let name = torrent.get("name").and_then(|v| v.as_str()).unwrap_or("");
        Ok(if download_dir.is_empty() {
            name.to_owned()
        } else if name.is_empty() {
            download_dir.to_owned()
        } else {
            format!("{download_dir}/{name}")
        })
    }
}

fn next_tag() -> u32 {
    TAG_COUNTER.fetch_add(1, Ordering::Relaxed)
}

/// Perform one RPC call. On `HTTP 409` (CSRF), read the new session id
/// from the response headers, attach it, and retry once. Any further
/// 409 is reported as a real error.
async fn rpc_call(
    config: &ClientConfig,
    method: &str,
    arguments: serde_json::Value,
) -> Result<serde_json::Value, DownloadError> {
    let rpc_path = config.option("rpc_path", "/transmission/rpc");
    let url = format!("{}{}", config.base_url(), rpc_path);
    let body = json!({
        "method": method,
        "arguments": arguments,
        "tag": next_tag(),
    });

    let client = build_client()?;
    let mut request = client.post(&url).json(&body);
    if let (Some(user), Some(pass)) = (config.username.as_deref(), config.password.as_deref()) {
        request = request.basic_auth(user, Some(pass));
    }
    let resp = request.send().await?;

    if resp.status().as_u16() == 409 {
        let session_id = resp
            .headers()
            .get("x-transmission-session-id")
            .and_then(|h| h.to_str().ok())
            .ok_or_else(|| DownloadError::api("409 from transmission missing session-id header"))?
            .to_owned();
        let retry = client.post(&url);
        let mut retry = retry
            .json(&body)
            .header("x-transmission-session-id", session_id);
        if let (Some(user), Some(pass)) = (config.username.as_deref(), config.password.as_deref()) {
            retry = retry.basic_auth(user, Some(pass));
        }
        let retried = retry.send().await?;
        return finalize(retried, method).await;
    }
    finalize(resp, method).await
}

async fn finalize(
    resp: reqwest::Response,
    method: &str,
) -> Result<serde_json::Value, DownloadError> {
    let status = resp.status();
    match status.as_u16() {
        200 => {
            let body: serde_json::Value = resp.json().await?;
            Ok(body)
        }
        401 => Err(DownloadError::AuthenticationFailed(
            "invalid transmission credentials".into(),
        )),
        s => Err(DownloadError::api_with_status(
            format!("transmission {method} unexpected status"),
            s,
        )),
    }
}

#[derive(Debug, Deserialize)]
struct RawTorrent {
    #[serde(rename = "hashString")]
    hash_string: String,
    #[serde(default)]
    name: String,
    #[serde(default)]
    status: i32,
    #[serde(rename = "percentDone", default)]
    percent_done: f64,
    #[serde(rename = "rateDownload", default)]
    rate_download: u64,
    #[serde(rename = "rateUpload", default)]
    rate_upload: u64,
    #[serde(rename = "downloadedEver", default)]
    downloaded_ever: u64,
    #[serde(rename = "uploadedEver", default)]
    uploaded_ever: u64,
    #[serde(rename = "totalSize", default)]
    total_size: u64,
    #[serde(default)]
    eta: i64,
    #[serde(rename = "uploadRatio", default)]
    upload_ratio: f64,
    #[serde(rename = "downloadDir", default)]
    download_dir: String,
    #[serde(rename = "addedDate", default)]
    added_date: i64,
    #[serde(rename = "doneDate", default)]
    done_date: i64,
}

impl RawTorrent {
    fn into_status(self) -> DownloadStatus {
        let save_path = if self.download_dir.is_empty() {
            String::new()
        } else if self.name.is_empty() {
            self.download_dir.clone()
        } else {
            format!("{}/{}", self.download_dir, self.name)
        };
        DownloadStatus {
            id: self.hash_string,
            name: self.name,
            state: parse_state(self.status),
            progress: self.percent_done * 100.0,
            download_speed: self.rate_download,
            upload_speed: self.rate_upload,
            downloaded: self.downloaded_ever,
            uploaded: self.uploaded_ever,
            size: self.total_size,
            eta: if self.eta >= 0 {
                Some(self.eta as u64)
            } else {
                None
            },
            ratio: self.upload_ratio,
            save_path,
            added_at: from_unix(self.added_date),
            completed_at: from_unix(self.done_date),
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

/// Map Transmission's numeric status codes to our internal states.
/// Status 0 (stopped) is `:paused`; 1 / 2 (verify queue / verify) are
/// `:checking`; 3 / 4 are `:downloading`; 5 / 6 are `:seeding`.
fn parse_state(status: i32) -> DownloadState {
    match status {
        0 => DownloadState::Paused,
        1 | 2 => DownloadState::Checking,
        3 | 4 => DownloadState::Downloading,
        5 | 6 => DownloadState::Seeding,
        _ => DownloadState::Error,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn status_mapping() {
        assert_eq!(parse_state(0), DownloadState::Paused);
        assert_eq!(parse_state(2), DownloadState::Checking);
        assert_eq!(parse_state(4), DownloadState::Downloading);
        assert_eq!(parse_state(6), DownloadState::Seeding);
        assert_eq!(parse_state(99), DownloadState::Error);
    }

    #[test]
    fn tag_counter_increments() {
        let a = next_tag();
        let b = next_tag();
        assert_ne!(a, b);
    }
}
