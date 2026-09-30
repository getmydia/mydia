//! Resolves a working base URL for the instance's server.
//!
//! Candidates are probed one at a time (the guest has no concurrency) in the
//! order most likely to answer quickly, capped at `MAX_PROBES`. The winner is
//! cached in the store for `CACHE_TTL_SECS`. When every candidate fails,
//! plex.tv is asked for the server's current addresses; new addresses that the
//! host refuses (not approved) are parked in `server/pending` for the operator.

use crate::host::Host;
use crate::http::{Auth, PlexError, PluginConfig};
use crate::plextv::{self, Connection};
use crate::store;
use mydia_plugin_sdk::types::{Endpoint, LinkRole};
use serde::{Deserialize, Serialize};

pub const MAX_PROBES: usize = 6;
pub const CACHE_TTL_SECS: i64 = 600;
const PROBE_PATH: &str = "/library/sections";

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ServerInfo {
    pub machine_identifier: Option<String>,
    pub name: String,
    pub candidates: Vec<String>,
}

#[derive(Debug, Serialize, Deserialize)]
struct Cached {
    url: String,
    checked_at: i64,
}

pub fn endpoint_of(uri: &str) -> Option<Endpoint> {
    let (scheme, rest) = uri.split_once("://")?;
    let scheme = scheme.to_ascii_lowercase();
    let default_port = match scheme.as_str() {
        "http" => 80,
        "https" => 443,
        _ => return None,
    };
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    if authority.contains('@') || authority.contains(' ') {
        return None;
    }
    let (host, port) = match authority.rsplit_once(':') {
        Some((h, p)) if !h.ends_with(']') || h.starts_with('[') => (h, p.parse::<u16>().ok()?),
        _ => (authority, default_port),
    };
    if host.is_empty() {
        return None;
    }
    Some(Endpoint {
        scheme,
        host: host.to_ascii_lowercase(),
        port,
    })
}

pub fn order_candidates(connections: &[Connection]) -> Vec<String> {
    let mut sorted: Vec<&Connection> = connections.iter().collect();
    // Local non-relay first, then remote non-relay, then relay; https before http.
    sorted.sort_by_key(|c| (c.relay, !c.local, !c.uri.starts_with("https://")));
    let mut out: Vec<String> = Vec::new();
    for c in sorted {
        let uri = c.uri.trim_end_matches('/').to_string();
        if endpoint_of(&uri).is_some() && !out.contains(&uri) {
            out.push(uri);
        }
    }
    out
}

fn link_with_role(host: &mut dyn Host, role: LinkRole) -> Result<Option<String>, PlexError> {
    let links = host
        .links_list()
        .map_err(|e| PlexError::Unexpected(format!("links-list: {e:?}")))?;
    Ok(links.into_iter().find(|l| l.role == role).map(|l| l.id))
}

pub fn owner_link(host: &mut dyn Host) -> Result<String, PlexError> {
    link_with_role(host, LinkRole::Owner)?.ok_or(PlexError::Unauthorized)
}

/// The endpoint credential when setup stored one (shared servers), else the owner's.
pub fn server_link(host: &mut dyn Host) -> Result<String, PlexError> {
    match link_with_role(host, LinkRole::Endpoint)? {
        Some(id) => Ok(id),
        None => owner_link(host),
    }
}

fn probe(host: &mut dyn Host, base: &str, link_id: &str) -> Result<(), PlexError> {
    let url = format!("{}{PROBE_PATH}", base.trim_end_matches('/'));
    let req = crate::http::request("GET", &url, crate::http::plex_headers(), None);
    crate::http::send(host, &Auth::Link(link_id), req).map(|_| ())
}

pub fn probe_all(
    host: &mut dyn Host,
    candidates: &[String],
    link_id: &str,
) -> Result<String, PlexError> {
    let mut last = PlexError::Unreachable("no connection candidates configured".into());
    let mut denied: Option<PlexError> = None;
    for uri in candidates.iter().take(MAX_PROBES) {
        match probe(host, uri, link_id) {
            Ok(()) => return Ok(uri.trim_end_matches('/').to_string()),
            // Reached a Plex server and it refused us: another address will not help.
            Err(PlexError::Unauthorized) => return Err(PlexError::Unauthorized),
            // Kept distinct: the host refused the address, it did not fail to answer.
            Err(e @ PlexError::Denied(_)) => denied = Some(e),
            Err(e) => last = e,
        }
    }
    Err(denied.unwrap_or(last))
}

