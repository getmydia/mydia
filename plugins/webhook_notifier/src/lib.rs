//! Mydia bundled webhook notifier — the reference SDK plugin (component model).
//!
//! Authored on the published SDK: `#[mydia::plugin]` adapts the typed
//! `on_event(Event) -> Result<String, String>` handler onto the WIT
//! `handler.on-event` export. The handler formats a notification for the
//! operator-selected target (`config.target`: a Discord embed, an ntfy publish,
//! or a `custom` request whose body, query params, and headers are
//! operator-supplied `{{key}}` templates), enriches it via the typed `data-read`
//! host import, POSTs it through the gated `http-request` host import, and
//! returns a small JSON result the host reads (`{"delivered": bool, "status": n}`).
//!
//! All egress goes through the typed host imports — the guest has no ambient
//! network or filesystem access. The destination URL arrives in the event's
//! metadata bag under `config.webhook_url`; the gate re-validates its host
//! against the plugin's granted `net:http` allowlist on every call. For ntfy
//! that host is granted from the operator's configured URL (a host-granting
//! setting), so Mydia never needs ntfy-specific knowledge.
//!
//! The handler operates over `tinyjson::JsonValue` internally so the templated
//! `custom` target can render over the arbitrary metadata bag; the typed `Event`
//! is reconstructed into that shape on entry, and the typed host records are
//! adapted at the two call sites.

use std::collections::HashMap;
use std::fmt::Write;

use mydia_plugin_sdk::types::{DataRequest, Event, MediaItem, OutboundRequest, ReadResult};
use tinyjson::JsonValue;

#[mydia_plugin_sdk::plugin]
#[expect(
    clippy::needless_pass_by_value,
    clippy::unnecessary_wraps,
    reason = "the plugin macro fixes this by-value, Result-returning handler signature"
)]
fn on_event(evt: Event) -> Result<String, String> {
    Ok(stringify(&process(&event_to_json(&evt))))
}

// Reconstruct the internal JsonValue event from the typed Event. The envelope
// fields map back to their keys; the metadata bag (carrying `metadata` and the
// injected `config`) is parsed from `metadata-json` and forms the base object.
fn event_to_json(evt: &Event) -> JsonValue {
    let mut map: HashMap<String, JsonValue> = match evt.metadata_json.parse() {
        Ok(JsonValue::Object(m)) => m,
        _ => HashMap::new(),
    };

    map.insert("event".to_string(), string(&evt.event));
    insert_opt(&mut map, "category", evt.category.as_ref());
    insert_opt(&mut map, "severity", evt.severity.as_ref());
    insert_opt(&mut map, "actor_type", evt.actor_type.as_ref());
    insert_opt(&mut map, "actor_id", evt.actor_id.as_ref());
    insert_opt(&mut map, "resource_type", evt.resource_type.as_ref());
    insert_opt(&mut map, "resource_id", evt.resource_id.as_ref());

    JsonValue::Object(map)
}

fn insert_opt(map: &mut HashMap<String, JsonValue>, key: &str, value: Option<&String>) {
    if let Some(v) = value {
        map.insert(key.to_string(), string(v));
    }
}

// ── Typed host imports, cfg-guarded so the crate links for native `cargo test`
// (R2: handler logic is unit-testable without a wasm build), where the wasm
// imports do not exist. ───────────────────────────────────────────────────────

#[cfg(target_arch = "wasm32")]
fn host_http(req: &OutboundRequest) -> Option<mydia_plugin_sdk::types::OutboundResponse> {
    mydia_plugin_sdk::host::http_request(req).ok()
}

#[cfg(not(target_arch = "wasm32"))]
fn host_http(_req: &OutboundRequest) -> Option<mydia_plugin_sdk::types::OutboundResponse> {
    None
}

#[cfg(target_arch = "wasm32")]
fn host_data(req: &DataRequest) -> Option<ReadResult> {
    mydia_plugin_sdk::host::data_read(req).ok()
}

