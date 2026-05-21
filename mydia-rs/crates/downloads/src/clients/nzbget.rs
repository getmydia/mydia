//! `NZBGet` adapter. Rust port of
//! `lib/mydia/downloads/client/nzbget.ex`.
//!
//! `NZBGet` uses JSON-RPC 2.0 with HTTP Basic auth. Every call POSTs
//! to `<url_base>/jsonrpc` with `{ "jsonrpc": "2.0", "method": "...",
//! "params": [...], "id": N }`. Responses always carry the `result`
//! field; we surface its content as `serde_json::Value` and let
//! per-method helpers extract typed fields.

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

static REQUEST_ID: AtomicU32 = AtomicU32::new(0);

pub struct NzbgetClient;

#[async_trait]
impl DownloadClient for NzbgetClient {
    fn name(&self) -> &'static str {
        "nzbget"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Nzb]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let result = rpc_call(config, "version", json!([])).await?;
        let version = result.as_str().unwrap_or("unknown").to_owned();
        Ok(ClientInfo {
            version,
            api_version: Some("jsonrpc".into()),
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        opts: AddOpts,
    ) -> Result<String, DownloadError> {
        // append(NZBFilename, NZBContent, Category, Priority,
        //        AddToTop, AddPaused, DupeKey, DupeScore, DupeMode)
        let (filename, content_b64) = match input {
            TorrentInput::File { bytes, title } => {
                let filename = title.unwrap_or_else(|| "upload.nzb".into());
                let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                (filename, encoded)
            }
            TorrentInput::Url(url) => {
                // NZBGet supports URL append via the same method by
                // setting NZBContent to the URL itself with an empty
                // filename — operators usually fetch the file
                // upstream though.
                (String::new(), url)
            }
            TorrentInput::Magnet(_) => {
                return Err(DownloadError::InvalidTorrent(
                    "nzbget does not accept magnet links (Usenet client)".into(),
                ));
            }
        };

        let category = opts.category.unwrap_or_default();
        let priority: i64 = 0;
        let paused = opts.paused.unwrap_or(false);

        let params = json!([
            filename,
            content_b64,
            category,
            priority,
            false,   // AddToTop
            paused,  // AddPaused
            "",      // DupeKey
            0,       // DupeScore
            "FORCE", // DupeMode
        ]);
        let result = rpc_call(config, "append", params).await?;
        let id = result
            .as_i64()
            .ok_or_else(|| DownloadError::api("nzbget append did not return a numeric NZBID"))?;
        Ok(id.to_string())
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        let listgroups = rpc_call(config, "listgroups", json!([0])).await?;
        let history = rpc_call(config, "history", json!([false])).await?;

        let queue: Vec<RawGroup> = serde_json::from_value(listgroups).unwrap_or_default();
        let history: Vec<RawGroup> = serde_json::from_value(history).unwrap_or_default();

        let mut statuses: Vec<DownloadStatus> = queue
            .into_iter()
            .chain(history)
            .map(RawGroup::into_status)
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
        _delete_files: bool,
    ) -> Result<(), DownloadError> {
        let id: i64 = client_id
            .parse()
            .map_err(|_| DownloadError::api(format!("invalid nzbget id: {client_id}")))?;
        // editqueue(Command, Offset, EditText, IDs)
        let result = rpc_call(
            config,
            "editqueue",
            json!(["GroupFinalDelete", 0, "", [id]]),
        )
        .await?;
        if result.as_bool().unwrap_or(false) {
            Ok(())
        } else {
            Err(DownloadError::api("nzbget editqueue returned false"))
        }
    }

    async fn get_files(
        &self,
        _config: &ClientConfig,
        _client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        // Per-file inspection requires the `listfiles` RPC which only
        // returns active queue entries — U17 walks the on-disk
        // destination folder once `Status == "SUCCESS"`.
        Ok(vec![])
    }

    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError> {
        let id: i64 = client_id
            .parse()
            .map_err(|_| DownloadError::api(format!("invalid nzbget id: {client_id}")))?;
        let history: Vec<RawGroup> =
            serde_json::from_value(rpc_call(config, "history", json!([false])).await?)
                .unwrap_or_default();
        history
            .into_iter()
            .find(|g| g.nzb_id == id)
            .map(|g| g.dest_dir)
            .ok_or_else(|| DownloadError::NotFound(client_id.to_owned()))
    }
}

fn next_id() -> u32 {
    REQUEST_ID.fetch_add(1, Ordering::Relaxed)
}

