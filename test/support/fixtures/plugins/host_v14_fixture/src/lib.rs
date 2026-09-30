//! 1.4 host-contract fixture. Each event name is an op that calls one 1.4 host
//! import and returns its result as JSON; `setup` and `check-health` return
//! canned screens. See Cargo.toml.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    ChoiceOption, ChoiceScreen, Credential, Endpoint, Event, ExternalAuthScreen, FormScreen,
    Health, HealthAction, HealthStatus, KvEntry, LinkRole, LinkStatus, ListItem, ListRequest,
    MappingScreen, MappingSuggestion, OutboundRequest, RemoteAccount, ScheduleTick, ScreenBody,
    SetupField, SetupRequest, SetupScreen, SyncRunReport, SyncRunStatus,
};
use std::collections::HashMap;
use tinyjson::JsonValue;

type Obj = HashMap<String, JsonValue>;

fn parse_obj(json: &str) -> Obj {
    match json.parse::<JsonValue>() {
        Ok(JsonValue::Object(map)) => map,
        _ => HashMap::new(),
    }
}

fn s(map: &Obj, key: &str) -> Option<String> {
    match map.get(key) {
        Some(JsonValue::String(v)) => Some(v.clone()),
        _ => None,
    }
}

fn n(map: &Obj, key: &str) -> u32 {
    match map.get(key) {
        Some(JsonValue::Number(v)) => *v as u32,
        _ => 0,
    }
}

fn arr(map: &Obj, key: &str) -> Vec<Obj> {
    match map.get(key) {
        Some(JsonValue::Array(items)) => items
            .iter()
            .filter_map(|v| match v {
                JsonValue::Object(o) => Some(o.clone()),
                _ => None,
            })
            .collect(),
        _ => Vec::new(),
    }
}

fn js(v: &str) -> String {
    JsonValue::String(v.to_string()).stringify().unwrap()
}

fn js_opt(v: &Option<String>) -> String {
    match v {
        Some(x) => js(x),
        None => "null".to_string(),
    }
}

fn ok() -> Result<String, String> {
    Ok("{\"ok\":true}".to_string())
}