#[cfg(not(target_arch = "wasm32"))]
fn host_data(_req: &DataRequest) -> Option<ReadResult> {
    None
}

// POST `req` (the internal JsonValue request) through the gated http-request
// host import, returning the host's `{ok, status}` envelope.
fn http_call(req: &JsonValue) -> JsonValue {
    let headers: Vec<(String, String)> = match get(req, "headers") {
        Some(JsonValue::Object(m)) => m
            .iter()
            .filter_map(|(k, v)| as_str(v).map(|s| (k.clone(), s.to_string())))
            .collect(),
        _ => Vec::new(),
    };

    let out = OutboundRequest {
        url: get(req, "url").and_then(as_str).unwrap_or("").to_string(),
        method: get(req, "method")
            .and_then(as_str)
            .unwrap_or("POST")
            .to_string(),
        headers,
        body: get(req, "body").and_then(as_str).map(ToString::to_string),
    };

    match host_http(&out) {
        Some(resp) => object(vec![
            ("ok", JsonValue::Boolean(resp.ok)),
            ("status", JsonValue::Number(f64::from(resp.status))),
        ]),
        None => object(vec![
            ("ok", JsonValue::Boolean(false)),
            ("status", JsonValue::Number(0.0)),
        ]),
    }
}

// Read the curated media-item projection via the data-read host import, mapping
// the typed record back into the flat JsonValue shape the templates expect.
fn data_call(id: &str) -> JsonValue {
    let req = DataRequest {
        namespace: "media_item".to_string(),
        id: id.to_string(),
    };

    match host_data(&req) {
        Some(ReadResult::MediaItem(item)) => media_item_to_json(&item),
        None => object(vec![("error", string("host call failed"))]),
    }
}

fn media_item_to_json(item: &MediaItem) -> JsonValue {
    let mut pairs: Vec<(&str, JsonValue)> = vec![
        ("id", string(&item.id)),
        ("type", string(&item.item_type)),
        ("title", string(&item.title)),
        (
            "genres",
            JsonValue::Array(item.genres.iter().map(|g| string(g)).collect()),
        ),
    ];

    push_opt_str(&mut pairs, "original_title", item.original_title.as_ref());
    push_opt_str(&mut pairs, "imdb_id", item.imdb_id.as_ref());
    push_opt_str(&mut pairs, "overview", item.overview.as_ref());
    push_opt_str(&mut pairs, "tagline", item.tagline.as_ref());
    push_opt_str(&mut pairs, "poster_path", item.poster_path.as_ref());
    push_opt_str(&mut pairs, "backdrop_path", item.backdrop_path.as_ref());
    push_opt_num(&mut pairs, "year", item.year.map(f64::from));
    push_opt_num(&mut pairs, "tmdb_id", item.tmdb_id.map(i64_to_f64));
    push_opt_num(&mut pairs, "tvdb_id", item.tvdb_id.map(i64_to_f64));
    push_opt_num(&mut pairs, "runtime", item.runtime.map(f64::from));
    push_opt_num(&mut pairs, "rating", item.rating);

    object(pairs)
}

fn push_opt_str(pairs: &mut Vec<(&str, JsonValue)>, key: &'static str, value: Option<&String>) {
    if let Some(v) = value {
        pairs.push((key, string(v)));
    }
}

fn push_opt_num(pairs: &mut Vec<(&str, JsonValue)>, key: &'static str, value: Option<f64>) {
    if let Some(v) = value {
        pairs.push((key, JsonValue::Number(v)));
    }
}

