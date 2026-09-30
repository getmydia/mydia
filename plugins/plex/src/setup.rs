//! The setup wizard (spec 2.2) as a state machine over setup-request/screen.
//!
//! No token is ever written into `next_state_json`: the account token leaves
//! the plugin once, as the `owner` credential on the server choice, and server
//! tokens ride only on the option they belong to.

use crate::endpoint::{self, ServerInfo};
use crate::host::Host;
use crate::http::{Auth, PlexError, PluginConfig};
use crate::plextv::{self, HomeUser, PinStatus};
use crate::store;
use mydia_plugin_sdk::types::{
    ChoiceOption, ChoiceScreen, Credential, ExternalAuthScreen, FormScreen, LinkRole, LinkStatus,
    MappingScreen, RemoteAccount, ScreenBody, SetupField, SetupRequest, SetupScreen,
};
use serde::{Deserialize, Serialize};

const POLL_SECONDS: u32 = 2;

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    pin_id: Option<i64>,
    #[serde(default)]
    pin_code: Option<String>,
    #[serde(default)]
    servers: Vec<ServerChoice>,
    #[serde(default)]
    confirm_only: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct ServerChoice {
    id: String,
    name: String,
    machine_identifier: Option<String>,
    candidates: Vec<String>,
}

#[derive(Deserialize)]
struct OptionInput {
    #[serde(default)]
    option_id: String,
}

#[derive(Deserialize)]
struct ManualInput {
    #[serde(default)]
    url: String,
    #[serde(default)]
    token: String,
}

#[derive(Deserialize)]
struct MappingInput {
    #[serde(default)]
    links: Vec<MappedLink>,
}

#[derive(Deserialize)]
struct MappedLink {
    link_id: String,
    remote_account_id: String,
}

pub fn run(host: &mut dyn Host, req: &SetupRequest) -> Result<SetupScreen, String> {
    let config = PluginConfig::parse(&req.config_json);
    let state: State = serde_json::from_str(&req.state_json).unwrap_or_default();
    let base = config.plex_tv_base();

    match req.step.as_str() {
        "start" => Ok(method_screen(None)),
        "method" => Ok(on_method(host, &base, &req.input_json)),
        "poll" => Ok(on_poll(host, &base, &state)),
        "manual" => Ok(on_manual(&req.input_json)),
        "server" => Ok(on_server(host, &base, &state, &req.input_json)),
        "accounts" => {
            Ok(accounts_screen(host, &base).unwrap_or_else(|e| method_screen(Some(e.message()))))
        }
        "mapping" => on_mapping(host, &base, &req.input_json).map_err(|e| e.message()),
        "confirm-endpoints" => on_confirm_endpoints(host, &base),
        other => Err(format!("unknown setup step {other}")),
    }
}

fn screen(step: &str, body: ScreenBody, state: &State) -> SetupScreen {
    SetupScreen {
        step: step.to_string(),
        body,
        next_state_json: serde_json::to_string(state).unwrap_or_else(|_| "{}".into()),
        credentials: vec![],
        error: None,
    }
}

fn option(id: &str, label: &str, detail: Option<&str>) -> ChoiceOption {
    ChoiceOption {
        id: id.to_string(),
        label: label.to_string(),
        detail: detail.map(str::to_string),
        badge: None,
        endpoints: vec![],
        credentials: vec![],
    }
}

fn method_screen(error: Option<String>) -> SetupScreen {
    let body = ScreenBody::Choice(ChoiceScreen {
        title: "Connect a Plex server".into(),
        options: vec![
            option(
                "signin",
                "Sign in with Plex",
                Some("Recommended. Finds your servers and Plex Home profiles."),
            ),
            option(
                "manual",
                "Enter a URL and token",
                Some("For a server plex.tv cannot see."),
            ),
        ],
    });
    SetupScreen {
        error,
        ..screen("method", body, &State::default())
    }
}

fn external_auth(state: &State) -> SetupScreen {
    let code = state.pin_code.clone().unwrap_or_default();
    let body = ScreenBody::ExternalAuth(ExternalAuthScreen {
        url: plextv::auth_url(&code),
        poll_after_seconds: POLL_SECONDS,
        message: Some("Sign in to Plex in the window that opened, then come back here.".into()),
    });
    screen("poll", body, state)
}