#[mydia_plugin_sdk::plugin(on_schedule = on_schedule, setup = setup, check_health = check_health)]
fn on_event(evt: Event) -> Result<String, String> {
    let m = parse_obj(&evt.metadata_json);
    let op = evt.event.as_str();
    let fail = |e: mydia_plugin_sdk::types::HostError| format!("{} error: {:?}", op, e);

    match op {
        "links_list" => {
            let links = host::links_list().map_err(fail)?;
            let rows: Vec<String> = links
                .iter()
                .map(|l| {
                    let role = match l.role {
                        LinkRole::Owner => "owner",
                        LinkRole::Endpoint => "endpoint",
                        LinkRole::User => "user",
                    };
                    let status = match l.status {
                        LinkStatus::Active => "active",
                        LinkStatus::Error => "error",
                        LinkStatus::Disabled => "disabled",
                    };
                    format!(
                        "{{\"id\":{},\"role\":{},\"user_id\":{},\"external_user_id\":{},\"status\":{}}}",
                        js(&l.id),
                        js(role),
                        js_opt(&l.user_id),
                        js_opt(&l.external_user_id),
                        js(status)
                    )
                })
                .collect();
            Ok(format!("{{\"links\":[{}]}}", rows.join(",")))
        }

        "link_request" => {
            let req = OutboundRequest {
                url: s(&m, "url").unwrap_or_default(),
                method: s(&m, "method").unwrap_or_else(|| "GET".to_string()),
                headers: vec![],
                body: None,
            };
            let resp =
                host::link_request(&s(&m, "link_id").unwrap_or_default(), &req).map_err(fail)?;
            Ok(format!("{{\"status\":{},\"ok\":{}}}", resp.status, resp.ok))
        }

        "propose_accounts" => {
            let accounts: Vec<RemoteAccount> = arr(&m, "accounts")
                .iter()
                .map(|a| RemoteAccount {
                    id: s(a, "id").unwrap_or_default(),
                    name: s(a, "name").unwrap_or_default(),
                    admin: matches!(a.get("admin"), Some(JsonValue::Boolean(true))),
                })
                .collect();
            host::propose_accounts(&accounts).map_err(fail)?;
            ok()
        }

        "set_link_token" => {
            host::set_link_token(
                &s(&m, "link_id").unwrap_or_default(),
                &s(&m, "token").unwrap_or_default(),
            )
            .map_err(fail)?;
            ok()
        }

        "set_link_status" => {
            let status = match s(&m, "status").as_deref() {
                Some("error") => LinkStatus::Error,
                Some("disabled") => LinkStatus::Disabled,
                _ => LinkStatus::Active,
            };
            let message = s(&m, "message");
            host::set_link_status(
                &s(&m, "link_id").unwrap_or_default(),
                status,
                message.as_deref(),
            )
            .map_err(fail)?;
            ok()
        }

        "kv_list" => {
            let cursor = s(&m, "cursor");
            let page = host::kv_list(&s(&m, "prefix").unwrap_or_default(), cursor.as_deref())
                .map_err(fail)?;
            let entries: Vec<String> = page
                .entries
                .iter()
                .map(|e| format!("{{\"key\":{},\"value\":{}}}", js(&e.key), js(&e.value)))
                .collect();
            Ok(format!(
                "{{\"entries\":[{}],\"next_cursor\":{}}}",
                entries.join(","),
                js_opt(&page.next_cursor)
            ))
        }

        "kv_set_many" => {
            let entries: Vec<KvEntry> = arr(&m, "entries")
                .iter()
                .map(|e| KvEntry {
                    key: s(e, "key").unwrap_or_default(),
                    value: s(e, "value").unwrap_or_default(),
                })
                .collect();
            host::kv_set_many(&entries).map_err(fail)?;
            ok()
        }

        "report_sync_run" => {
            let status = match s(&m, "status").as_deref() {
                Some("partial") => SyncRunStatus::Partial,
                Some("error") => SyncRunStatus::Error,
                _ => SyncRunStatus::Ok,
            };
            let run = SyncRunReport {
                started_at: "2026-01-01T00:00:00Z".to_string(),
                finished_at: "2026-01-01T00:00:05Z".to_string(),
                status,
                pulled: n(&m, "pulled"),
                pushed: n(&m, "pushed"),
                skipped: n(&m, "skipped"),
                errors: n(&m, "errors"),
                message: s(&m, "message"),
            };
            host::report_sync_run(&run).map_err(fail)?;
            ok()
        }

        "progress_origins" => {
            let req = ListRequest {
                namespace: "playback_progress".to_string(),
                cursor: None,
                updated_since: None,
                limit: Some(match n(&m, "limit") {
                    0 => 200,
                    x => x,
                }),
            };
            let result = host::data_list(&req).map_err(fail)?;
            let origins: Vec<String> = result
                .items
                .iter()
                .filter_map(|item| match item {
                    ListItem::PlaybackProgress(p) => Some(js_opt(&p.origin)),
                    _ => None,
                })
                .collect();
            Ok(format!("{{\"origins\":[{}]}}", origins.join(",")))
        }

        "http" => {
            let req = OutboundRequest {
                url: s(&m, "url").unwrap_or_default(),
                method: "GET".to_string(),
                headers: vec![],
                body: None,
            };
            let resp = host::http_request(&req).map_err(fail)?;
            Ok(format!("{{\"status\":{},\"ok\":{}}}", resp.status, resp.ok))
        }

        "config" => {
            let config = m
                .get("config")
                .cloned()
                .unwrap_or(JsonValue::Object(HashMap::new()));
            Ok(format!("{{\"config\":{}}}", config.stringify().unwrap()))
        }

        _ => Ok("{}".to_string()),
    }
}

fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    let config = match tick.config_json.parse::<JsonValue>() {
        Ok(v) => v.stringify().unwrap(),
        Err(_) => "{}".to_string(),
    };
    Ok(format!("{{\"scheduled\":true,\"config\":{}}}", config))
}

fn screen(step: &str, body: ScreenBody, state: &str) -> SetupScreen {
    SetupScreen {
        step: step.to_string(),
        body,
        next_state_json: state.to_string(),
        credentials: vec![],
        error: None,
    }
}

fn external_auth(polls: u32) -> SetupScreen {
    screen(
        "auth",
        ScreenBody::ExternalAuth(ExternalAuthScreen {
            url: "https://auth.example.invalid/pin".to_string(),
            poll_after_seconds: 1,
            message: None,
        }),
        &format!("{{\"polls\":{}}}", polls),
    )
}