fn process(event: &JsonValue) -> JsonValue {
    let config = get(event, "config");

    let webhook_url = config
        .and_then(|c| get(c, "webhook_url"))
        .and_then(as_str)
        .unwrap_or("")
        .to_string();

    if webhook_url.is_empty() {
        return object(vec![
            ("delivered", JsonValue::Boolean(false)),
            ("error", string("no webhook_url configured")),
        ]);
    }

    // The operator picks the target service; Mydia stays target-agnostic and only
    // grants the host of the configured URL. Default to discord for back-compat.
    let target = config
        .and_then(|c| get(c, "target"))
        .and_then(as_str)
        .unwrap_or("discord");

    let title = get(event, "metadata")
        .and_then(|m| get(m, "title"))
        .and_then(as_str)
        .unwrap_or("Mydia")
        .to_string();
    let verb = describe(get(event, "event").and_then(as_str).unwrap_or(""));

    // Enrich with library data via the data:read host function when possible.
    let enriched = read_media(event);
    let overview = enriched
        .as_ref()
        .and_then(|v| get(v, "overview"))
        .and_then(as_str)
        .unwrap_or("")
        .to_string();

    let req = match target {
        "ntfy" => ntfy_request(&webhook_url, config, &title, verb, &overview),
        "custom" => {
            let ctx = build_context(event, enriched.as_ref(), verb);
            custom_request(&webhook_url, config, &ctx)
        }
        _ => discord_request(&webhook_url, &title, verb, &overview, enriched.as_ref()),
    };

    let resp = http_call(&req);
    object(vec![
        (
            "delivered",
            JsonValue::Boolean(get(&resp, "ok").and_then(as_bool).unwrap_or(false)),
        ),
        (
            "status",
            JsonValue::Number(get(&resp, "status").and_then(as_num).unwrap_or(0.0)),
        ),
    ])
}

// Discord webhook: a JSON embed POSTed to the configured webhook URL.
fn discord_request(
    webhook_url: &str,
    title: &str,
    verb: &str,
    overview: &str,
    enriched: Option<&JsonValue>,
) -> JsonValue {
    let poster = enriched
        .and_then(|v| get(v, "poster_path"))
        .and_then(as_str)
        .unwrap_or("");

    let description = if overview.is_empty() {
        verb.to_string()
    } else {
        format!("{verb}\n\n{overview}")
    };

    let mut embed = vec![
        ("title", string(title)),
        ("description", string(&description)),
    ];
    if !poster.is_empty() {
        embed.push((
            "thumbnail",
            object(vec![("url", string(&poster_url(poster)))]),
        ));
    }

    let discord = object(vec![
        ("content", string(&format!("{verb}: {title}"))),
        ("embeds", JsonValue::Array(vec![object(embed)])),
    ]);

    object(vec![
        ("url", string(webhook_url)),
        ("method", string("POST")),
        (
            "headers",
            object(vec![("content-type", string("application/json"))]),
        ),
        ("body", string(&stringify(&discord))),
    ])
}

// ntfy publish: a plain-text body POSTed to the operator's configured URL (the
// topic is in the URL path), with metadata in headers. See
// https://docs.ntfy.sh/publish/ ("Shape A"). The host canonicalizes header case.
fn ntfy_request(
    webhook_url: &str,
    config: Option<&JsonValue>,
    title: &str,
    verb: &str,
    overview: &str,
) -> JsonValue {
    let body = if overview.is_empty() {
        verb.to_string()
    } else {
        format!("{verb}\n\n{overview}")
    };

    let mut headers = vec![
        ("content-type", string("text/plain")),
        ("title", string(&sanitize_header(title))),
    ];

    push_setting_header(&mut headers, config, "ntfy_priority", "priority", |v| {
        v.to_string()
    });
    push_setting_header(
        &mut headers,
        config,
        "ntfy_tags",
        "tags",
        ToString::to_string,
    );
    push_setting_header(&mut headers, config, "ntfy_token", "authorization", |v| {
        format!("Bearer {v}")
    });

    object(vec![
        ("url", string(webhook_url)),
        ("method", string("POST")),
        ("headers", object(headers)),
        ("body", string(&body)),
    ])
}

