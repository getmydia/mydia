//! Page fixture: see Cargo.toml for the route table.

use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{
    CollectionAttrs, Event, FavoriteTarget, HostError, ListRequest, MediaAddTarget,
    OutboundRequest, PageRequest, PageResponse, SearchKind, SearchRequest, WriteOutcome,
};
use std::collections::HashMap;
use tinyjson::JsonValue;

fn obj(pairs: Vec<(&str, JsonValue)>) -> String {
    let map: HashMap<String, JsonValue> =
        pairs.into_iter().map(|(k, v)| (k.to_string(), v)).collect();
    JsonValue::Object(map)
        .stringify()
        .unwrap_or_else(|_| "{}".into())
}

fn s(v: &str) -> JsonValue {
    JsonValue::String(v.to_string())
}

fn body_map(req: &PageRequest) -> HashMap<String, JsonValue> {
    match req.body.as_deref().unwrap_or("{}").parse::<JsonValue>() {
        Ok(JsonValue::Object(m)) => m,
        _ => HashMap::new(),
    }
}

fn get_str(m: &HashMap<String, JsonValue>, k: &str) -> String {
    match m.get(k) {
        Some(JsonValue::String(v)) => v.clone(),
        _ => String::new(),
    }
}

fn get_i64(m: &HashMap<String, JsonValue>, k: &str) -> Option<i64> {
    match m.get(k) {
        Some(JsonValue::Number(n)) => Some(*n as i64),
        _ => None,
    }
}

fn get_strs(m: &HashMap<String, JsonValue>, k: &str) -> Vec<String> {
    match m.get(k) {
        Some(JsonValue::Array(a)) => a
            .iter()
            .filter_map(|v| match v {
                JsonValue::String(s) => Some(s.clone()),
                _ => None,
            })
            .collect(),
        _ => vec![],
    }
}

fn json(status: u16, body: String) -> Result<PageResponse, String> {
    Ok(PageResponse {
        status,
        headers: vec![("content-type".into(), "application/json".into())],
        body,
    })
}

fn host_error(e: HostError) -> Result<PageResponse, String> {
    json(500, obj(vec![("error", s(&format!("{:?}", e)))]))
}

fn outcome(r: Result<WriteOutcome, HostError>) -> Result<PageResponse, String> {
    match r {
        Ok(WriteOutcome::Done(result)) => json(
            200,
            obj(vec![("outcome", s("done")), ("result", s(&result))]),
        ),
        Ok(WriteOutcome::NeedsConfirmation(id)) => {
            json(200, obj(vec![("outcome", s("pending")), ("id", s(&id))]))
        }
        Err(e) => host_error(e),
    }
}

fn handle_http(req: PageRequest) -> Result<PageResponse, String> {
    let m = body_map(&req);

    match req.path.as_str() {
        "/echo" => json(
            200,
            obj(vec![
                ("method", s(&req.method)),
                ("path", s(&req.path)),
                ("query", s(&req.query)),
                ("body", s(req.body.as_deref().unwrap_or(""))),
                ("user_id", s(&req.user_id)),
                ("role", s(&req.role)),
                ("session_id", s(&req.session_id)),
                ("config", s(&req.config_json)),
                (
                    "headers",
                    s(&req
                        .headers
                        .iter()
                        .map(|(k, v)| format!("{}:{}", k, v))
                        .collect::<Vec<_>>()
                        .join("\n")),
                ),
            ]),
        ),

        "/headers" => Ok(PageResponse {
            status: 200,
            headers: vec![
                ("set-cookie".into(), "sid=stolen".into()),
                ("content-security-policy".into(), "default-src *".into()),
                ("cache-control".into(), "public, max-age=999".into()),
                ("x-injected".into(), "a\r\nset-cookie: b=c".into()),
                ("x-custom".into(), "kept-out".into()),
            ],
            body: "hostile".into(),
        }),

        "/no-content-type" => Ok(PageResponse {
            status: 200,
            headers: vec![],
            body: "plain".into(),
        }),

        "/call/search" => {
            let kind = if get_str(&m, "kind") == "catalog" {
                SearchKind::Catalog
            } else {
                SearchKind::Library
            };
            let r = host::search(&SearchRequest {
                kind,
                query: get_str(&m, "query"),
                media_type: None,
                limit: Some(10),
            });
            match r {
                Ok(hits) => json(
                    200,
                    obj(vec![(
                        "titles",
                        JsonValue::Array(hits.iter().map(|h| s(&h.title)).collect()),
                    )]),
                ),
                Err(e) => host_error(e),
            }
        }

        "/call/media-add" => outcome(host::media_add(&MediaAddTarget {
            media_type: get_str(&m, "media_type"),
            tmdb_id: get_i64(&m, "tmdb_id"),
            tvdb_id: get_i64(&m, "tvdb_id"),
        })),

        "/call/collection-create" => outcome(host::collection_create(&CollectionAttrs {
            name: Some(get_str(&m, "name")),
            description: None,
            kind: None,
            smart_rules_json: None,
        })),

        "/call/collection-add" => outcome(host::collection_add_items(
            &get_str(&m, "id"),
            &get_strs(&m, "ids"),
        )),

        "/call/add-favorite" => outcome(host::add_favorite(&FavoriteTarget {
            user_id: String::new(),
            imdb_id: None,
            tmdb_id: get_i64(&m, "tmdb_id"),
            tvdb_id: None,
        })),

        "/call/data-list" => {
            let r = host::data_list(&ListRequest {
                namespace: get_str(&m, "namespace"),
                cursor: None,
                updated_since: None,
                limit: None,
            });
            match r {
                Ok(page) => json(
                    200,
                    obj(vec![("count", JsonValue::Number(page.items.len() as f64))]),
                ),
                Err(e) => host_error(e),
            }
        }

        "/call/http" => {
            let r = host::http_request(&OutboundRequest {
                url: get_str(&m, "url"),
                method: "GET".into(),
                headers: vec![],
                body: None,
            });
            match r {
                Ok(resp) => json(
                    200,
                    obj(vec![("status", JsonValue::Number(resp.status as f64))]),
                ),
                Err(e) => host_error(e),
            }
        }

        "/call/sleep" => {
            let ms = get_i64(&m, "ms").unwrap_or(0).max(0) as u64;
            std::thread::sleep(std::time::Duration::from_millis(ms));
            json(200, obj(vec![("slept", JsonValue::Boolean(true))]))
        }

        _ => json(404, obj(vec![("error", s("no route"))])),
    }
}

#[mydia_plugin_sdk::plugin(on_http = handle_http)]
fn on_event(evt: Event) -> Result<String, String> {
    if evt.event == "page-write" {
        let r = host::add_favorite(&FavoriteTarget {
            user_id: String::new(),
            imdb_id: None,
            tmdb_id: Some(1),
            tvdb_id: None,
        });
        return match r {
            Ok(_) => Ok("{\"wrote\":true}".into()),
            Err(e) => Err(format!("{:?}", e)),
        };
    }
    Ok("{}".into())
}
