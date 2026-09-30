//! Outbound request helpers shared by every Plex call.

use crate::host::Host;
use mydia_plugin_sdk::types::{HostError, OutboundRequest};
use serde::de::DeserializeOwned;
use serde::Deserialize;

/// Kept identical to the native `PlexOAuth.client_identifier/0`. Existing
/// installs hold tokens minted under this identifier.
pub const CLIENT_IDENTIFIER: &str = "mydia-media-manager";
pub const PRODUCT: &str = "Mydia";
pub const DEFAULT_PLEX_TV_BASE: &str = "https://plex.tv/api/v2";

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum PlexError {
    /// 401 or 403: the server was reached and rejected the credential.
    Unauthorized,
    NotFound,
    /// Transport failure: timeout, refused, DNS.
    Unreachable(String),
    /// The host refused the request (unapproved private endpoint, missing grant).
    Denied(String),
    Unexpected(String),
}

impl PlexError {
    pub fn message(&self) -> String {
        match self {
            PlexError::Unauthorized => "Plex rejected the credentials (401)".to_string(),
            PlexError::NotFound => "not found (404)".to_string(),
            PlexError::Unreachable(m) => format!("unreachable: {m}"),
            PlexError::Denied(m) => format!("blocked by Mydia: {m}"),
            PlexError::Unexpected(m) => m.clone(),
        }
    }
}

/// How a request is authenticated. `Token` is only for the setup window,
/// before the host has stored the credential as a link.
pub enum Auth<'a> {
    None,
    Token(&'a str),
    Link(&'a str),
}

pub fn plex_headers() -> Vec<(String, String)> {
    vec![
        ("Accept".to_string(), "application/json".to_string()),
        (
            "X-Plex-Client-Identifier".to_string(),
            CLIENT_IDENTIFIER.to_string(),
        ),
        ("X-Plex-Product".to_string(), PRODUCT.to_string()),
        (
            "X-Plex-Version".to_string(),
            env!("CARGO_PKG_VERSION").to_string(),
        ),
    ]
}

pub fn request(
    method: &str,
    url: &str,
    headers: Vec<(String, String)>,
    body: Option<String>,
) -> OutboundRequest {
    OutboundRequest {
        url: url.to_string(),
        method: method.to_string(),
        headers,
        body,
    }
}

pub fn send(
    host: &mut dyn Host,
    auth: &Auth,
    mut req: OutboundRequest,
) -> Result<String, PlexError> {
    let result = match auth {
        Auth::None => host.http_request(&req),
        Auth::Token(token) => {
            req.headers
                .push(("X-Plex-Token".to_string(), token.to_string()));
            host.http_request(&req)
        }
        Auth::Link(link_id) => host.link_request(link_id, &req),
    };

    match result {
        Ok(resp) if (200..300).contains(&resp.status) => Ok(resp.body.unwrap_or_default()),
        Ok(resp) if resp.status == 401 || resp.status == 403 => Err(PlexError::Unauthorized),
        Ok(resp) if resp.status == 404 => Err(PlexError::NotFound),
        Ok(resp) => Err(PlexError::Unexpected(format!("HTTP {}", resp.status))),
        Err(HostError::Network(m)) => Err(PlexError::Unreachable(m)),
        Err(HostError::Denied(m)) => Err(PlexError::Denied(m)),
        Err(HostError::NotFound(m)) => Err(PlexError::Unexpected(format!("host: {m}"))),
        Err(HostError::InvalidRequest(m)) => {
            Err(PlexError::Unexpected(format!("invalid request: {m}")))
        }
        Err(HostError::Internal(m)) => Err(PlexError::Unexpected(format!("host error: {m}"))),
    }
}

pub fn send_json<T: DeserializeOwned>(
    host: &mut dyn Host,
    auth: &Auth,
    req: OutboundRequest,
) -> Result<T, PlexError> {
    let body = send(host, auth, req)?;
    serde_json::from_str(&body)
        .map_err(|e| PlexError::Unexpected(format!("bad JSON from Plex: {e}")))
}

/// RFC 3986 unreserved characters pass; everything else is %XX.
pub fn encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char)
            }
            _ => out.push_str(&format!("%{:02X}", b)),
        }
    }
    out
}

pub fn query(pairs: &[(&str, String)]) -> String {
    pairs
        .iter()
        .map(|(k, v)| format!("{}={}", encode(k), encode(v)))
        .collect::<Vec<_>>()
        .join("&")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Bidirectional,
    Import,
    Export,
}

/// The injected `config` map: instance settings plus `instance_id`.
#[derive(Debug, Clone, Default, Deserialize)]
pub struct PluginConfig {
    #[serde(default)]
    pub instance_id: Option<String>,
    #[serde(default)]
    pub url: Option<String>,
    #[serde(default)]
    pub sync_watched: Option<String>,
    #[serde(default)]
    pub sync_watched_direction: Option<String>,
    #[serde(default)]
    pub plex_tv_base: Option<String>,
}

impl PluginConfig {
    pub fn parse(config_json: &str) -> PluginConfig {
        serde_json::from_str(config_json).unwrap_or_default()
    }