fn on_method(host: &mut dyn Host, base: &str, input: &str) -> SetupScreen {
    let choice: OptionInput = serde_json::from_str(input).unwrap_or(OptionInput {
        option_id: String::new(),
    });
    match choice.option_id.as_str() {
        "signin" => match plextv::create_pin(host, base) {
            Ok(pin) => external_auth(&State {
                pin_id: Some(pin.id),
                pin_code: Some(pin.code),
                ..State::default()
            }),
            Err(e) => method_screen(Some(format!(
                "Could not start the Plex sign-in: {}",
                e.message()
            ))),
        },
        "manual" => manual_form(None),
        _ => method_screen(Some("Choose how to connect.".into())),
    }
}

fn manual_form(error: Option<String>) -> SetupScreen {
    let field = |key: &str, label: &str, field_type: &str| SetupField {
        key: key.into(),
        label: label.into(),
        field_type: field_type.into(),
        required: true,
        options: vec![],
        default_value: None,
    };
    let body = ScreenBody::Form(FormScreen {
        title: "Plex server address".into(),
        fields: vec![
            field(
                "url",
                "Server URL, for example http://192.168.1.20:32400",
                "url",
            ),
            field("token", "X-Plex-Token", "secret"),
        ],
    });
    SetupScreen {
        error,
        ..screen("manual", body, &State::default())
    }
}

fn on_poll(host: &mut dyn Host, base: &str, state: &State) -> SetupScreen {
    let Some(pin_id) = state.pin_id else {
        return method_screen(Some("The Plex sign-in was lost. Start again.".into()));
    };
    match plextv::check_pin(host, base, pin_id) {
        Ok(PinStatus::Pending) => external_auth(state),
        Ok(PinStatus::Expired) => {
            method_screen(Some("The Plex sign-in expired. Start again.".into()))
        }
        Ok(PinStatus::Authorized(token)) => servers_screen(host, base, &token),
        Err(e) => method_screen(Some(format!(
            "Could not check the Plex sign-in: {}",
            e.message()
        ))),
    }
}

fn servers_screen(host: &mut dyn Host, base: &str, account_token: &str) -> SetupScreen {
    let servers = match plextv::resources(host, base, &Auth::Token(account_token)) {
        Ok(s) => plextv::rank(s),
        Err(e) => {
            return method_screen(Some(format!(
                "Could not list your Plex servers: {}",
                e.message()
            )))
        }
    };
    if servers.is_empty() {
        return method_screen(Some("This Plex account has no Plex Media Server.".into()));
    }

    let recommended = recommended_id(&servers);
    let mut state = State::default();
    let mut options = Vec::new();
    for s in &servers {
        let candidates = endpoint::order_candidates(&s.connections);
        let mut credentials = Vec::new();
        if let Some(tok) = s
            .access_token
            .as_deref()
            .filter(|t| !t.is_empty() && *t != account_token)
        {
            credentials.push(Credential {
                role: LinkRole::Endpoint,
                token: tok.to_string(),
            });
        }
        let badge = match (Some(&s.machine_identifier) == recommended.as_ref(), s.owned) {
            (true, _) => "Recommended",
            (false, true) => "Owned",
            (false, false) => "Shared",
        };
        options.push(ChoiceOption {
            id: s.machine_identifier.clone(),
            label: s.name.clone(),
            detail: Some(format!(
                "{}, {} address{}",
                if s.presence { "Online" } else { "Offline" },
                candidates.len(),
                if candidates.len() == 1 { "" } else { "es" }
            )),
            badge: Some(badge.to_string()),
            endpoints: candidates
                .iter()
                .filter_map(|c| endpoint::endpoint_of(c))
                .collect(),
            credentials,
        });
        state.servers.push(ServerChoice {
            id: s.machine_identifier.clone(),
            name: s.name.clone(),
            machine_identifier: Some(s.machine_identifier.clone()),
            candidates,
        });
    }

    let body = ScreenBody::Choice(ChoiceScreen {
        title: "Choose a Plex server".into(),
        options,
    });
    SetupScreen {
        credentials: vec![Credential {
            role: LinkRole::Owner,
            token: account_token.to_string(),
        }],
        ..screen("server", body, &state)
    }
}

/// The server native `Selection.auto_select/1` would have picked silently:
/// the only server, or the only owned one.
fn recommended_id(servers: &[plextv::Server]) -> Option<String> {
    let owned: Vec<_> = servers.iter().filter(|s| s.owned).collect();
    match (servers.len(), owned.len()) {
        (1, _) => Some(servers[0].machine_identifier.clone()),
        (_, 1) => Some(owned[0].machine_identifier.clone()),
        _ => None,
    }
}

