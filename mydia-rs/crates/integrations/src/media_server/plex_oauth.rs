//! Plex OAuth PIN-pairing flow.
//!
//! Port of `lib/mydia/media_server/plex_oauth.ex`. Plex authenticates
//! third-party apps through a short-lived PIN that the user enters at
//! `https://app.plex.tv/auth#?clientID=...&code=PIN`. The flow:
//!
//! 1. [`PlexOAuth::create_pin`] — request a PIN from Plex.
//! 2. Direct the user to [`PlexOAuth::auth_url`] for that PIN.
//! 3. Poll [`PlexOAuth::check_pin`] until it returns a non-pending
//!    [`PinStatus`] (authorized, expired, or denied — though Plex
//!    only surfaces `authorized` vs `pending`/`expired`).
//! 4. Use [`PlexOAuth::list_servers`] with the resulting auth token to
//!    discover the user's servers.

use std::time::Duration;

use serde::Deserialize;

use crate::error::IntegrationError;

const PLEX_API_BASE: &str = "https://plex.tv/api/v2";
const PLEX_AUTH_BASE: &str = "https://app.plex.tv/auth#";

const CLIENT_IDENTIFIER: &str = "mydia-media-manager";
const PRODUCT_NAME: &str = "Mydia";

const DEFAULT_TIMEOUT_MS: u64 = 30_000;

/// PIN-creation response — id + display code.
#[derive(Debug, Clone, Deserialize)]
pub struct PlexPin {
    pub id: i64,
    pub code: String,
}

/// PIN-poll outcome.
#[derive(Debug, Clone)]
pub enum PinStatus {
    /// User has authorized — token is ready to use.
    Authorized { auth_token: String },
    /// User hasn't entered the code yet.
    Pending,
}

/// One server discovered via `/resources`.
#[derive(Debug, Clone)]
pub struct PlexServer {
    pub name: String,
    pub client_identifier: String,
    pub provides: String,
    pub owned: bool,
    pub presence: bool,
    pub connections: Vec<PlexConnection>,
}

#[derive(Debug, Clone)]
pub struct PlexConnection {
    pub uri: String,
    pub protocol: String,
    pub address: String,
    pub port: i32,
    pub local: bool,
    pub relay: bool,
}

#[derive(Debug, Clone)]
pub struct PlexOAuth {
    inner: reqwest::Client,
    base_url: String,
}

impl PlexOAuth {
    /// Build an OAuth client pointing at `plex.tv/api/v2`.
    pub fn new() -> Result<Self, IntegrationError> {
        Self::with_base_url(PLEX_API_BASE)
    }

    /// Override the base URL (used by tests to point at a wiremock).
    pub fn with_base_url(base_url: impl Into<String>) -> Result<Self, IntegrationError> {
        let inner = reqwest::Client::builder()
            .user_agent(format!(
                "Mydia-rs/{} ({})",
                env!("CARGO_PKG_VERSION"),
                std::env::consts::ARCH
            ))
            .timeout(Duration::from_millis(DEFAULT_TIMEOUT_MS))
            .build()?;
        Ok(Self {
            inner,
            base_url: base_url.into(),
        })
    }

    /// Build with a custom `reqwest::Client` (test-only).
    pub fn with_client(base_url: impl Into<String>, inner: reqwest::Client) -> Self {
        Self {
            inner,
            base_url: base_url.into(),
        }
    }

    /// Client identifier this app uses. Stable across versions; Plex
    /// keys pairing history off it.
    #[must_use]
    pub fn client_identifier() -> &'static str {
        CLIENT_IDENTIFIER
    }

    fn join(&self, path: &str) -> String {
        let base = self.base_url.trim_end_matches('/');
        if path.starts_with('/') {
            format!("{base}{path}")
        } else {
            format!("{base}/{path}")
        }
    }

    /// `POST /pins` — request a new PIN.
    pub async fn create_pin(&self) -> Result<PlexPin, IntegrationError> {
        let url = self.join("/pins");
        let resp = self
            .inner
            .post(&url)
            .header("Accept", "application/json")
            .form(&[
                ("strong", "true"),
                ("X-Plex-Product", PRODUCT_NAME),
                ("X-Plex-Client-Identifier", CLIENT_IDENTIFIER),
            ])
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() {
            resp.json::<PlexPin>().await.map_err(IntegrationError::from)
        } else {
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ))
        }
    }

    /// `GET /pins/<id>` — check if the user has authorized.
    pub async fn check_pin(&self, pin_id: i64) -> Result<PinStatus, IntegrationError> {
        let url = self.join(&format!("/pins/{pin_id}"));
        let resp = self
            .inner
            .get(&url)
            .header("Accept", "application/json")
            .header("X-Plex-Client-Identifier", CLIENT_IDENTIFIER)
            .send()
            .await?;
        let status = resp.status();
        if status.is_success() {
            let body: PinCheckResponse = resp.json().await?;
            match body.auth_token.as_deref() {
                None | Some("") => Ok(PinStatus::Pending),
                Some(token) => Ok(PinStatus::Authorized {
                    auth_token: token.to_owned(),
                }),
            }
        } else if status.as_u16() == 404 {
            Err(IntegrationError::pin_expired())
        } else {
            let body = resp.text().await.ok();
            Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ))
        }
    }

    /// Build the authorization URL the user visits to authorize.
    #[must_use]
    pub fn auth_url(code: &str) -> String {
        let params = url::form_urlencoded::Serializer::new(String::new())
            .append_pair("clientID", CLIENT_IDENTIFIER)
            .append_pair("code", code)
            .append_pair("context[device][product]", PRODUCT_NAME)
            .finish();
        format!("{PLEX_AUTH_BASE}?{params}")
    }

    /// `GET /resources` — list the user's servers using their auth token.
    pub async fn list_servers(
        &self,
        auth_token: &str,
    ) -> Result<Vec<PlexServer>, IntegrationError> {
        let url = self.join("/resources");
        let resp = self
            .inner
            .get(&url)
            .header("Accept", "application/json")
            .header("X-Plex-Token", auth_token)
            .header("X-Plex-Client-Identifier", CLIENT_IDENTIFIER)
            .query(&[("includeHttps", "1"), ("includeRelay", "1")])
            .send()
            .await?;
        let status = resp.status();
        if status.as_u16() == 401 {
            return Err(IntegrationError::auth_expired(
                "Invalid or expired auth token",
            ));
        }
        if !status.is_success() {
            let body = resp.text().await.ok();
            return Err(IntegrationError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ));
        }
        let body: Vec<PlexResourceRaw> = resp.json().await?;
        Ok(body
            .into_iter()
            .filter(|r| is_server_resource(r.provides.as_deref()))
            .map(parse_server)
            .collect())
    }

    /// Pick the best connection URL out of a server's connection list.
    ///
    /// Preference order:
    /// 1. Local HTTPS connections.
    /// 2. Local HTTP connections.
    /// 3. Remote HTTPS connections.
    /// 4. Remote HTTP connections.
    /// 5. Relay connections (last resort).
    #[must_use]
    pub fn best_connection_url(connections: &[PlexConnection]) -> Option<String> {
        let mut sorted: Vec<&PlexConnection> = connections.iter().collect();
        sorted.sort_by_key(|c| connection_priority(c));
        sorted.first().map(|c| c.uri.clone())
    }
}