// Appends `header` from a non-empty `config[key]` string, transformed by `f`.
fn push_setting_header<'a>(
    headers: &mut Vec<(&'a str, JsonValue)>,
    config: Option<&JsonValue>,
    key: &str,
    header: &'a str,
    f: impl Fn(&str) -> String,
) {
    if let Some(value) = config.and_then(|c| get(c, key)).and_then(as_str) {
        if !value.is_empty() {
            headers.push((header, string(&sanitize_header(&f(value)))));
        }
    }
}

// ntfy metadata travels in HTTP headers; strip CR/LF so an operator-entered
// value can't inject extra header lines. Defense-in-depth — the host's HTTP
// client also rejects control characters in header values.
fn sanitize_header(value: &str) -> String {
    value.chars().filter(|c| *c != '\r' && *c != '\n').collect()
}

// ── Custom target (templated webhook) ───────────────────────────────────────
//
// A generic webhook: the operator supplies templates for the body, query
// params, and headers. Templates use `{{key}}` placeholders resolved against a
// flat context built from the event, its metadata, and the enriched media
// record. Query-param values are percent-encoded; the host gate still validates
// the (granted) URL host. See https://docs.ntfy.sh / Slack / Gotify etc.
fn custom_request(
    webhook_url: &str,
    config: Option<&JsonValue>,
    ctx: &HashMap<String, String>,
) -> JsonValue {
    let method = setting(config, "http_method").unwrap_or("POST");
    let content_type = setting(config, "content_type").unwrap_or("application/json");

    let body = setting(config, "body_template")
        .map(|t| render_template(t, ctx))
        .unwrap_or_default();

    let url = match setting(config, "query_template") {
        Some(q) => append_query(webhook_url, &render_query(q, ctx)),
        None => webhook_url.to_string(),
    };

    // content-type plus operator-templated headers and an optional bearer token.
    let mut headers: Vec<(String, JsonValue)> =
        vec![("content-type".to_string(), string(content_type))];

    if let Some(lines) = setting(config, "headers_template") {
        for line in lines.lines() {
            if let Some((name, value)) = line.split_once(':') {
                let name = name.trim();
                if !name.is_empty() {
                    let rendered = sanitize_header(&render_template(value.trim(), ctx));
                    headers.push((name.to_string(), string(&rendered)));
                }
            }
        }
    }

    if let Some(token) = setting(config, "auth_token") {
        headers.push((
            "authorization".to_string(),
            string(&sanitize_header(&format!("Bearer {token}"))),
        ));
    }

    object_owned(vec![
        ("url".to_string(), string(&url)),
        ("method".to_string(), string(method)),
        ("headers".to_string(), object_owned(headers)),
        ("body".to_string(), string(&body)),
    ])
}

// Reads a non-empty string setting from `config`, trimming nothing (templates
// may rely on leading whitespace). Returns None for absent or empty values.
fn setting<'a>(config: Option<&'a JsonValue>, key: &str) -> Option<&'a str> {
    config
        .and_then(|c| get(c, key))
        .and_then(as_str)
        .filter(|s| !s.is_empty())
}

// Flat `{{key}}` lookup table from the event payload. Scalars from the
// top-level event, its `metadata`, and the enriched media record are inserted
// by their bare key (enriched values win on collision, e.g. canonical title);
// `event_label` is the human verb and `poster` the absolute image URL.
fn build_context(
    event: &JsonValue,
    enriched: Option<&JsonValue>,
    verb: &str,
) -> HashMap<String, String> {
    let mut ctx = HashMap::new();

    for key in [
        "event",
        "category",
        "severity",
        "actor_type",
        "actor_id",
        "resource_type",
        "resource_id",
    ] {
        if let Some(v) = get(event, key) {
            if let Some(s) = scalar(v) {
                ctx.insert(key.to_string(), s);
            }
        }
    }

    if let Some(JsonValue::Object(metadata)) = get(event, "metadata") {
        flatten_into(&mut ctx, metadata);
    }
    if let Some(JsonValue::Object(media)) = enriched {
        flatten_into(&mut ctx, media);
    }

    ctx.insert("event_label".to_string(), verb.to_string());
    if let Some(poster) = enriched
        .and_then(|v| get(v, "poster_path"))
        .and_then(as_str)
    {
        if !poster.is_empty() {
            ctx.insert("poster".to_string(), poster_url(poster));
        }
    }
    ctx.entry("title".to_string())
        .or_insert_with(|| "Mydia".to_string());

    ctx
}