fn on_manual(input: &str) -> SetupScreen {
    let m: ManualInput = serde_json::from_str(input).unwrap_or(ManualInput {
        url: String::new(),
        token: String::new(),
    });
    let url = m.url.trim().trim_end_matches('/').to_string();
    let token = m.token.trim().to_string();
    let Some(ep) = endpoint::endpoint_of(&url) else {
        return manual_form(Some("Enter a full http:// or https:// URL.".into()));
    };
    if token.is_empty() {
        return manual_form(Some("An X-Plex-Token is required.".into()));
    }
    let state = State {
        servers: vec![ServerChoice {
            id: "manual".into(),
            name: ep.host.clone(),
            machine_identifier: None,
            candidates: vec![url.clone()],
        }],
        ..State::default()
    };
    let body = ScreenBody::Choice(ChoiceScreen {
        title: "Confirm the server".into(),
        options: vec![ChoiceOption {
            id: "manual".into(),
            label: format!("Use {url}"),
            detail: Some("Mydia will connect to this address only.".into()),
            badge: None,
            endpoints: vec![ep],
            credentials: vec![Credential {
                role: LinkRole::Owner,
                token,
            }],
        }],
    });
    screen("server", body, &state)
}

fn on_server(host: &mut dyn Host, base: &str, state: &State, input: &str) -> SetupScreen {
    let choice: OptionInput = serde_json::from_str(input).unwrap_or(OptionInput {
        option_id: String::new(),
    });
    let Some(server) = state.servers.iter().find(|s| s.id == choice.option_id) else {
        return method_screen(Some(
            "That server is no longer on offer. Start again.".into(),
        ));
    };
    let info = ServerInfo {
        machine_identifier: server.machine_identifier.clone(),
        name: server.name.clone(),
        candidates: server.candidates.clone(),
    };
    let probed = endpoint::server_link(host)
        .and_then(|link| endpoint::probe_all(host, &info.candidates, &link));
    let url = match probed {
        Ok(url) => url,
        Err(e) => {
            return method_screen(Some(format!(
                "Could not reach {}: {}",
                info.name,
                e.message()
            )))
        }
    };

    let now = host.now();
    let saved = store::put_json(host, store::SERVER_INFO, &info)
        .and_then(|_| {
            store::put_json(
                host,
                store::ENDPOINT_CURRENT,
                &serde_json::json!({"url": url, "checked_at": now}),
            )
        })
        .and_then(|_| store::delete(host, store::SERVER_PENDING));
    if let Err(e) = saved {
        return method_screen(Some(e.message()));
    }

    if state.confirm_only {
        let body = ScreenBody::Done(format!("{} is reachable again at {url}.", info.name));
        return screen("done", body, &State::default());
    }
    accounts_screen(host, base).unwrap_or_else(|e| method_screen(Some(e.message())))
}

fn accounts_screen(host: &mut dyn Host, base: &str) -> Result<SetupScreen, PlexError> {
    let owner = endpoint::owner_link(host)?;
    let me = plextv::account(host, base, &Auth::Link(&owner))?;
    let (accounts, has_home) = match plextv::home_users(host, base, &Auth::Link(&owner))? {
        Some(users) if !users.is_empty() => (users, true),
        _ => (vec![me.clone()], false),
    };
    host.kv_set(store::SERVER_OWNER_ACCOUNT, &me.uuid)
        .and_then(|_| host.kv_set(store::SERVER_HOME, if has_home { "1" } else { "0" }))
        .map_err(|e| PlexError::Unexpected(format!("store: {e:?}")))?;

    let remote: Vec<RemoteAccount> = accounts.iter().map(to_remote).collect();
    host.propose_accounts(&remote)
        .map_err(|e| PlexError::Unexpected(format!("propose-accounts: {e:?}")))?;

    let body = ScreenBody::Mapping(MappingScreen {
        title: "Match Plex profiles to Mydia users".into(),
        accounts: remote,
        suggestions: vec![],
    });
    Ok(screen("mapping", body, &State::default()))
}

fn to_remote(u: &HomeUser) -> RemoteAccount {
    RemoteAccount {
        id: u.uuid.clone(),
        name: u.name.clone(),
        admin: u.admin,
    }
}