fn manual_form(error: Option<String>) -> SetupScreen {
    let field = |key: &str, label: &str, ty: &str, required: bool| SetupField {
        key: key.to_string(),
        label: label.to_string(),
        field_type: ty.to_string(),
        required,
        options: vec![],
        default_value: None,
    };

    let mut form = screen(
        "manual",
        ScreenBody::Form(FormScreen {
            title: "Enter server details".to_string(),
            fields: vec![
                field("url", "Server URL", "url", true),
                field("token", "Token", "secret", false),
            ],
        }),
        "{}",
    );
    form.error = error;
    form
}

fn server_choice() -> SetupScreen {
    let mut choice = screen(
        "pick",
        ScreenBody::Choice(ChoiceScreen {
            title: "Pick a server".to_string(),
            options: vec![
                ChoiceOption {
                    id: "server-a".to_string(),
                    label: "Server A".to_string(),
                    detail: Some("http://127.0.0.1:32400".to_string()),
                    badge: Some("local".to_string()),
                    endpoints: vec![Endpoint {
                        scheme: "http".to_string(),
                        host: "127.0.0.1".to_string(),
                        port: 32400,
                    }],
                    credentials: vec![Credential {
                        role: LinkRole::Endpoint,
                        token: "endpoint-token-a".to_string(),
                    }],
                },
                ChoiceOption {
                    id: "server-b".to_string(),
                    label: "Server B".to_string(),
                    detail: None,
                    badge: None,
                    endpoints: vec![Endpoint {
                        scheme: "https".to_string(),
                        host: "b.example.invalid".to_string(),
                        port: 443,
                    }],
                    credentials: vec![],
                },
            ],
        }),
        "{\"stage\":\"picked\"}",
    );
    choice.credentials = vec![Credential {
        role: LinkRole::Owner,
        token: "owner-token".to_string(),
    }];
    choice
}

fn setup(req: SetupRequest) -> Result<SetupScreen, String> {
    let input = parse_obj(&req.input_json);
    let state = parse_obj(&req.state_json);
    let config = parse_obj(&req.config_json);

    match req.step.as_str() {
        "start" => Ok(external_auth(0)),

        "poll" => {
            if n(&state, "polls") == 0 {
                Ok(external_auth(1))
            } else {
                Ok(server_choice())
            }
        }

        "pick" => {
            let server = s(&input, "option_id").unwrap_or_default();
            let suggestions = match s(&config, "suggest_user_id") {
                Some(user_id) if !user_id.is_empty() => vec![MappingSuggestion {
                    remote_account_id: "acct-1".to_string(),
                    user_id,
                }],
                _ => vec![],
            };

            Ok(screen(
                "map",
                ScreenBody::Mapping(MappingScreen {
                    title: "Link accounts".to_string(),
                    accounts: vec![
                        RemoteAccount {
                            id: "acct-1".to_string(),
                            name: "Remote Alice".to_string(),
                            admin: true,
                        },
                        RemoteAccount {
                            id: "acct-2".to_string(),
                            name: "Remote Bob".to_string(),
                            admin: false,
                        },
                    ],
                    suggestions,
                }),
                &format!("{{\"server\":{}}}", js(&server)),
            ))
        }

        "map" => {
            let count = match input.get("links") {
                Some(JsonValue::Array(items)) => items.len(),
                _ => 0,
            };
            Ok(screen(
                "done",
                ScreenBody::Done(format!("Linked {} accounts", count)),
                "{}",
            ))
        }

        "manual-start" => Ok(manual_form(None)),

        "manual" => {
            let url = s(&input, "url").unwrap_or_default();
            let token = s(&input, "token").unwrap_or_default();

            if url.is_empty() {
                return Ok(manual_form(Some("url is empty".to_string())));
            }

            let mut done = screen("done", ScreenBody::Done(format!("Manual {}", url)), "{}");
            if !token.is_empty() {
                done.credentials = vec![Credential {
                    role: LinkRole::Owner,
                    token,
                }];
            }
            Ok(done)
        }

        "fail" => Err("fixture failure".to_string()),

        other => Err(format!("unknown step {}", other)),
    }
}

fn check_health() -> Result<Health, String> {
    Ok(Health {
        status: HealthStatus::Degraded,
        message: Some("fixture degraded".to_string()),
        action: Some(HealthAction::Reconnect),
    })
}