fn flatten_into(ctx: &mut HashMap<String, String>, map: &HashMap<String, JsonValue>) {
    for (k, v) in map {
        if let Some(s) = scalar(v) {
            ctx.insert(k.clone(), s);
        }
    }
}

// Renders a scalar JSON value to a string for templating. Arrays of scalars
// (e.g. genres) join with ", "; objects and null yield nothing.
fn scalar(v: &JsonValue) -> Option<String> {
    match v {
        JsonValue::String(s) => Some(s.clone()),
        JsonValue::Number(n) => Some(format_number(*n)),
        JsonValue::Boolean(b) => Some(b.to_string()),
        JsonValue::Array(items) => {
            let parts: Vec<String> = items.iter().filter_map(scalar).collect();
            Some(parts.join(", "))
        }
        _ => None,
    }
}

#[expect(
    clippy::cast_precision_loss,
    reason = "tinyjson stores every number as f64; media ids are far below 2^53"
)]
fn i64_to_f64(v: i64) -> f64 {
    v as f64
}

// tinyjson stores every number as f64; render integral values without a ".0".
fn format_number(n: f64) -> String {
    if n.fract() == 0.0 && n.abs() < 1e15 {
        #[expect(
            clippy::cast_possible_truncation,
            reason = "guarded by fract() == 0 and abs() < 1e15, so the value is integral and fits i64"
        )]
        let integral = n as i64;
        format!("{integral}")
    } else {
        format!("{n}")
    }
}

// Mustache-lite: replaces `{{key}}` (key trimmed) with its context value;
// unknown keys render empty. No conditionals or logic — substitution only.
fn render_template(template: &str, ctx: &HashMap<String, String>) -> String {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;

    while let Some(start) = rest.find("{{") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        if let Some(end) = after.find("}}") {
            let key = after[..end].trim();
            if let Some(value) = ctx.get(key) {
                out.push_str(value);
            }
            rest = &after[end + 2..];
        } else {
            // Unterminated placeholder: emit the remainder literally.
            out.push_str(&rest[start..]);
            return out;
        }
    }

    out.push_str(rest);
    out
}

// Renders a `k={{v}}&k2={{v2}}` template, templating and percent-encoding each
// value. Bare keys (no `=`) pass through unchanged.
fn render_query(template: &str, ctx: &HashMap<String, String>) -> String {
    template
        .split('&')
        .filter_map(|pair| {
            let pair = pair.trim();
            if pair.is_empty() {
                return None;
            }
            match pair.split_once('=') {
                Some((key, value)) => {
                    let key = key.trim();
                    if key.is_empty() {
                        return None;
                    }
                    let value = percent_encode(&render_template(value, ctx));
                    Some(format!("{key}={value}"))
                }
                None => Some(pair.to_string()),
            }
        })
        .collect::<Vec<_>>()
        .join("&")
}

fn append_query(url: &str, query: &str) -> String {
    if query.is_empty() {
        url.to_string()
    } else if url.contains('?') {
        format!("{url}&{query}")
    } else {
        format!("{url}?{query}")
    }
}

// Percent-encodes a query-parameter value per RFC 3986 unreserved set.
fn percent_encode(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for b in value.bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                let _ = write!(out, "%{b:02X}");
            }
        }
    }
    out
}

