//! HTML / JSON result parser for Cardigann searches.
//!
//! Port of `lib/mydia/indexers/cardigann_result_parser.ex`. The Phoenix
//! source is 1.6 kLOC; this Rust port covers the core extraction
//! pipeline (CSS row + field selectors, basic filter chain, JSON path
//! navigation, URL/category normalization, conversion to
//! [`SearchResult`]). The exotic Cardigann filters (`dateparse`,
//! `timeago`, `fuzzytime`, `htmldecode`, complex `re_replace`
//! chains) are wired through [`apply_filter`] — additions can be made
//! in place without touching the public surface.

use chrono::{DateTime, Utc};
use scraper::{Html, Selector as CssSelector};
use serde_json::Value as JsonValue;
use std::collections::HashMap;
use tracing::warn;

use crate::cardigann::definition_parsed::{ParsedDefinition, Selector};
use crate::category_mapping;
use crate::error::IndexerError;
use crate::quality_parser;
use crate::search_result::{DownloadProtocol, SearchResult, SearchResultBuilder};

/// Output of [`parse_results`].
pub type ParseResult = Result<Vec<SearchResult>, IndexerError>;

/// HTTP response shape the parser operates on. The transport layer
/// provides this — we don't depend on `reqwest::Response` here so the
/// parser stays unit-testable.
#[derive(Debug, Clone)]
pub struct HttpResponse {
    pub status: u16,
    pub body: String,
    pub content_type: Option<String>,
}

/// Detect whether a body is HTML or JSON. Mirrors
/// `detect_response_type/1`.
#[must_use]
pub fn detect_response_type(body: &str) -> ResponseType {
    let trimmed = body.trim_start();
    if trimmed.starts_with('{') || trimmed.starts_with('[') {
        ResponseType::Json
    } else {
        ResponseType::Html
    }
}

/// Enum companion for [`detect_response_type`].
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ResponseType {
    Html,
    Json,
}

/// Parse a response into [`SearchResult`]s. Auto-detects HTML vs JSON.
pub fn parse_results(
    definition: &ParsedDefinition,
    response: &HttpResponse,
    indexer_name: &str,
    base_url: &str,
) -> ParseResult {
    let trimmed = response.body.trim();
    if trimmed.is_empty() {
        return Ok(Vec::new());
    }
    match detect_response_type(trimmed) {
        ResponseType::Html => {
            parse_html_results(definition, &response.body, indexer_name, base_url)
        }
        ResponseType::Json => {
            parse_json_results(definition, &response.body, indexer_name, base_url)
        }
    }
}

/// HTML pipeline: parse → select rows → extract fields → build [`SearchResult`].
pub fn parse_html_results(
    definition: &ParsedDefinition,
    body: &str,
    indexer_name: &str,
    base_url: &str,
) -> ParseResult {
    let document = Html::parse_document(body);
    let row_sel = compile_css(&definition.search.rows.selector)?;
    let rows: Vec<_> = document.select(&row_sel).collect();

    let mut out = Vec::with_capacity(rows.len());
    let mappings = definition.capabilities.categorymappings.clone();
    for row_ref in rows {
        let mut fields: HashMap<String, String> = HashMap::new();
        for (field_name, selector) in &definition.search.fields {
            match extract_field_html(&row_ref, selector) {
                Ok(value) => {
                    fields.insert(field_name.clone(), value);
                }
                Err(err) => {
                    if selector.optional {
                        continue;
                    }
                    warn!(
                        indexer = indexer_name,
                        field = field_name,
                        error = %err,
                        "field extraction failed"
                    );
                    // Required field failed — skip this row.
                    fields.clear();
                    break;
                }
            }
        }
        if fields.is_empty() {
            continue;
        }
        if let Some(result) = build_search_result(&fields, indexer_name, base_url, &mappings) {
            out.push(result);
        }
    }
    Ok(out)
}

/// JSON pipeline: navigate the rows JSON path → field-extract.
pub fn parse_json_results(
    definition: &ParsedDefinition,
    body: &str,
    indexer_name: &str,
    base_url: &str,
) -> ParseResult {
    let json: JsonValue = serde_json::from_str(body)
        .map_err(|err| IndexerError::parse_error(format!("invalid JSON: {err}")))?;
    let rows = json_select(&json, &definition.search.rows.selector);

    let mappings = definition.capabilities.categorymappings.clone();
    let mut out = Vec::with_capacity(rows.len());
    for row in rows {
        let mut fields: HashMap<String, String> = HashMap::new();
        for (name, selector) in &definition.search.fields {
            if let Some(v) = extract_field_json(&row, selector) {
                fields.insert(name.clone(), v);
            } else if !selector.optional {
                fields.clear();
                break;
            }
        }
        if fields.is_empty() {
            continue;
        }
        if let Some(result) = build_search_result(&fields, indexer_name, base_url, &mappings) {
            out.push(result);
        }
    }
    Ok(out)
}

