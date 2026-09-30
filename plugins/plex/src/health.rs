//! check-health and the no-probe address lookup the 5 s event paths share.
//! Never rediscovers: a server that moved is reported with a confirm-endpoints
//! action once the schedule's rediscovery has parked candidates in
//! server/pending.

use crate::api;
use crate::endpoint::{self, ServerInfo};
use crate::host::Host;
use crate::http::{PlexError, PluginConfig};
use crate::store;
use mydia_plugin_sdk::types::{Health, HealthAction, HealthStatus};

/// The server address and credential link to use right now, without probing:
/// the configured URL, else the last address that worked, else the first
/// stored candidate.
pub fn quick_base(host: &mut dyn Host, cfg: &PluginConfig) -> Result<(String, String), PlexError> {
    let link = endpoint::server_link(host)?;
    if let Some(url) = cfg.url.as_deref().map(str::trim).filter(|u| !u.is_empty()) {
        return Ok((url.trim_end_matches('/').to_string(), link));
    }
    if let Some(current) = store::get_json::<serde_json::Value>(host, store::ENDPOINT_CURRENT)? {
        if let Some(url) = current.get("url").and_then(|v| v.as_str()) {
            return Ok((url.to_string(), link));
        }
    }
    if let Some(info) = store::get_json::<ServerInfo>(host, store::SERVER_INFO)? {
        if let Some(first) = info.candidates.first() {
            return Ok((first.clone(), link));
        }
    }
    Err(PlexError::Unreachable("no server address known yet".into()))
}

pub fn check(host: &mut dyn Host) -> Result<Health, String> {
    // check-health receives no config; the schedule keeps endpoint/current
    // current, including for an explicitly configured URL.
    let probe = quick_base(host, &PluginConfig::default())
        .and_then(|(base, link)| api::sections(host, &base, &link).map(|_| ()));
    Ok(match probe {
        Ok(()) => Health {
            status: HealthStatus::Ok,
            message: None,
            action: None,
        },
        Err(PlexError::Unauthorized) => Health {
            status: HealthStatus::Unauthorized,
            message: Some("Plex rejected the stored sign-in. Reconnect to sign in again.".into()),
            action: Some(HealthAction::Reconnect),
        },
        Err(e) => {
            let pending = store::get_json::<ServerInfo>(host, store::SERVER_PENDING)
                .ok()
                .flatten();
            match pending {
                Some(p) => Health {
                    status: HealthStatus::Unreachable,
                    message: Some(format!(
                        "{} moved to new addresses that need your approval.",
                        p.name
                    )),
                    action: Some(HealthAction::ConfirmEndpoints),
                },
                None => Health {
                    status: HealthStatus::Unreachable,
                    message: Some(format!("The Plex server did not answer: {}", e.message())),
                    action: None,
                },
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;
    use mydia_plugin_sdk::types::LinkRole;

    const B: &str = "http://plex.test";

    fn with_cached_endpoint() -> FakeHost {
        let mut host = FakeHost::new();
        host.with_link("owner", LinkRole::Owner, None, None);
        host.kv.insert(
            store::ENDPOINT_CURRENT.into(),
            format!(r#"{{"url":"{B}","checked_at":1}}"#),
        );
        host
    }

    #[test]
    fn quick_base_prefers_the_configured_url() {
        let mut host = with_cached_endpoint();
        let cfg = PluginConfig::parse(r#"{"url":"http://typed.test/"}"#);
        assert_eq!(
            quick_base(&mut host, &cfg).unwrap(),
            ("http://typed.test".into(), "owner".into())
        );
        assert!(host.sent.is_empty());
    }

    #[test]
    fn quick_base_falls_back_to_a_stored_candidate() {
        let mut host = FakeHost::new();
        host.with_link("owner", LinkRole::Owner, None, None);
        host.kv.insert(
            store::SERVER_INFO.into(),
            r#"{"machine_identifier":"m1","name":"Den","candidates":["http://10.0.0.5:32400"]}"#
                .into(),
        );
        assert_eq!(
            quick_base(&mut host, &PluginConfig::default()).unwrap().0,
            "http://10.0.0.5:32400"
        );
    }

    #[test]
    fn a_reachable_server_is_ok() {
        let mut host = with_cached_endpoint();
        host.respond(
            "GET",
            &format!("{B}/library/sections"),
            200,
            r#"{"MediaContainer":{}}"#,
        );
        assert_eq!(check(&mut host).unwrap().status, HealthStatus::Ok);
    }

    #[test]
    fn a_401_asks_for_reconnect() {
        let mut host = with_cached_endpoint();
        host.respond("GET", &format!("{B}/library/sections"), 401, "");
        let health = check(&mut host).unwrap();
        assert_eq!(health.status, HealthStatus::Unauthorized);
        assert_eq!(health.action, Some(HealthAction::Reconnect));
    }

    #[test]
    fn no_credential_asks_for_reconnect() {
        let mut host = FakeHost::new();
        let health = check(&mut host).unwrap();
        assert_eq!(health.status, HealthStatus::Unauthorized);
        assert_eq!(health.action, Some(HealthAction::Reconnect));
    }

    #[test]
    fn unreachable_with_pending_addresses_asks_for_confirmation() {
        let mut host = with_cached_endpoint();
        host.kv.insert(
            store::SERVER_PENDING.into(),
            r#"{"machine_identifier":"m1","name":"Den","candidates":["http://10.0.0.9:32400"]}"#
                .into(),
        );
        let health = check(&mut host).unwrap();
        assert_eq!(health.status, HealthStatus::Unreachable);
        assert_eq!(health.action, Some(HealthAction::ConfirmEndpoints));
    }

    #[test]
    fn unreachable_without_candidates_has_no_action() {
        let mut host = with_cached_endpoint();
        let health = check(&mut host).unwrap();
        assert_eq!(health.status, HealthStatus::Unreachable);
        assert_eq!(health.action, None);
    }
}