fn read_media(event: &JsonValue) -> Option<JsonValue> {
    if get(event, "resource_type").and_then(as_str) != Some("media_item") {
        return None;
    }
    let id = get(event, "resource_id").and_then(as_str)?;
    let resp = data_call(id);
    if get(&resp, "error").is_some() {
        None
    } else {
        Some(resp)
    }
}

// ── tinyjson helpers ────────────────────────────────────────────────────────

fn get<'a>(v: &'a JsonValue, key: &str) -> Option<&'a JsonValue> {
    match v {
        JsonValue::Object(m) => m.get(key),
        _ => None,
    }
}

fn as_str(v: &JsonValue) -> Option<&str> {
    match v {
        JsonValue::String(s) => Some(s.as_str()),
        _ => None,
    }
}

fn as_bool(v: &JsonValue) -> Option<bool> {
    match v {
        JsonValue::Boolean(b) => Some(*b),
        _ => None,
    }
}

fn as_num(v: &JsonValue) -> Option<f64> {
    match v {
        JsonValue::Number(n) => Some(*n),
        _ => None,
    }
}

fn string(s: &str) -> JsonValue {
    JsonValue::String(s.to_string())
}

fn object(pairs: Vec<(&str, JsonValue)>) -> JsonValue {
    let mut m: HashMap<String, JsonValue> = HashMap::new();
    for (k, v) in pairs {
        m.insert(k.to_string(), v);
    }
    JsonValue::Object(m)
}

// Like `object`, but for dynamically-named keys (e.g. operator header names).
fn object_owned(pairs: Vec<(String, JsonValue)>) -> JsonValue {
    let mut m: HashMap<String, JsonValue> = HashMap::new();
    for (k, v) in pairs {
        m.insert(k, v);
    }
    JsonValue::Object(m)
}

fn stringify(v: &JsonValue) -> String {
    v.stringify().unwrap_or_else(|_| "{}".to_string())
}

fn describe(event_type: &str) -> &'static str {
    match event_type {
        "media_item.added" => "Added to library",
        "media_item.updated" => "Updated",
        "media_item.removed" => "Removed from library",
        "media_file.imported" => "File imported",
        "download.completed" => "Download completed",
        "download.failed" => "Download failed",
        _ => "Event",
    }
}