    pub fn plex_tv_base(&self) -> String {
        match self.plex_tv_base.as_deref().map(str::trim) {
            Some(b) if !b.is_empty() => b.trim_end_matches('/').to_string(),
            _ => DEFAULT_PLEX_TV_BASE.to_string(),
        }
    }

    pub fn sync_enabled(&self) -> bool {
        self.sync_watched.as_deref() == Some("on")
    }

    pub fn direction(&self) -> Direction {
        match self.sync_watched_direction.as_deref() {
            Some("import") => Direction::Import,
            Some("export") => Direction::Export,
            _ => Direction::Bidirectional,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;
    use mydia_plugin_sdk::types::HostError;

    #[test]
    fn a_2xx_returns_the_body() {
        let mut host = FakeHost::new();
        host.respond("GET", "https://srv/x", 200, "{\"a\":1}");
        let req = request("GET", "https://srv/x", plex_headers(), None);
        assert_eq!(send(&mut host, &Auth::None, req).unwrap(), "{\"a\":1}");
    }

    #[test]
    fn statuses_classify_like_the_native_client() {
        let mut host = FakeHost::new();
        host.respond("GET", "https://srv/401", 401, "")
            .respond("GET", "https://srv/403", 403, "")
            .respond("GET", "https://srv/404", 404, "")
            .respond("GET", "https://srv/500", 500, "");
        let mut get = |url: &str| send(&mut host, &Auth::None, request("GET", url, vec![], None));
        assert_eq!(get("https://srv/401"), Err(PlexError::Unauthorized));
        assert_eq!(get("https://srv/403"), Err(PlexError::Unauthorized));
        assert_eq!(get("https://srv/404"), Err(PlexError::NotFound));
        assert_eq!(
            get("https://srv/500"),
            Err(PlexError::Unexpected("HTTP 500".into()))
        );
    }

    #[test]
    fn host_errors_map_to_plex_errors() {
        let mut host = FakeHost::new();
        host.fail("GET", "https://srv/a", HostError::Network("timeout".into()))
            .fail(
                "GET",
                "https://srv/b",
                HostError::Denied("private address".into()),
            );
        let r = send(
            &mut host,
            &Auth::None,
            request("GET", "https://srv/a", vec![], None),
        );
        assert_eq!(r, Err(PlexError::Unreachable("timeout".into())));
        let r = send(
            &mut host,
            &Auth::None,
            request("GET", "https://srv/b", vec![], None),
        );
        assert_eq!(r, Err(PlexError::Denied("private address".into())));
    }

    #[test]
    fn token_auth_adds_the_plex_token_header_and_link_auth_uses_the_link() {
        let mut host = FakeHost::new();
        host.respond("GET", "https://plex.tv/api/v2/resources", 200, "[]");
        send(
            &mut host,
            &Auth::Token("tok"),
            request(
                "GET",
                "https://plex.tv/api/v2/resources",
                plex_headers(),
                None,
            ),
        )
        .unwrap();
        send(
            &mut host,
            &Auth::Link("link-1"),
            request(
                "GET",
                "https://plex.tv/api/v2/resources",
                plex_headers(),
                None,
            ),
        )
        .unwrap();
        assert_eq!(host.sent[0].header("X-Plex-Token"), Some("tok"));
        assert_eq!(host.sent[0].link, None);
        assert_eq!(host.sent[1].header("X-Plex-Token"), None);
        assert_eq!(host.sent[1].link.as_deref(), Some("link-1"));
    }

    #[test]
    fn plex_headers_carry_the_native_client_identifier() {
        let h = plex_headers();
        assert!(h.contains(&(
            "X-Plex-Client-Identifier".into(),
            "mydia-media-manager".into()
        )));
        assert!(h.contains(&("X-Plex-Product".into(), "Mydia".into())));
        assert!(h.contains(&("Accept".into(), "application/json".into())));
    }

    #[test]
    fn query_percent_encodes_values() {
        assert_eq!(
            query(&[
                ("path", "/media/TV Shows/Harbor Lights".to_string()),
                ("a", "1".to_string())
            ]),
            "path=%2Fmedia%2FTV%20Shows%2FHarbor%20Lights&a=1"
        );
    }

    #[test]
    fn config_reads_settings_and_defaults() {
        let c = PluginConfig::parse(
            r#"{"instance_id":"i1","sync_watched":"on","sync_watched_direction":"import","plex_tv_base":"http://127.0.0.1:4000/api/v2/"}"#,
        );
        assert_eq!(c.instance_id.as_deref(), Some("i1"));
        assert!(c.sync_enabled());
        assert_eq!(c.direction(), Direction::Import);
        assert_eq!(c.plex_tv_base(), "http://127.0.0.1:4000/api/v2");

        let d = PluginConfig::parse("not json");
        assert!(!d.sync_enabled());
        assert_eq!(d.direction(), Direction::Bidirectional);
        assert_eq!(d.plex_tv_base(), DEFAULT_PLEX_TV_BASE);
    }
}