async fn rpc_call(
    config: &ClientConfig,
    method: &str,
    params: serde_json::Value,
) -> Result<serde_json::Value, DownloadError> {
    let client = build_client()?;
    let path = config.option("rpc_path", "/jsonrpc");
    let url = format!("{}{}", config.base_url(), path);
    let body = json!({
        "jsonrpc": "2.0",
        "method": method,
        "params": params,
        "id": next_id(),
    });

    let mut request = client.post(&url).json(&body);
    if let (Some(user), Some(pass)) = (config.username.as_deref(), config.password.as_deref()) {
        request = request.basic_auth(user, Some(pass));
    }
    let resp = request.send().await?;
    if resp.status().as_u16() == 401 {
        return Err(DownloadError::AuthenticationFailed(
            "invalid nzbget credentials".into(),
        ));
    }
    if !resp.status().is_success() {
        return Err(DownloadError::api_with_status(
            format!("nzbget {method} failed"),
            resp.status().as_u16(),
        ));
    }
    let envelope: serde_json::Value = resp.json().await?;
    if let Some(error) = envelope.get("error") {
        return Err(DownloadError::api(format!("nzbget rpc error: {error}")));
    }
    envelope
        .get("result")
        .cloned()
        .ok_or_else(|| DownloadError::api("nzbget response missing result"))
}

#[derive(Debug, Deserialize)]
struct RawGroup {
    #[serde(rename = "NZBID", default)]
    nzb_id: i64,
    #[serde(rename = "NZBName", default)]
    nzb_name: String,
    #[serde(rename = "Status", default)]
    status: String,
    #[serde(rename = "FileSizeMB", default)]
    file_size_mb: u64,
    #[serde(rename = "DownloadedSizeMB", default)]
    downloaded_size_mb: u64,
    #[serde(rename = "DestDir", default)]
    dest_dir: String,
}

impl RawGroup {
    fn into_status(self) -> DownloadStatus {
        let size = self.file_size_mb.saturating_mul(1_048_576);
        let downloaded = self.downloaded_size_mb.saturating_mul(1_048_576);
        let progress = if size == 0 {
            0.0
        } else {
            (downloaded as f64 / size as f64) * 100.0
        };
        DownloadStatus {
            id: self.nzb_id.to_string(),
            name: self.nzb_name,
            state: parse_state(&self.status),
            progress,
            download_speed: 0,
            upload_speed: 0,
            downloaded,
            uploaded: 0,
            size,
            eta: None,
            ratio: 0.0,
            save_path: self.dest_dir,
            added_at: None,
            completed_at: None,
        }
    }
}

/// `NZBGet` status prefix → internal state. Unknown prefixes fall
/// through to `Checking` so the U17 monitor never deletes a row
/// over an unrecognized post-processing state.
fn parse_state(raw: &str) -> DownloadState {
    if raw.starts_with("SUCCESS") {
        DownloadState::Completed
    } else if raw.starts_with("FAILURE") || raw.starts_with("WARNING") || raw.starts_with("DELETED")
    {
        DownloadState::Error
    } else if raw.starts_with("PAUSED") {
        DownloadState::Paused
    } else if raw.starts_with("QUEUED")
        || raw.starts_with("DOWNLOADING")
        || raw.starts_with("FETCHING")
    {
        DownloadState::Downloading
    } else {
        // PP_QUEUED, LOADING_PARS, VERIFYING, REPAIRING, UNPACKING,
        // MOVING, and any new value all collapse here.
        DownloadState::Checking
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn nzbget_state_prefixes() {
        assert_eq!(parse_state("SUCCESS/GOOD"), DownloadState::Completed);
        assert_eq!(parse_state("FAILURE/CRC"), DownloadState::Error);
        assert_eq!(parse_state("DOWNLOADING"), DownloadState::Downloading);
        assert_eq!(parse_state("VERIFYING/RAR"), DownloadState::Checking);
        assert_eq!(parse_state("PAUSED"), DownloadState::Paused);
        assert_eq!(parse_state("nonsense"), DownloadState::Checking);
    }

    #[test]
    fn group_into_status_computes_progress() {
        let group = RawGroup {
            nzb_id: 7,
            nzb_name: "TestNZB".into(),
            status: "DOWNLOADING".into(),
            file_size_mb: 100,
            downloaded_size_mb: 50,
            dest_dir: "/downloads/TestNZB".into(),
        };
        let status = group.into_status();
        assert_eq!(status.id, "7");
        assert!((status.progress - 50.0).abs() < 0.0001);
    }
}