fn poster_url(poster: &str) -> String {
    if poster.starts_with("http") {
        poster.to_string()
    } else {
        format!("https://image.tmdb.org/t/p/w500{poster}")
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn ctx() -> HashMap<String, String> {
        let mut m = HashMap::new();
        m.insert("title".to_string(), "The Matrix".to_string());
        m.insert("event".to_string(), "media_item.added".to_string());
        m
    }

    #[test]
    fn render_template_substitutes_and_blanks_missing() {
        let c = ctx();
        assert_eq!(render_template("{{title}}", &c), "The Matrix");
        assert_eq!(render_template("{{ title }} added", &c), "The Matrix added");
        // Unknown key renders empty, surrounding text preserved.
        assert_eq!(render_template("[{{nope}}]", &c), "[]");
        // Unterminated placeholder is emitted literally.
        assert_eq!(render_template("a {{title", &c), "a {{title");
        assert_eq!(render_template("no placeholders", &c), "no placeholders");
    }

    #[test]
    fn percent_encode_escapes_reserved() {
        assert_eq!(percent_encode("a b&c=d"), "a%20b%26c%3Dd");
        assert_eq!(percent_encode("Aa0-_.~"), "Aa0-_.~");
        assert_eq!(percent_encode("café"), "caf%C3%A9");
    }

    #[test]
    fn render_query_templates_and_encodes_values() {
        let c = ctx();
        assert_eq!(
            render_query("text={{title}}&kind={{event}}", &c),
            "text=The%20Matrix&kind=media_item.added"
        );
        // Bare key passes through; empty segments dropped.
        assert_eq!(render_query("ping&&x={{title}}", &c), "ping&x=The%20Matrix");
    }

    #[test]
    fn append_query_picks_separator() {
        assert_eq!(append_query("https://h/p", "a=1"), "https://h/p?a=1");
        assert_eq!(
            append_query("https://h/p?b=2", "a=1"),
            "https://h/p?b=2&a=1"
        );
        assert_eq!(append_query("https://h/p", ""), "https://h/p");
    }

    #[test]
    fn scalar_renders_numbers_and_arrays() {
        assert_eq!(scalar(&JsonValue::Number(2026.0)), Some("2026".to_string()));
        assert_eq!(scalar(&JsonValue::Number(7.5)), Some("7.5".to_string()));
        let genres = JsonValue::Array(vec![string("Sci-Fi"), string("Action")]);
        assert_eq!(scalar(&genres), Some("Sci-Fi, Action".to_string()));
        assert_eq!(scalar(&JsonValue::Null), None);
    }

    #[test]
    fn custom_request_builds_url_method_headers_body() {
        let config = object(vec![
            ("http_method", string("PUT")),
            ("content_type", string("text/plain")),
            ("body_template", string("{{title}} was added")),
            ("query_template", string("t={{title}}")),
            (
                "headers_template",
                string("X-Source: mydia\nX-Title: {{title}}"),
            ),
            ("auth_token", string("sekret")),
        ]);
        let c = ctx();

        let req = custom_request("https://hooks.example.com/x", Some(&config), &c);

        assert_eq!(
            get(&req, "url").and_then(as_str),
            Some("https://hooks.example.com/x?t=The%20Matrix")
        );
        assert_eq!(get(&req, "method").and_then(as_str), Some("PUT"));
        assert_eq!(
            get(&req, "body").and_then(as_str),
            Some("The Matrix was added")
        );

        let headers = get(&req, "headers").unwrap();
        assert_eq!(
            get(headers, "content-type").and_then(as_str),
            Some("text/plain")
        );
        assert_eq!(get(headers, "X-Source").and_then(as_str), Some("mydia"));
        assert_eq!(get(headers, "X-Title").and_then(as_str), Some("The Matrix"));
        assert_eq!(
            get(headers, "authorization").and_then(as_str),
            Some("Bearer sekret")
        );
    }

    #[test]
    fn custom_request_defaults_method_and_content_type() {
        let config = object(vec![("body_template", string("hi"))]);
        let c = ctx();
        let req = custom_request("https://h/x", Some(&config), &c);

        assert_eq!(get(&req, "method").and_then(as_str), Some("POST"));
        assert_eq!(get(&req, "url").and_then(as_str), Some("https://h/x"));
        let headers = get(&req, "headers").unwrap();
        assert_eq!(
            get(headers, "content-type").and_then(as_str),
            Some("application/json")
        );
    }

    #[test]
    fn build_context_flattens_event_metadata_and_media() {
        let event = object(vec![
            ("event", string("media_item.added")),
            ("resource_type", string("media_item")),
            (
                "metadata",
                object(vec![
                    ("title", string("Meta Title")),
                    ("year", JsonValue::Number(1999.0)),
                ]),
            ),
        ]);
        let enriched = object(vec![
            ("title", string("Canonical Title")),
            ("genres", JsonValue::Array(vec![string("Sci-Fi")])),
            ("poster_path", string("/p.jpg")),
        ]);

        let c = build_context(&event, Some(&enriched), "Added to library");

        // Enriched title wins over metadata title.
        assert_eq!(c.get("title").map(String::as_str), Some("Canonical Title"));
        assert_eq!(c.get("year").map(String::as_str), Some("1999"));
        assert_eq!(c.get("genres").map(String::as_str), Some("Sci-Fi"));
        assert_eq!(
            c.get("event_label").map(String::as_str),
            Some("Added to library")
        );
        assert_eq!(
            c.get("poster").map(String::as_str),
            Some("https://image.tmdb.org/t/p/w500/p.jpg")
        );
        assert_eq!(c.get("event").map(String::as_str), Some("media_item.added"));
    }
}