fn on_mapping(host: &mut dyn Host, base: &str, input: &str) -> Result<SetupScreen, PlexError> {
    let input: MappingInput = serde_json::from_str(input)
        .map_err(|e| PlexError::Unexpected(format!("bad mapping input: {e}")))?;
    let owner = endpoint::owner_link(host)?;
    let has_home = host.kv_get(store::SERVER_HOME).ok().flatten().as_deref() != Some("0");
    let owner_account = host.kv_get(store::SERVER_OWNER_ACCOUNT).ok().flatten();
    let names: std::collections::HashMap<String, String> = host
        .links_list()
        .map_err(|e| PlexError::Unexpected(format!("links-list: {e:?}")))?
        .into_iter()
        .map(|l| (l.id.clone(), l.external_username.unwrap_or(l.id)))
        .collect();

    let mut linked = 0;
    let mut failed: Vec<String> = Vec::new();
    for link in &input.links {
        let status =
            if !has_home && owner_account.as_deref() == Some(link.remote_account_id.as_str()) {
                host.kv_set(&store::link_uses_owner_key(&link.link_id), "1")
                    .map_err(|e| PlexError::Unexpected(format!("store: {e:?}")))
            } else {
                let _ = host.kv_delete(&store::link_uses_owner_key(&link.link_id));
                plextv::switch_user(host, base, &owner, &link.remote_account_id).and_then(|token| {
                    host.set_link_token(&link.link_id, &token)
                        .map_err(|e| PlexError::Unexpected(format!("set-link-token: {e:?}")))
                })
            };
        match status {
            Ok(()) => {
                let _ = host.set_link_status(&link.link_id, LinkStatus::Active, None);
                linked += 1;
            }
            Err(e) => {
                host.log(
                    "warn",
                    &format!(
                        "plex: could not mint a token for link {}: {}",
                        link.link_id,
                        e.message()
                    ),
                );
                let _ = host.set_link_status(
                    &link.link_id,
                    LinkStatus::Error,
                    Some("token_mint_failed"),
                );
                failed.push(
                    names
                        .get(&link.link_id)
                        .cloned()
                        .unwrap_or_else(|| link.link_id.clone()),
                );
            }
        }
    }

    let mut summary = format!("{linked} linked.");
    if !failed.is_empty() {
        summary.push_str(&format!(
            " Plex did not issue a profile token for {}; try Edit accounts again later.",
            failed.join(", ")
        ));
    }
    Ok(screen("done", ScreenBody::Done(summary), &State::default()))
}

/// Addresses parked by a failed rediscovery, or a fresh rediscovery when the
/// operator gets here before one ran.
fn pending_or_rediscovered(
    host: &mut dyn Host,
    base: &str,
) -> Result<Option<ServerInfo>, PlexError> {
    if let Some(p) = store::get_json::<ServerInfo>(host, store::SERVER_PENDING)? {
        return Ok(Some(p));
    }
    let Some(info) = store::get_json::<ServerInfo>(host, store::SERVER_INFO)? else {
        return Ok(None);
    };
    let Some(machine) = info.machine_identifier.clone() else {
        return Ok(None);
    };
    let owner = endpoint::owner_link(host)?;
    let found = plextv::resources(host, base, &Auth::Link(&owner))?
        .into_iter()
        .find(|s| s.machine_identifier == machine);
    Ok(found.map(|s| ServerInfo {
        machine_identifier: Some(machine),
        name: s.name,
        candidates: endpoint::order_candidates(&s.connections),
    }))
}