/// A refused address reads as unreachable to callers that only report health.
fn refused_as_unreachable(e: PlexError) -> PlexError {
    match e {
        PlexError::Denied(m) => PlexError::Unreachable(format!("address not approved: {m}")),
        other => other,
    }
}

fn remember(host: &mut dyn Host, url: &str) -> Result<(), PlexError> {
    let now = host.now();
    store::put_json(
        host,
        store::ENDPOINT_CURRENT,
        &Cached {
            url: url.to_string(),
            checked_at: now,
        },
    )
}

pub fn resolve(host: &mut dyn Host, config: &PluginConfig) -> Result<String, PlexError> {
    let link = server_link(host)?;

    // An explicit URL is the operator's override and is probed exactly as typed.
    if let Some(url) = config
        .url
        .as_deref()
        .map(str::trim)
        .filter(|u| !u.is_empty())
    {
        let url = url.trim_end_matches('/').to_string();
        probe(host, &url, &link)?;
        return Ok(url);
    }

    if let Some(cached) = store::get_json::<Cached>(host, store::ENDPOINT_CURRENT)? {
        if host.now() - cached.checked_at < CACHE_TTL_SECS {
            return Ok(cached.url);
        }
    }

    let info: ServerInfo = store::get_json(host, store::SERVER_INFO)?
        .ok_or_else(|| PlexError::Unexpected("no server chosen; run setup".into()))?;

    match probe_all(host, &info.candidates, &link) {
        Ok(url) => {
            remember(host, &url)?;
            Ok(url)
        }
        Err(PlexError::Unauthorized) => Err(PlexError::Unauthorized),
        Err(first_error) => match rediscover(host, config, &info, &link)? {
            Some(url) => Ok(url),
            None => Err(refused_as_unreachable(first_error)),
        },
    }
}

