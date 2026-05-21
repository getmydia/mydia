//! `rTorrent` adapter. Rust port of
//! `lib/mydia/downloads/client/rtorrent.ex`.
//!
//! rTorrent exposes XML-RPC at `/RPC2` (configurable). The Rust port
//! hand-rolls the request envelope (the wire format is tiny — a
//! `<methodCall>` wrapping `<methodName>` and `<params>` with
//! `<value>` leaves) rather than pulling in a full XML-RPC crate.
//! Responses are parsed leniently with `quick-xml`-style cursor logic
//! built on top of `str::find` — we only care about the leaf
//! `<string>` / `<i4>` / `<double>` values, not the full element tree.
//!
//! ## Scope note
//!
//! Phoenix's `Mydia.Downloads.Client.Rtorrent` is 645 LOC and includes
//! per-field decoders for the full `d.multicall2` response. This port
//! covers the same surface area used by the U17 `DownloadMonitor`
//! cron worker (`add_torrent`, `list_torrents`, `cancel`,
//! `get_save_path`) plus the connection test. Adapter polish (HTTP
//! Basic, custom views) is plumbed through but not exercised by the
//! integration tests yet — when U17 wires the cron worker it will
//! drive the remaining edges.

use async_trait::async_trait;
use base64::Engine;

use crate::adapter::{
    AddOpts, ClientConfig, ClientInfo, DownloadClient, DownloadState, DownloadStatus, ListOpts,
    Protocol, TorrentInput,
};
use crate::clients::http::build_client;
use crate::error::DownloadError;

pub struct RtorrentClient;

#[async_trait]
impl DownloadClient for RtorrentClient {
    fn name(&self) -> &'static str {
        "rtorrent"
    }

    fn supported_protocols(&self) -> &'static [Protocol] {
        &[Protocol::Torrent]
    }

    async fn test_connection(&self, config: &ClientConfig) -> Result<ClientInfo, DownloadError> {
        let body = xmlrpc_call(config, "system.client_version", &[]).await?;
        let version = extract_string(&body).unwrap_or_else(|| "unknown".to_owned());
        Ok(ClientInfo {
            version,
            api_version: None,
            rpc_version: None,
        })
    }

    async fn add(
        &self,
        config: &ClientConfig,
        input: TorrentInput,
        _opts: AddOpts,
    ) -> Result<String, DownloadError> {
        match input {
            TorrentInput::Magnet(magnet) => {
                let body = xmlrpc_call(
                    config,
                    "load.start",
                    &[XmlValue::Str(""), XmlValue::Str(&magnet)],
                )
                .await?;
                let _ = body;
                // rTorrent's `load.start` returns 0 on success and we
                // don't get the hash back; U17 derives it from the
                // input bytes / magnet upstream.
                Ok(String::new())
            }
            TorrentInput::Url(url) => {
                let body = xmlrpc_call(
                    config,
                    "load.start",
                    &[XmlValue::Str(""), XmlValue::Str(&url)],
                )
                .await?;
                let _ = body;
                Ok(String::new())
            }
            TorrentInput::File { bytes, .. } => {
                let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                let body = xmlrpc_call(
                    config,
                    "load.raw_start",
                    &[XmlValue::Str(""), XmlValue::Base64(&encoded)],
                )
                .await?;
                let _ = body;
                Ok(String::new())
            }
        }
    }

    async fn list_active(
        &self,
        config: &ClientConfig,
        _opts: ListOpts,
    ) -> Result<Vec<DownloadStatus>, DownloadError> {
        // d.multicall2("", "main", "d.hash=", "d.name=", "d.state=",
        //              "d.is_active=", "d.complete=", "d.is_hash_checking=",
        //              "d.size_bytes=", "d.completed_bytes=", "d.directory=")
        let body = xmlrpc_call(
            config,
            "d.multicall2",
            &[
                XmlValue::Str(""),
                XmlValue::Str("main"),
                XmlValue::Str("d.hash="),
                XmlValue::Str("d.name="),
                XmlValue::Str("d.state="),
                XmlValue::Str("d.is_active="),
                XmlValue::Str("d.complete="),
                XmlValue::Str("d.is_hash_checking="),
                XmlValue::Str("d.size_bytes="),
                XmlValue::Str("d.completed_bytes="),
                XmlValue::Str("d.directory="),
            ],
        )
        .await?;
        Ok(parse_multicall_rows(&body))
    }

    async fn cancel(
        &self,
        config: &ClientConfig,
        client_id: &str,
        _delete_files: bool,
    ) -> Result<(), DownloadError> {
        xmlrpc_call(config, "d.erase", &[XmlValue::Str(client_id)]).await?;
        Ok(())
    }

    async fn get_files(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<Vec<String>, DownloadError> {
        let body = xmlrpc_call(
            config,
            "f.multicall",
            &[
                XmlValue::Str(client_id),
                XmlValue::Str(""),
                XmlValue::Str("f.path="),
            ],
        )
        .await?;
        Ok(extract_all_strings(&body))
    }

    async fn get_save_path(
        &self,
        config: &ClientConfig,
        client_id: &str,
    ) -> Result<String, DownloadError> {
        let body = xmlrpc_call(config, "d.directory", &[XmlValue::Str(client_id)]).await?;
        extract_string(&body).ok_or_else(|| DownloadError::NotFound(client_id.to_owned()))
    }
}