fn on_confirm_endpoints(host: &mut dyn Host, base: &str) -> Result<SetupScreen, String> {
    let Some(p) = pending_or_rediscovered(host, base).map_err(|e| e.message())? else {
        let body = ScreenBody::Done(
            "Nothing to confirm: plex.tv does not list new addresses for this server.".into(),
        );
        return Ok(screen("done", body, &State::default()));
    };
    let id = p
        .machine_identifier
        .clone()
        .unwrap_or_else(|| "manual".into());
    let state = State {
        servers: vec![ServerChoice {
            id: id.clone(),
            name: p.name.clone(),
            machine_identifier: p.machine_identifier.clone(),
            candidates: p.candidates.clone(),
        }],
        confirm_only: true,
        ..State::default()
    };
    let body = ScreenBody::Choice(ChoiceScreen {
        title: format!("{} moved to new addresses", p.name),
        options: vec![ChoiceOption {
            id,
            label: format!("Allow Mydia to reach {} at these addresses", p.name),
            detail: Some(p.candidates.join(", ")),
            badge: None,
            endpoints: p
                .candidates
                .iter()
                .filter_map(|c| endpoint::endpoint_of(c))
                .collect(),
            credentials: vec![],
        }],
    });
    Ok(screen("server", body, &state))
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::endpoint::ServerInfo;
    use crate::host::fake::FakeHost;
    use crate::store;
    use mydia_plugin_sdk::types::{LinkRole, LinkStatus, ScreenBody, SetupRequest};

    const TV: &str = "https://plex.tv/api/v2";
    const RES: &str = "https://plex.tv/api/v2/resources?includeHttps=1&includeRelay=1";

    fn req(step: &str, input: &str, state: &str) -> SetupRequest {
        SetupRequest {
            step: step.into(),
            input_json: input.into(),
            state_json: state.into(),
            config_json: r#"{"instance_id":"inst-1"}"#.into(),
        }
    }

    fn choice(screen: &SetupScreen) -> &mydia_plugin_sdk::types::ChoiceScreen {
        match &screen.body {
            ScreenBody::Choice(c) => c,
            other => panic!("expected choice, got {other:?}"),
        }
    }

    fn after_server_links(host: &mut FakeHost) {
        host.with_link("owner", LinkRole::Owner, None, None);
        host.with_link("srv", LinkRole::Endpoint, None, None);
    }

    const TWO_SERVERS: &str = r#"[
      {"name":"Den","clientIdentifier":"m1","provides":"server","owned":true,"presence":true,"accessToken":"den-tok",
       "connections":[{"uri":"http://192.168.1.20:32400","local":true},{"uri":"https://relay.m1.plex.direct:8443","relay":true}]},
      {"name":"Zed Shared","clientIdentifier":"s2","provides":"server","owned":false,"presence":true,"accessToken":"zed-tok",
       "connections":[{"uri":"https://203-0-113-5.s2.plex.direct:32400"}]}
    ]"#;

    #[test]
    fn start_offers_sign_in_or_manual() {
        let screen = run(&mut FakeHost::new(), &req("start", "{}", "{}")).unwrap();
        assert_eq!(screen.step, "method");
        let ids: Vec<_> = choice(&screen)
            .options
            .iter()
            .map(|o| o.id.as_str())
            .collect();
        assert_eq!(ids, vec!["signin", "manual"]);
        assert!(choice(&screen)
            .options
            .iter()
            .all(|o| o.endpoints.is_empty() && o.credentials.is_empty()));
    }

    #[test]
    fn sign_in_creates_a_pin_and_opens_plex() {
        let mut host = FakeHost::new();
        host.respond(
            "POST",
            &format!("{TV}/pins"),
            201,
            r#"{"id":42,"code":"c0de"}"#,
        );
        let screen = run(&mut host, &req("method", r#"{"option_id":"signin"}"#, "{}")).unwrap();
        assert_eq!(screen.step, "poll");
        match &screen.body {
            ScreenBody::ExternalAuth(a) => {
                assert!(a.url.contains("code=c0de"));
                assert_eq!(a.poll_after_seconds, 2);
            }
            other => panic!("expected external-auth, got {other:?}"),
        }
        let state: serde_json::Value = serde_json::from_str(&screen.next_state_json).unwrap();
        assert_eq!(state["pin_id"], 42);
    }

    #[test]
    fn polling_a_pending_pin_keeps_waiting() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/pins/42"),
            200,
            r#"{"id":42,"code":"c0de"}"#,
        );
        let screen = run(
            &mut host,
            &req("poll", "{}", r#"{"pin_id":42,"pin_code":"c0de"}"#),
        )
        .unwrap();
        assert!(matches!(screen.body, ScreenBody::ExternalAuth(_)));
        assert_eq!(screen.step, "poll");
    }

    #[test]
    fn an_expired_pin_returns_to_the_method_choice_with_an_error() {
        let mut host = FakeHost::new();
        host.respond("GET", &format!("{TV}/pins/42"), 404, "");
        let screen = run(
            &mut host,
            &req("poll", "{}", r#"{"pin_id":42,"pin_code":"c0de"}"#),
        )
        .unwrap();
        assert_eq!(screen.step, "method");
        assert!(screen.error.as_deref().unwrap().contains("expired"));
    }

    #[test]
    fn an_authorized_pin_lists_servers_with_endpoints_and_credentials() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/pins/42"),
            200,
            r#"{"id":42,"code":"c","authToken":"acct-token"}"#,
        )
        .respond("GET", RES, 200, TWO_SERVERS);
        let screen = run(
            &mut host,
            &req("poll", "{}", r#"{"pin_id":42,"pin_code":"c"}"#),
        )
        .unwrap();
        assert_eq!(screen.step, "server");
        assert_eq!(
            host.requests_to(RES)[0].header("X-Plex-Token"),
            Some("acct-token")
        );

        // The account token is the owner credential, stored when the screen is shown.
        assert_eq!(screen.credentials.len(), 1);
        assert_eq!(screen.credentials[0].role, LinkRole::Owner);
        assert_eq!(screen.credentials[0].token, "acct-token");

        let c = choice(&screen);
        assert_eq!(c.options[0].id, "m1");
        // Den is the only owned server, so it is the one native would have auto-picked.
        assert_eq!(c.options[0].badge.as_deref(), Some("Recommended"));
        assert_eq!(c.options[1].badge.as_deref(), Some("Shared"));
        let hosts: Vec<_> = c.options[0]
            .endpoints
            .iter()
            .map(|e| (e.host.as_str(), e.port))
            .collect();
        assert_eq!(
            hosts,
            vec![("192.168.1.20", 32400), ("relay.m1.plex.direct", 8443)]
        );
        assert_eq!(c.options[0].credentials[0].role, LinkRole::Endpoint);
        assert_eq!(c.options[0].credentials[0].token, "den-tok");

        // No token ever rides in state_json.
        assert!(!screen.next_state_json.contains("acct-token"));
        assert!(!screen.next_state_json.contains("den-tok"));
    }

    #[test]
    fn an_account_with_no_server_explains_itself() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/pins/42"),
            200,
            r#"{"id":42,"code":"c","authToken":"t"}"#,
        )
        .respond("GET", RES, 200, "[]");
        let screen = run(&mut host, &req("poll", "{}", r#"{"pin_id":42}"#)).unwrap();
        assert_eq!(screen.step, "method");
        assert!(screen
            .error
            .as_deref()
            .unwrap()
            .contains("no Plex Media Server"));
    }

    #[test]
    fn manual_entry_asks_for_url_and_token_then_offers_that_server() {
        let mut host = FakeHost::new();
        let form = run(&mut host, &req("method", r#"{"option_id":"manual"}"#, "{}")).unwrap();
        assert_eq!(form.step, "manual");
        assert!(matches!(form.body, ScreenBody::Form(_)));

        let bad = run(
            &mut host,
            &req("manual", r#"{"url":"nonsense","token":"t"}"#, "{}"),
        )
        .unwrap();
        assert_eq!(bad.step, "manual");
        assert!(bad.error.is_some());

        let ok = run(
            &mut host,
            &req(
                "manual",
                r#"{"url":"http://192.168.1.20:32400/","token":"manual-tok"}"#,
                "{}",
            ),
        )
        .unwrap();
        assert_eq!(ok.step, "server");
        let opt = &choice(&ok).options[0];
        assert_eq!(opt.id, "manual");
        assert_eq!(opt.endpoints[0].host, "192.168.1.20");
        assert_eq!(opt.credentials[0].role, LinkRole::Owner);
        assert_eq!(opt.credentials[0].token, "manual-tok");
        assert!(!ok.next_state_json.contains("manual-tok"));
    }

    fn server_state() -> String {
        serde_json::json!({"servers": [{"id": "m1", "name": "Den", "machine_identifier": "m1",
            "candidates": ["http://192.168.1.20:32400"]}]})
        .to_string()
    }

    #[test]
    fn choosing_a_server_probes_it_then_proposes_home_profiles() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.respond("GET", "http://192.168.1.20:32400/library/sections", 200, "{}")
            .respond("GET", &format!("{TV}/user"), 200, r#"{"uuid":"owner-uuid","username":"camille"}"#)
            .respond("GET", &format!("{TV}/home/users"), 200, r#"{"users":[
                {"uuid":"owner-uuid","username":"camille","admin":true},{"uuid":"uuid-kid","title":"Kiddo"}]}"#);
        let screen = run(
            &mut host,
            &req("server", r#"{"option_id":"m1"}"#, &server_state()),
        )
        .unwrap();

        assert_eq!(screen.step, "mapping");
        match &screen.body {
            ScreenBody::Mapping(m) => {
                assert_eq!(m.accounts.len(), 2);
                assert!(m.suggestions.is_empty(), "name matching is the host's job");
            }
            other => panic!("expected mapping, got {other:?}"),
        }
        assert_eq!(host.proposed.last().unwrap().len(), 2);
        assert_eq!(
            host.requests_to("http://192.168.1.20:32400/library/sections")[0]
                .link
                .as_deref(),
            Some("srv")
        );
        let info: ServerInfo = store::get_json(&mut host, store::SERVER_INFO)
            .unwrap()
            .unwrap();
        assert_eq!(info.machine_identifier.as_deref(), Some("m1"));
        assert!(host.kv.contains_key(store::ENDPOINT_CURRENT));
        assert_eq!(
            host.kv.get(store::SERVER_HOME).map(String::as_str),
            Some("1")
        );
        assert_eq!(
            host.kv.get(store::SERVER_OWNER_ACCOUNT).map(String::as_str),
            Some("owner-uuid")
        );
    }

    #[test]
    fn without_plex_home_the_owner_account_is_the_only_account() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.respond(
            "GET",
            "http://192.168.1.20:32400/library/sections",
            200,
            "{}",
        )
        .respond(
            "GET",
            &format!("{TV}/user"),
            200,
            r#"{"uuid":"owner-uuid","username":"camille"}"#,
        )
        .respond("GET", &format!("{TV}/home/users"), 404, "");
        let screen = run(
            &mut host,
            &req("server", r#"{"option_id":"m1"}"#, &server_state()),
        )
        .unwrap();
        match &screen.body {
            ScreenBody::Mapping(m) => {
                assert_eq!(m.accounts.len(), 1);
                assert_eq!(m.accounts[0].id, "owner-uuid");
                assert!(m.accounts[0].admin);
            }
            other => panic!("expected mapping, got {other:?}"),
        }
        assert_eq!(
            host.kv.get(store::SERVER_HOME).map(String::as_str),
            Some("0")
        );
    }

    #[test]
    fn an_unreachable_choice_restarts_from_the_method_screen() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.fail(
            "GET",
            "http://192.168.1.20:32400/library/sections",
            mydia_plugin_sdk::types::HostError::Network("refused".into()),
        );
        let screen = run(
            &mut host,
            &req("server", r#"{"option_id":"m1"}"#, &server_state()),
        )
        .unwrap();
        assert_eq!(screen.step, "method");
        assert!(screen.error.as_deref().unwrap().contains("Den"));
    }

    #[test]
    fn an_unknown_option_is_an_error_screen_not_a_panic() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        let screen = run(
            &mut host,
            &req("server", r#"{"option_id":"nope"}"#, &server_state()),
        )
        .unwrap();
        assert_eq!(screen.step, "method");
        assert!(screen.error.is_some());
    }

    #[test]
    fn saving_the_mapping_mints_a_token_per_profile_and_isolates_failures() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.with_link("l-kid", LinkRole::User, Some("uuid-kid"), Some("Kiddo"));
        host.with_link("l-gran", LinkRole::User, Some("uuid-gran"), Some("Gran"));
        host.kv.insert(store::SERVER_HOME.into(), "1".into());
        host.kv
            .insert(store::SERVER_OWNER_ACCOUNT.into(), "owner-uuid".into());
        host.respond(
            "POST",
            &format!("{TV}/home/users/uuid-kid/switch"),
            201,
            r#"{"authToken":"kid-token"}"#,
        )
        .respond(
            "POST",
            &format!("{TV}/home/users/uuid-gran/switch"),
            500,
            "",
        );
        let input = r#"{"links":[
            {"link_id":"l-kid","remote_account_id":"uuid-kid","user_id":"u1"},
            {"link_id":"l-gran","remote_account_id":"uuid-gran","user_id":"u2"}]}"#;
        let screen = run(&mut host, &req("mapping", input, "{}")).unwrap();

        assert_eq!(
            host.tokens.get("l-kid").map(String::as_str),
            Some("kid-token")
        );
        assert!(!host.tokens.contains_key("l-gran"));
        assert!(host
            .statuses
            .contains(&("l-kid".into(), LinkStatus::Active, None)));
        assert!(host.statuses.contains(&(
            "l-gran".into(),
            LinkStatus::Error,
            Some("token_mint_failed".into())
        )));
        assert!(host.sent.iter().all(|s| s.link.as_deref() == Some("owner")));
        match &screen.body {
            ScreenBody::Done(summary) => {
                assert!(summary.contains("1 linked"));
                assert!(summary.contains("Gran"));
            }
            other => panic!("expected done, got {other:?}"),
        }
    }

    #[test]
    fn the_owner_account_without_home_links_through_the_owner_credential() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.with_link("l-me", LinkRole::User, Some("owner-uuid"), Some("camille"));
        host.kv.insert(store::SERVER_HOME.into(), "0".into());
        host.kv
            .insert(store::SERVER_OWNER_ACCOUNT.into(), "owner-uuid".into());
        let input =
            r#"{"links":[{"link_id":"l-me","remote_account_id":"owner-uuid","user_id":"u1"}]}"#;
        run(&mut host, &req("mapping", input, "{}")).unwrap();
        assert!(host.sent.is_empty(), "no switch call without Plex Home");
        assert_eq!(
            host.kv
                .get(&store::link_uses_owner_key("l-me"))
                .map(String::as_str),
            Some("1")
        );
        assert!(host
            .statuses
            .contains(&("l-me".into(), LinkStatus::Active, None)));
    }

    #[test]
    fn edit_accounts_goes_straight_to_the_mapping() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        host.respond(
            "GET",
            &format!("{TV}/user"),
            200,
            r#"{"uuid":"owner-uuid","username":"camille"}"#,
        )
        .respond("GET", &format!("{TV}/home/users"), 404, "");
        let screen = run(&mut host, &req("accounts", "{}", "{}")).unwrap();
        assert_eq!(screen.step, "mapping");
    }

    #[test]
    fn confirm_endpoints_offers_the_pending_server_and_finishes_after_the_probe() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        store::put_json(
            &mut host,
            store::SERVER_PENDING,
            &ServerInfo {
                machine_identifier: Some("m1".into()),
                name: "Den".into(),
                candidates: vec!["http://10.0.0.9:32400".into()],
            },
        )
        .unwrap();
        let offer = run(&mut host, &req("confirm-endpoints", "{}", "{}")).unwrap();
        assert_eq!(offer.step, "server");
        assert_eq!(choice(&offer).options[0].endpoints[0].host, "10.0.0.9");
        assert!(choice(&offer).options[0].credentials.is_empty());

        host.respond("GET", "http://10.0.0.9:32400/library/sections", 200, "{}");
        let done = run(
            &mut host,
            &req("server", r#"{"option_id":"m1"}"#, &offer.next_state_json),
        )
        .unwrap();
        assert!(matches!(done.body, ScreenBody::Done(_)));
        assert!(!host.kv.contains_key(store::SERVER_PENDING));
    }

    #[test]
    fn confirm_endpoints_without_pending_rediscovers_through_plex_tv() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
        store::put_json(
            &mut host,
            store::SERVER_INFO,
            &ServerInfo {
                machine_identifier: Some("m1".into()),
                name: "Den".into(),
                candidates: vec!["http://old:1".into()],
            },
        )
        .unwrap();
        host.respond("GET", RES, 200,
            r#"[{"name":"Den","clientIdentifier":"m1","provides":"server","connections":[{"uri":"http://10.0.0.9:32400","local":true}]}]"#);
        let offer = run(&mut host, &req("confirm-endpoints", "{}", "{}")).unwrap();
        assert_eq!(offer.step, "server");
        assert_eq!(choice(&offer).options[0].endpoints[0].host, "10.0.0.9");
        assert_eq!(host.requests_to(RES)[0].link.as_deref(), Some("owner"));
    }

    #[test]
    fn confirm_endpoints_for_a_manual_server_is_done() {
        let mut host = FakeHost::new();
        after_server_links(&mut host);
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
        let screen = run(&mut host, &req("confirm-endpoints", "{}", "{}")).unwrap();
        assert!(matches!(screen.body, ScreenBody::Done(_)));
        assert!(host.sent.is_empty());
    }

    #[test]
    fn an_unknown_step_is_an_error() {
        assert!(run(&mut FakeHost::new(), &req("bogus", "{}", "{}")).is_err());
    }
}