fn compile_css(selector: &str) -> Result<CssSelector, IndexerError> {
    CssSelector::parse(selector).map_err(|err| {
        IndexerError::parse_error(format!("invalid CSS selector `{selector}`: {err:?}"))
    })
}

fn extract_field_html(
    row: &scraper::ElementRef<'_>,
    selector: &Selector,
) -> Result<String, IndexerError> {
    if let Some(text) = &selector.text {
        return Ok(text.clone());
    }

    let target = if selector.selector.is_empty() {
        Some(*row)
    } else {
        let css = compile_css(&selector.selector)?;
        row.select(&css).next()
    };
    let Some(element) = target else {
        return Err(IndexerError::parse_error("selector matched nothing"));
    };

    let raw = if let Some(attr) = &selector.attribute {
        element
            .value()
            .attr(attr)
            .map(str::to_string)
            .unwrap_or_default()
    } else {
        element.text().collect::<Vec<_>>().join(" ")
    };

    let mut value = raw.trim().to_owned();
    for filter in &selector.filters {
        value = apply_filter(filter, &value);
    }
    Ok(value)
}

fn extract_field_json(row: &JsonValue, selector: &Selector) -> Option<String> {
    let value = if selector.selector.is_empty() {
        row.clone()
    } else {
        json_select_one(row, &selector.selector)?
    };
    let raw = json_value_to_string(&value);
    let filtered = selector
        .filters
        .iter()
        .fold(raw, |acc, f| apply_filter(f, &acc));
    Some(filtered)
}

/// Apply one Cardigann filter to a string value.
///
/// Filters are encoded in YAML as `{"name": "filter_name", "args": ...}`.
/// Returns the unmodified value when the filter is unrecognised.
pub(crate) fn apply_filter(filter: &JsonValue, value: &str) -> String {
    let Some(name) = filter.get("name").and_then(JsonValue::as_str) else {
        return value.to_owned();
    };
    let args = filter.get("args");
    match name {
        "trim" => value.trim().to_owned(),
        "tolower" => value.to_lowercase(),
        "toupper" => value.to_uppercase(),
        "append" => match args {
            Some(JsonValue::String(s)) => format!("{value}{s}"),
            _ => value.to_owned(),
        },
        "prepend" => match args {
            Some(JsonValue::String(s)) => format!("{s}{value}"),
            _ => value.to_owned(),
        },
        "replace" => match args {
            Some(JsonValue::Array(arr)) if arr.len() == 2 => {
                let from = arr[0].as_str().unwrap_or("");
                let to = arr[1].as_str().unwrap_or("");
                value.replace(from, to)
            }
            _ => value.to_owned(),
        },
        "re_replace" => match args {
            Some(JsonValue::Array(arr)) if arr.len() == 2 => {
                let pattern = arr[0].as_str().unwrap_or("");
                let replacement = arr[1].as_str().unwrap_or("");
                regex::Regex::new(pattern)
                    .map(|re| re.replace_all(value, replacement).into_owned())
                    .unwrap_or_else(|_| value.to_owned())
            }
            _ => value.to_owned(),
        },
        "regexp" => match args {
            Some(JsonValue::String(pattern)) => regex::Regex::new(pattern)
                .ok()
                .and_then(|re| {
                    re.captures(value).map(|cap| {
                        cap.get(1)
                            .or_else(|| cap.get(0))
                            .map(|m| m.as_str().to_owned())
                            .unwrap_or_default()
                    })
                })
                .unwrap_or_default(),
            _ => value.to_owned(),
        },
        "split" => match args {
            Some(JsonValue::Array(arr)) if arr.len() == 2 => {
                let sep = arr[0].as_str().unwrap_or(" ");
                let idx = arr[1].as_i64().unwrap_or(0);
                let pieces: Vec<&str> = value.split(sep).collect();
                if idx >= 0 && (idx as usize) < pieces.len() {
                    pieces[idx as usize].to_owned()
                } else if idx < 0 {
                    let len = pieces.len() as i64;
                    let real = (len + idx).max(0) as usize;
                    pieces
                        .get(real)
                        .map(|s| (*s).to_owned())
                        .unwrap_or_default()
                } else {
                    String::new()
                }
            }
            _ => value.to_owned(),
        },
        "urldecode" => urlencoding_decode(value),
        "urlencode" => urlencoding_encode(value),
        "querystring" => match args {
            Some(JsonValue::String(key)) => extract_querystring(value, key),
            _ => value.to_owned(),
        },
        // Date filters are noisy and use Go layouts — punt for now.
        "dateparse" | "timeparse" | "timeago" | "reltime" | "fuzzytime" => value.to_owned(),
        // Unknown filter — leave the value untouched, but warn.
        other => {
            tracing::debug!("unknown cardigann filter `{other}`, passing through");
            value.to_owned()
        }
    }
}