fn connection_priority(c: &PlexConnection) -> u8 {
    match (c.local, c.protocol.as_str(), c.relay) {
        (_, _, true) => 5,
        (true, "https", _) => 1,
        (true, _, _) => 2,
        (false, "https", _) => 3,
        _ => 4,
    }
}

fn is_server_resource(provides: Option<&str>) -> bool {
    match provides {
        Some(s) => s.split(',').any(|part| part.trim() == "server"),
        None => false,
    }
}

fn parse_server(r: PlexResourceRaw) -> PlexServer {
    PlexServer {
        name: r.name.unwrap_or_default(),
        client_identifier: r.client_identifier.unwrap_or_default(),
        provides: r.provides.unwrap_or_default(),
        owned: r.owned.unwrap_or(false),
        presence: r.presence.unwrap_or(false),
        connections: r
            .connections
            .unwrap_or_default()
            .into_iter()
            .map(|c| PlexConnection {
                uri: c.uri.unwrap_or_default(),
                protocol: c.protocol.unwrap_or_default(),
                address: c.address.unwrap_or_default(),
                port: c.port.unwrap_or(0),
                local: c.local.unwrap_or(false),
                relay: c.relay.unwrap_or(false),
            })
            .collect(),
    }
}

#[derive(Debug, Deserialize)]
struct PinCheckResponse {
    #[serde(default, rename = "authToken")]
    auth_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct PlexResourceRaw {
    #[serde(default)]
    name: Option<String>,
    #[serde(default, rename = "clientIdentifier")]
    client_identifier: Option<String>,
    #[serde(default)]
    provides: Option<String>,
    #[serde(default)]
    owned: Option<bool>,
    #[serde(default)]
    presence: Option<bool>,
    #[serde(default)]
    connections: Option<Vec<PlexConnectionRaw>>,
}

#[derive(Debug, Deserialize)]
struct PlexConnectionRaw {
    #[serde(default)]
    uri: Option<String>,
    #[serde(default)]
    protocol: Option<String>,
    #[serde(default)]
    address: Option<String>,
    #[serde(default)]
    port: Option<i32>,
    #[serde(default)]
    local: Option<bool>,
    #[serde(default)]
    relay: Option<bool>,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auth_url_includes_client_id_and_code() {
        let url = PlexOAuth::auth_url("ABCD");
        assert!(url.contains(PLEX_AUTH_BASE));
        assert!(url.contains("clientID=mydia-media-manager"));
        assert!(url.contains("code=ABCD"));
    }

    #[test]
    fn is_server_resource_handles_comma_list() {
        assert!(is_server_resource(Some("server,player")));
        assert!(is_server_resource(Some("controller, server")));
        assert!(!is_server_resource(Some("player")));
        assert!(!is_server_resource(None));
    }

    #[test]
    fn best_connection_prefers_local_https() {
        let conns = vec![
            PlexConnection {
                uri: "https://remote".into(),
                protocol: "https".into(),
                address: String::new(),
                port: 0,
                local: false,
                relay: false,
            },
            PlexConnection {
                uri: "https://local".into(),
                protocol: "https".into(),
                address: String::new(),
                port: 0,
                local: true,
                relay: false,
            },
        ];
        assert_eq!(
            PlexOAuth::best_connection_url(&conns).unwrap(),
            "https://local"
        );
    }

    #[test]
    fn best_connection_falls_back_to_relay() {
        let conns = vec![PlexConnection {
            uri: "https://relay".into(),
            protocol: "https".into(),
            address: String::new(),
            port: 0,
            local: false,
            relay: true,
        }];
        assert_eq!(
            PlexOAuth::best_connection_url(&conns).unwrap(),
            "https://relay"
        );
    }

    #[test]
    fn client_identifier_is_stable() {
        assert_eq!(PlexOAuth::client_identifier(), "mydia-media-manager");
    }
}