/// Asks plex.tv for the server's current addresses. Adopts them when one
/// answers; otherwise parks them in `server/pending` for operator approval.
fn rediscover(
    host: &mut dyn Host,
    config: &PluginConfig,
    info: &ServerInfo,
    link: &str,
) -> Result<Option<String>, PlexError> {
    let Some(machine) = info.machine_identifier.clone() else {
        return Ok(None);
    };
    let owner = owner_link(host)?;
    let servers = match plextv::resources(host, &config.plex_tv_base(), &Auth::Link(&owner)) {
        Ok(s) => s,
        Err(e) => {
            host.log(
                "warn",
                &format!("plex: rediscovery failed: {}", e.message()),
            );
            return Ok(None);
        }
    };
    let Some(server) = servers
        .into_iter()
        .find(|s| s.machine_identifier == machine)
    else {
        host.log(
            "warn",
            &format!("plex: server {machine} is no longer on this account"),
        );
        return Ok(None);
    };
    let candidates = order_candidates(&server.connections);
    if candidates == info.candidates {
        return Ok(None);
    }
    let updated = ServerInfo {
        machine_identifier: Some(machine),
        name: server.name,
        candidates,
    };
    match probe_all(host, &updated.candidates, link) {
        Ok(url) => {
            store::put_json(host, store::SERVER_INFO, &updated)?;
            store::delete(host, store::SERVER_PENDING)?;
            remember(host, &url)?;
            Ok(Some(url))
        }
        // Only addresses the host refused wait for the operator; addresses that
        // simply did not answer are reported as unreachable without parking.
        Err(PlexError::Denied(_)) => {
            store::put_json(host, store::SERVER_PENDING, &updated)?;
            Err(PlexError::Unreachable(format!(
                "{} moved to new addresses that need approval",
                updated.name
            )))
        }
        Err(_) => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;
    use crate::http::PluginConfig;
    use crate::plextv::Connection;
    use crate::store;
    use mydia_plugin_sdk::types::{HostError, LinkRole};

    fn conn(uri: &str, local: bool, relay: bool) -> Connection {
        Connection {
            uri: uri.into(),
            local,
            relay,
            protocol: None,
        }
    }

    fn seeded() -> FakeHost {
        let mut host = FakeHost::new();
        host.with_link("owner", LinkRole::Owner, None, None);
        host.with_link("srv", LinkRole::Endpoint, None, None);
        host
    }

    fn info(candidates: &[&str]) -> ServerInfo {
        ServerInfo {
            machine_identifier: Some("m1".into()),
            name: "Den".into(),
            candidates: candidates.iter().map(|s| s.to_string()).collect(),
        }
    }

    #[test]
    fn endpoint_of_reads_scheme_host_and_port_with_defaults() {
        let e = endpoint_of("https://1-2-3-4.abc.plex.direct:32400/").unwrap();
        assert_eq!(
            (e.scheme.as_str(), e.host.as_str(), e.port),
            ("https", "1-2-3-4.abc.plex.direct", 32400)
        );
        let e = endpoint_of("http://192.168.1.20").unwrap();
        assert_eq!(e.port, 80);
        let e = endpoint_of("https://plex.example.org").unwrap();
        assert_eq!(e.port, 443);
        assert!(endpoint_of("ftp://x").is_none());
        assert!(endpoint_of("not a url").is_none());
        assert!(endpoint_of("http://:32400").is_none());
    }

    #[test]
    fn candidates_prefer_local_then_remote_then_relay_https_first() {
        let order = order_candidates(&[
            conn("https://relay.plex.direct:8443", false, true),
            conn("http://203.0.113.5:32400", false, false),
            conn("http://192.168.1.20:32400", true, false),
            conn("https://192-168-1-20.m1.plex.direct:32400", true, false),
            conn("http://192.168.1.20:32400", true, false),
        ]);
        assert_eq!(
            order,
            vec![
                "https://192-168-1-20.m1.plex.direct:32400",
                "http://192.168.1.20:32400",
                "http://203.0.113.5:32400",
                "https://relay.plex.direct:8443",
            ]
        );
    }

    #[test]
    fn server_link_prefers_the_endpoint_credential() {
        let mut host = seeded();
        assert_eq!(server_link(&mut host).unwrap(), "srv");
        let mut owner_only = FakeHost::new();
        owner_only.with_link("owner", LinkRole::Owner, None, None);
        assert_eq!(server_link(&mut owner_only).unwrap(), "owner");
        assert_eq!(
            server_link(&mut FakeHost::new()),
            Err(PlexError::Unauthorized)
        );
    }

    #[test]
    fn probe_all_stops_at_the_first_working_candidate() {
        let mut host = seeded();
        host.fail(
            "GET",
            "http://a:1/library/sections",
            HostError::Network("timeout".into()),
        )
        .respond("GET", "http://b:2/library/sections", 200, "{}");
        let url = probe_all(
            &mut host,
            &[
                "http://a:1".into(),
                "http://b:2".into(),
                "http://c:3".into(),
            ],
            "srv",
        )
        .unwrap();
        assert_eq!(url, "http://b:2");
        assert_eq!(host.sent.len(), 2);
        assert!(host.sent.iter().all(|s| s.link.as_deref() == Some("srv")));
    }

    #[test]
    fn a_rejected_credential_stops_probing() {
        let mut host = seeded();
        host.respond("GET", "http://a:1/library/sections", 401, "");
        let r = probe_all(
            &mut host,
            &["http://a:1".into(), "http://b:2".into()],
            "srv",
        );
        assert_eq!(r, Err(PlexError::Unauthorized));
        assert_eq!(host.sent.len(), 1);
    }

    #[test]
    fn probing_is_capped() {
        let mut host = seeded();
        let many: Vec<String> = (0..10).map(|i| format!("http://h{i}:1")).collect();
        assert!(probe_all(&mut host, &many, "srv").is_err());
        assert_eq!(host.sent.len(), MAX_PROBES);
    }

    #[test]
    fn a_fresh_cache_answers_without_requests() {
        let mut host = seeded();
        let now = host.now_value;
        store::put_json(
            &mut host,
            store::ENDPOINT_CURRENT,
            &serde_json::json!({"url": "http://b:2", "checked_at": now - 60}),
        )
        .unwrap();
        assert_eq!(
            resolve(&mut host, &PluginConfig::default()).unwrap(),
            "http://b:2"
        );
        assert!(host.sent.is_empty());
    }

    #[test]
    fn a_stale_cache_re_probes_and_is_rewritten() {
        let mut host = seeded();
        store::put_json(&mut host, store::SERVER_INFO, &info(&["http://b:2"])).unwrap();
        let now = host.now_value;
        store::put_json(
            &mut host,
            store::ENDPOINT_CURRENT,
            &serde_json::json!({"url": "http://b:2", "checked_at": now - 601}),
        )
        .unwrap();
        host.respond("GET", "http://b:2/library/sections", 200, "{}");
        assert_eq!(
            resolve(&mut host, &PluginConfig::default()).unwrap(),
            "http://b:2"
        );
        let cached: serde_json::Value = store::get_json(&mut host, store::ENDPOINT_CURRENT)
            .unwrap()
            .unwrap();
        assert_eq!(cached["checked_at"], host.now_value);
    }

    #[test]
    fn an_explicit_url_setting_wins_over_discovery() {
        let mut host = seeded();
        store::put_json(&mut host, store::SERVER_INFO, &info(&["http://b:2"])).unwrap();
        host.respond("GET", "http://manual:32400/library/sections", 200, "{}");
        let cfg = PluginConfig {
            url: Some("http://manual:32400/".into()),
            ..Default::default()
        };
        assert_eq!(resolve(&mut host, &cfg).unwrap(), "http://manual:32400");
    }

    #[test]
    fn when_every_address_fails_rediscovery_records_pending_addresses() {
        let mut host = seeded();
        store::put_json(&mut host, store::SERVER_INFO, &info(&["http://old:1"])).unwrap();
        host.fail("GET", "http://old:1/library/sections", HostError::Network("refused".into()))
            .respond("GET", "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", 200,
                r#"[{"name":"Den","clientIdentifier":"m1","provides":"server","owned":true,"presence":true,
                     "connections":[{"uri":"http://10.0.0.9:32400","local":true}]}]"#)
            .fail("GET", "http://10.0.0.9:32400/library/sections", HostError::Denied("private address not approved".into()));
        let r = resolve(&mut host, &PluginConfig::default());
        assert!(matches!(r, Err(PlexError::Unreachable(_))));
        let pending: ServerInfo = store::get_json(&mut host, store::SERVER_PENDING)
            .unwrap()
            .unwrap();
        assert_eq!(pending.candidates, vec!["http://10.0.0.9:32400"]);
        let rediscovery =
            host.requests_to("https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1");
        assert_eq!(rediscovery[0].link.as_deref(), Some("owner"));
    }

    #[test]
    fn probe_all_keeps_a_refused_address_distinct_from_an_unreachable_one() {
        let mut host = seeded();
        host.fail(
            "GET",
            "http://a:1/library/sections",
            HostError::Denied("not approved".into()),
        );
        let r = probe_all(&mut host, &["http://a:1".into()], "srv");
        assert!(matches!(r, Err(PlexError::Denied(_))));
    }

    #[test]
    fn unreachable_rediscovered_addresses_are_not_parked() {
        let mut host = seeded();
        store::put_json(&mut host, store::SERVER_INFO, &info(&["http://old:1"])).unwrap();
        host.fail(
            "GET",
            "http://old:1/library/sections",
            HostError::Network("refused".into()),
        )
        .respond(
            "GET",
            "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1",
            200,
            r#"[{"name":"Den","clientIdentifier":"m1","provides":"server","connections":[{"uri":"http://new:2","local":true}]}]"#,
        )
        .fail(
            "GET",
            "http://new:2/library/sections",
            HostError::Network("timeout".into()),
        );
        let r = resolve(&mut host, &PluginConfig::default());
        assert!(matches!(r, Err(PlexError::Unreachable(_))));
        assert!(!host.kv.contains_key(store::SERVER_PENDING));
    }

    #[test]
    fn rediscovered_addresses_that_answer_are_adopted() {
        let mut host = seeded();
        store::put_json(&mut host, store::SERVER_INFO, &info(&["http://old:1"])).unwrap();
        host.fail("GET", "http://old:1/library/sections", HostError::Network("refused".into()))
            .respond("GET", "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1", 200,
                r#"[{"name":"Den","clientIdentifier":"m1","provides":"server","connections":[{"uri":"http://old:2","local":true}]}]"#)
            .respond("GET", "http://old:2/library/sections", 200, "{}");
        assert_eq!(
            resolve(&mut host, &PluginConfig::default()).unwrap(),
            "http://old:2"
        );
        let stored: ServerInfo = store::get_json(&mut host, store::SERVER_INFO)
            .unwrap()
            .unwrap();
        assert_eq!(stored.candidates, vec!["http://old:2"]);
        assert!(!host.kv.contains_key(store::SERVER_PENDING));
    }

    #[test]
    fn a_manual_server_without_machine_id_never_rediscovers() {
        let mut host = seeded();
        store::put_json(
            &mut host,
            store::SERVER_INFO,
            &ServerInfo {
                machine_identifier: None,
                name: "m".into(),
                candidates: vec!["http://x:1".into()],
            },
        )
        .unwrap();
        host.fail(
            "GET",
            "http://x:1/library/sections",
            HostError::Network("refused".into()),
        );
        assert!(matches!(
            resolve(&mut host, &PluginConfig::default()),
            Err(PlexError::Unreachable(_))
        ));
        assert_eq!(host.sent.len(), 1);
    }
}