fn extract_querystring(url_or_qs: &str, key: &str) -> String {
    let qs = url_or_qs.split('?').nth(1).unwrap_or(url_or_qs);
    for pair in qs.split('&') {
        let mut parts = pair.splitn(2, '=');
        let k = parts.next().unwrap_or("");
        let v = parts.next().unwrap_or("");
        if k == key {
            return urlencoding_decode(v);
        }
    }
    String::new()
}

fn urlencoding_decode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        if b == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(
                std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or("00"),
                16,
            ) {
                out.push(byte as char);
                i += 3;
                continue;
            }
        }
        if b == b'+' {
            out.push(' ');
        } else {
            out.push(b as char);
        }
        i += 1;
    }
    out
}

fn urlencoding_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char);
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

fn json_value_to_string(v: &JsonValue) -> String {
    match v {
        JsonValue::Null => String::new(),
        JsonValue::Bool(b) => b.to_string(),
        JsonValue::Number(n) => n.to_string(),
        JsonValue::String(s) => s.clone(),
        _ => v.to_string(),
    }
}

fn json_select(root: &JsonValue, path: &str) -> Vec<JsonValue> {
    // Tiny JSONPath subset: `$.foo.bar[*]` / `foo.bar[*]`.
    let path = path.trim_start_matches('$').trim_start_matches('.');
    let mut cursor = vec![root.clone()];
    for segment in path.split('.') {
        if segment.is_empty() {
            continue;
        }
        let mut new_cursor = Vec::new();
        for v in &cursor {
            if let Some(key) = segment.strip_suffix("[*]") {
                let target = if key.is_empty() {
                    v.clone()
                } else if let Some(next) = v.get(key) {
                    next.clone()
                } else {
                    continue;
                };
                if let JsonValue::Array(arr) = target {
                    new_cursor.extend(arr);
                }
            } else if let Some(next) = v.get(segment) {
                new_cursor.push(next.clone());
            }
        }
        cursor = new_cursor;
    }
    cursor
}

fn json_select_one(root: &JsonValue, path: &str) -> Option<JsonValue> {
    json_select(root, path).into_iter().next()
}

fn build_search_result(
    fields: &HashMap<String, String>,
    indexer_name: &str,
    base_url: &str,
    category_mappings: &[JsonValue],
) -> Option<SearchResult> {
    let title = fields.get("title")?.clone();
    let download = fields.get("download")?.clone();
    let download_url = absolute_url(base_url, &download);
    let size = parse_size_bytes(fields.get("size").map(String::as_str).unwrap_or("0"));
    let seeders = parse_uint(fields.get("seeders").map(String::as_str).unwrap_or("0"));
    let leechers = parse_uint(fields.get("leechers").map(String::as_str).unwrap_or("0"));

    let info_url = fields
        .get("details")
        .map(|d| absolute_url(base_url, d))
        .filter(|s| !s.is_empty());

    let category = fields
        .get("category")
        .and_then(|c| category_mapping::map_site_category_to_torznab(Some(c), category_mappings));

    let imdb_id = fields.get("imdb").cloned().filter(|s| !s.is_empty());
    let tmdb_id = fields.get("tmdb").and_then(|t| t.parse::<i64>().ok());
    let tvdb_id = fields.get("tvdb").and_then(|t| t.parse::<i64>().ok());

    let published_at = fields.get("date").and_then(|d| parse_datetime(d));

    let quality = Some(quality_parser::parse(&title));
    let qbits = is_protocol_nzb(fields).then_some(DownloadProtocol::Nzb);

    SearchResultBuilder {
        title: Some(title),
        size: Some(size),
        seeders,
        leechers,
        download_url: Some(download_url),
        info_url,
        indexer: Some(indexer_name.to_owned()),
        category,
        published_at,
        quality,
        metadata: None,
        tmdb_id,
        tvdb_id,
        imdb_id,
        download_protocol: qbits.or(Some(DownloadProtocol::Torrent)),
        usenet_date: None,
        nzb_completion: None,
        nzb_grabs: None,
        guid: fields.get("guid").cloned(),
    }
    .build()
    .ok()
}