/// XML-RPC scalar variants we need on the wire. Built as borrowed
/// references so we never have to allocate the full envelope twice.
enum XmlValue<'a> {
    Str(&'a str),
    Base64(&'a str),
}

impl XmlValue<'_> {
    fn render(&self, out: &mut String) {
        out.push_str("<param><value>");
        match self {
            XmlValue::Str(s) => {
                out.push_str("<string>");
                out.push_str(&xml_escape(s));
                out.push_str("</string>");
            }
            XmlValue::Base64(s) => {
                out.push_str("<base64>");
                out.push_str(s);
                out.push_str("</base64>");
            }
        }
        out.push_str("</value></param>");
    }
}

fn xml_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
        .replace('\'', "&apos;")
}

async fn xmlrpc_call(
    config: &ClientConfig,
    method: &str,
    params: &[XmlValue<'_>],
) -> Result<String, DownloadError> {
    let client = build_client()?;
    let rpc_path = config.option("rpc_path", "/RPC2");
    let url = format!("{}{}", config.base_url(), rpc_path);

    let mut body = String::new();
    body.push_str("<?xml version=\"1.0\"?>");
    body.push_str("<methodCall><methodName>");
    body.push_str(method);
    body.push_str("</methodName><params>");
    for value in params {
        value.render(&mut body);
    }
    body.push_str("</params></methodCall>");

    let mut request = client
        .post(&url)
        .header("content-type", "text/xml")
        .body(body);
    if let (Some(user), Some(pass)) = (config.username.as_deref(), config.password.as_deref()) {
        request = request.basic_auth(user, Some(pass));
    }
    let resp = request.send().await?;
    if resp.status().as_u16() == 401 {
        return Err(DownloadError::AuthenticationFailed(
            "invalid rtorrent credentials".into(),
        ));
    }
    if !resp.status().is_success() {
        return Err(DownloadError::api_with_status(
            format!("rtorrent {method} failed"),
            resp.status().as_u16(),
        ));
    }
    let text = resp.text().await?;
    if text.contains("<fault>") {
        return Err(DownloadError::api(format!(
            "rtorrent {method} fault: {text}"
        )));
    }
    Ok(text)
}

fn extract_string(body: &str) -> Option<String> {
    let start = body.find("<string>")?;
    let after = &body[start + "<string>".len()..];
    let end = after.find("</string>")?;
    Some(after[..end].to_owned())
}

fn extract_all_strings(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cursor = body;
    while let Some(start) = cursor.find("<string>") {
        let after = &cursor[start + "<string>".len()..];
        if let Some(end) = after.find("</string>") {
            out.push(after[..end].to_owned());
            cursor = &after[end + "</string>".len()..];
        } else {
            break;
        }
    }
    out
}

/// Parse a `d.multicall2` response into a flat row list. Each row is
/// 10 columns (hash, name, state, active, complete, `hash_checking`,
/// size, completed, directory). We pull leaf scalar values in order
/// and chunk them into rows — XML-RPC arrays-of-arrays are awkward
/// to walk without a real tree but the structure is fixed enough
/// to lean on positional decoding here.
fn parse_multicall_rows(body: &str) -> Vec<DownloadStatus> {
    let columns = 10;
    let scalars = extract_all_scalars(body);
    if scalars.len() < columns {
        return Vec::new();
    }
    scalars
        .chunks_exact(columns)
        .map(|row| {
            let hash = row[0].clone();
            let name = row[1].clone();
            let state: i32 = row[2].parse().unwrap_or(0);
            let is_active: i32 = row[3].parse().unwrap_or(0);
            let complete: i32 = row[4].parse().unwrap_or(0);
            let is_hash_checking: i32 = row[5].parse().unwrap_or(0);
            let size: u64 = row[6].parse().unwrap_or(0);
            let completed: u64 = row[7].parse().unwrap_or(0);
            let directory = row[8].clone();
            let progress = if size == 0 {
                0.0
            } else {
                (completed as f64 / size as f64) * 100.0
            };
            DownloadStatus {
                id: hash,
                name,
                state: derive_state(state, is_active, complete, is_hash_checking),
                progress,
                download_speed: 0,
                upload_speed: 0,
                downloaded: completed,
                uploaded: 0,
                size,
                eta: None,
                ratio: 0.0,
                save_path: directory,
                added_at: None,
                completed_at: None,
            }
        })
        .collect()
}

fn extract_all_scalars(body: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut cursor = body;
    loop {
        let candidates = ["<string>", "<i4>", "<i8>", "<int>", "<boolean>", "<double>"];
        let next = candidates
            .iter()
            .filter_map(|tag| cursor.find(tag).map(|idx| (idx, *tag)))
            .min_by_key(|(idx, _)| *idx);
        let Some((start, tag)) = next else { break };
        let after = &cursor[start + tag.len()..];
        let close_tag = format!("</{}", &tag[1..]);
        let Some(end) = after.find(close_tag.as_str()) else {
            break;
        };
        out.push(after[..end].to_owned());
        cursor = &after[end + close_tag.len() + 1..];
    }
    out
}

fn derive_state(state: i32, is_active: i32, complete: i32, is_hash_checking: i32) -> DownloadState {
    if is_hash_checking == 1 {
        DownloadState::Checking
    } else if state == 1 && is_active == 1 && complete == 0 {
        DownloadState::Downloading
    } else if state == 1 && is_active == 1 && complete == 1 {
        DownloadState::Seeding
    } else if state == 0 && complete == 1 {
        DownloadState::Completed
    } else if state == 0 {
        DownloadState::Paused
    } else {
        DownloadState::Checking
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn extract_string_from_simple_envelope() {
        let body = r#"<?xml version="1.0"?>
        <methodResponse><params><param><value>
            <string>0.9.8</string>
        </value></param></params></methodResponse>"#;
        assert_eq!(extract_string(body).as_deref(), Some("0.9.8"));
    }

    #[test]
    fn xml_escape_rejects_xml_special_chars() {
        assert_eq!(xml_escape("<a&b>"), "&lt;a&amp;b&gt;");
    }

    #[test]
    fn state_derivation_matches_phoenix() {
        assert_eq!(
            derive_state(1, 1, 0, 0),
            DownloadState::Downloading,
            "started + active + incomplete"
        );
        assert_eq!(
            derive_state(1, 1, 1, 0),
            DownloadState::Seeding,
            "started + active + complete"
        );
        assert_eq!(
            derive_state(0, 0, 0, 0),
            DownloadState::Paused,
            "stopped + incomplete"
        );
        assert_eq!(
            derive_state(0, 0, 1, 0),
            DownloadState::Completed,
            "stopped + complete"
        );
        assert_eq!(
            derive_state(0, 0, 0, 1),
            DownloadState::Checking,
            "hash check beats other signals"
        );
    }

    #[test]
    fn extract_all_scalars_walks_tags() {
        let body = "<value><string>foo</string></value><value><i4>42</i4></value>";
        assert_eq!(
            extract_all_scalars(body),
            vec!["foo".to_owned(), "42".to_owned()]
        );
    }
}