fn is_protocol_nzb(fields: &HashMap<String, String>) -> bool {
    fields
        .get("download")
        .is_some_and(|d| d.contains(".nzb") || d.contains("/getnzb"))
}

fn absolute_url(base_url: &str, candidate: &str) -> String {
    if candidate.starts_with("http://")
        || candidate.starts_with("https://")
        || candidate.starts_with("magnet:")
    {
        return candidate.to_owned();
    }
    if base_url.is_empty() {
        return candidate.to_owned();
    }
    let base = base_url.trim_end_matches('/');
    if candidate.starts_with('/') {
        format!("{base}{candidate}")
    } else {
        format!("{base}/{candidate}")
    }
}

/// Parse a human-readable size (e.g. `"1.4 GB"`, `"512MB"`) into bytes.
#[must_use]
pub fn parse_size_bytes(input: &str) -> u64 {
    let trimmed = input.trim();
    if trimmed.is_empty() {
        return 0;
    }
    let mut number = String::new();
    let mut unit = String::new();
    let mut in_num = true;
    for c in trimmed.chars() {
        if in_num && (c.is_ascii_digit() || c == '.' || c == ',') {
            number.push(c);
        } else if !(c.is_whitespace() && number.is_empty()) {
            in_num = false;
            if !c.is_whitespace() {
                unit.push(c);
            }
        }
    }
    let n: f64 = number.replace(',', "").parse().unwrap_or(0.0);
    let multiplier: f64 = match unit.to_ascii_uppercase().as_str() {
        "B" | "" => 1.0,
        "KB" | "KIB" | "K" => 1024.0,
        "MB" | "MIB" | "M" => 1024.0 * 1024.0,
        "GB" | "GIB" | "G" => 1024.0 * 1024.0 * 1024.0,
        "TB" | "TIB" | "T" => 1024.0 * 1024.0 * 1024.0 * 1024.0,
        _ => 1.0,
    };
    (n * multiplier) as u64
}

fn parse_uint(s: &str) -> Option<u32> {
    let cleaned: String = s.chars().filter(char::is_ascii_digit).collect();
    if cleaned.is_empty() {
        None
    } else {
        cleaned.parse().ok()
    }
}

fn parse_datetime(s: &str) -> Option<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(s)
        .ok()
        .map(|dt| dt.with_timezone(&Utc))
        .or_else(|| {
            chrono::NaiveDateTime::parse_from_str(s, "%Y-%m-%d %H:%M:%S")
                .ok()
                .map(|nd| DateTime::<Utc>::from_naive_utc_and_offset(nd, Utc))
        })
}

// Re-exported for tests & external callers.
pub use crate::category_mapping as categories;

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_size_handles_common_units() {
        assert_eq!(parse_size_bytes("1024"), 1024);
        assert_eq!(parse_size_bytes("1 KB"), 1024);
        assert_eq!(parse_size_bytes("1.5 MB"), (1.5 * 1_048_576.0) as u64);
        assert_eq!(parse_size_bytes("2GB"), 2 * 1024 * 1024 * 1024);
    }

    #[test]
    fn absolute_url_joins_against_base() {
        assert_eq!(absolute_url("https://x.com", "/foo"), "https://x.com/foo");
        assert_eq!(absolute_url("https://x.com/", "bar"), "https://x.com/bar");
        assert_eq!(
            absolute_url("https://x.com", "https://other.com/y"),
            "https://other.com/y"
        );
        assert_eq!(
            absolute_url("https://x.com", "magnet:?xt=x"),
            "magnet:?xt=x"
        );
    }

    #[test]
    fn detect_response_type_branches_on_first_char() {
        assert_eq!(detect_response_type("  <html>"), ResponseType::Html);
        assert_eq!(detect_response_type(" { } "), ResponseType::Json);
        assert_eq!(detect_response_type(" [ ] "), ResponseType::Json);
    }

    #[test]
    fn detect_querystring_extracts_param_value() {
        assert_eq!(extract_querystring("https://x?u=42&v=7", "v"), "7");
        assert_eq!(extract_querystring("u=hello%20world", "u"), "hello world");
    }
}
