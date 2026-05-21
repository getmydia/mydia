//! YAML → [`ParsedDefinition`].
//!
//! Port of `lib/mydia/indexers/cardigann_parser.ex`. The Phoenix code
//! relies on the dynamic-typing of `Map.fetch!` for the validation
//! step; we do the same here with `serde_yaml::Value` indexing so the
//! error taxonomy survives the port.

use serde_yaml::Value;
use std::collections::BTreeMap;

use crate::cardigann::definition_parsed::{
    Capabilities, DownloadConfig, LoginConfig, ParsedDefinition, SearchConfig, SearchPath,
    Selector, Setting,
};
use crate::cardigann::overrides;
use crate::error::IndexerError;

/// Parse a Cardigann YAML string into a [`ParsedDefinition`]. Applies
/// any registered overrides for known upstream bugs before extracting
/// the struct.
pub fn parse_definition(yaml_str: &str) -> Result<ParsedDefinition, IndexerError> {
    let mut yaml: Value = serde_yaml::from_str(yaml_str)
        .map_err(|err| IndexerError::parse_error(format!("invalid YAML: {err}")))?;

    if let Some(id) = yaml.get("id").and_then(Value::as_str) {
        let id = id.to_owned();
        overrides::apply(&id, &mut yaml);
    }

    let parsed = build_parsed(&yaml)?;
    validate(&parsed)?;
    Ok(parsed)
}

fn build_parsed(yaml: &Value) -> Result<ParsedDefinition, IndexerError> {
    let search = parse_search_config(yaml)?;
    let login = parse_login_config(yaml)?;
    let capabilities = parse_capabilities(yaml)?;

    let id = required_str(yaml, "id")?;
    let name = required_str(yaml, "name")?;
    let description = required_str(yaml, "description")?;
    let language = required_str(yaml, "language")?;
    let r#type = required_str(yaml, "type")?;
    let encoding = required_str(yaml, "encoding")?;
    let links = extract_links(yaml)?;

    Ok(ParsedDefinition {
        id,
        name,
        description,
        language,
        r#type,
        encoding,
        links,
        capabilities,
        search,
        login,
        download: parse_download_config(yaml),
        settings: parse_settings(yaml),
        request_delay: yaml.get("requestdelay").and_then(Value::as_f64),
        follow_redirect: yaml
            .get("followredirect")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        test_link_torrent: yaml
            .get("testlinktorrent")
            .and_then(Value::as_bool)
            .unwrap_or(false),
        certificates: extract_string_seq(yaml.get("certificates")),
        replaces: extract_string_seq(yaml.get("replaces")),
    })
}

fn required_str(yaml: &Value, key: &str) -> Result<String, IndexerError> {
    yaml.get(key)
        .and_then(Value::as_str)
        .map(str::to_string)
        .ok_or_else(|| IndexerError::parse_error(format!("missing required field `{key}`")))
}

fn extract_links(yaml: &Value) -> Result<Vec<String>, IndexerError> {
    let Some(v) = yaml.get("links") else {
        return Err(IndexerError::parse_error("missing required field `links`"));
    };
    match v {
        Value::Sequence(seq) => Ok(seq
            .iter()
            .filter_map(|item| item.as_str().map(str::to_string))
            .collect()),
        Value::String(s) => Ok(vec![s.clone()]),
        _ => Err(IndexerError::parse_error("`links` must be string or list")),
    }
}

fn extract_string_seq(v: Option<&Value>) -> Vec<String> {
    match v {
        Some(Value::Sequence(seq)) => seq
            .iter()
            .filter_map(|item| item.as_str().map(str::to_string))
            .collect(),
        Some(Value::String(s)) => vec![s.clone()],
        _ => Vec::new(),
    }
}

fn parse_search_config(yaml: &Value) -> Result<SearchConfig, IndexerError> {
    let search = yaml
        .get("search")
        .ok_or_else(|| IndexerError::parse_error("missing required field `search`"))?;

    let paths = extract_search_paths(search)?;
    let rows = extract_rows_selector(search)?;
    let fields = extract_field_selectors(search)?;

    Ok(SearchConfig {
        paths,
        inputs: search
            .get("inputs")
            .map(yaml_to_json)
            .unwrap_or(serde_json::Value::Null),
        headers: search.get("headers").map(yaml_to_json),
        keywords_filters: search
            .get("keywordsfilters")
            .map(yaml_to_json)
            .and_then(|v| {
                if let serde_json::Value::Array(a) = v {
                    Some(a)
                } else {
                    None
                }
            })
            .unwrap_or_default(),
        rows,
        fields,
    })
}

fn extract_search_paths(search: &Value) -> Result<Vec<SearchPath>, IndexerError> {
    if let Some(p) = search.get("path").and_then(Value::as_str) {
        return Ok(vec![SearchPath {
            path: p.to_string(),
            categories: Vec::new(),
            method: "get".into(),
        }]);
    }

    let Some(paths) = search.get("paths") else {
        return Err(IndexerError::parse_error(
            "missing required field `search.path` or `search.paths`",
        ));
    };
    let Value::Sequence(seq) = paths else {
        return Err(IndexerError::parse_error(
            "`search.paths` must be a sequence",
        ));
    };

    Ok(seq
        .iter()
        .filter_map(|entry| match entry {
            Value::String(s) => Some(SearchPath {
                path: s.clone(),
                categories: Vec::new(),
                method: "get".into(),
            }),
            Value::Mapping(_) => {
                let path = entry.get("path").and_then(Value::as_str)?.to_owned();
                let categories = entry
                    .get("categories")
                    .map(yaml_to_json)
                    .and_then(|v| {
                        if let serde_json::Value::Array(a) = v {
                            Some(a)
                        } else {
                            None
                        }
                    })
                    .unwrap_or_default();
                let method = entry
                    .get("method")
                    .and_then(Value::as_str)
                    .unwrap_or("get")
                    .to_owned();
                Some(SearchPath {
                    path,
                    categories,
                    method,
                })
            }
            _ => None,
        })
        .collect())
}

fn extract_rows_selector(search: &Value) -> Result<Selector, IndexerError> {
    let Some(rows) = search.get("rows") else {
        return Err(IndexerError::parse_error(
            "missing required field `search.rows`",
        ));
    };

    let mut sel = normalize_selector(rows);
    if let Value::Mapping(_) = rows {
        if let Some(after) = rows.get("after").and_then(Value::as_i64) {
            sel.after = Some(after as i32);
        }
        if let Some(count) = rows.get("count").and_then(Value::as_i64) {
            sel.count = Some(count as i32);
        }
    }
    Ok(sel)
}

fn extract_field_selectors(search: &Value) -> Result<BTreeMap<String, Selector>, IndexerError> {
    let Some(fields) = search.get("fields") else {
        return Err(IndexerError::parse_error(
            "missing required field `search.fields`",
        ));
    };
    let Value::Mapping(map) = fields else {
        return Err(IndexerError::parse_error(
            "`search.fields` must be a mapping",
        ));
    };

    let mut out = BTreeMap::new();
    for (k, v) in map {
        let Some(key) = k.as_str() else { continue };
        out.insert(key.to_owned(), normalize_selector(v));
    }
    Ok(out)
}

fn normalize_selector(v: &Value) -> Selector {
    match v {
        Value::String(s) => Selector {
            selector: s.clone(),
            ..Selector::default()
        },
        Value::Mapping(_) => {
            let mut sel = Selector::default();
            if let Some(s) = v.get("selector").and_then(Value::as_str) {
                s.clone_into(&mut sel.selector);
            }
            sel.attribute = v
                .get("attribute")
                .and_then(Value::as_str)
                .map(str::to_string);
            sel.remove = v.get("remove").and_then(Value::as_str).map(str::to_string);
            sel.case = v.get("case").map(yaml_to_json);
            sel.filters = v
                .get("filters")
                .map(yaml_to_json)
                .and_then(|j| {
                    if let serde_json::Value::Array(a) = j {
                        Some(a)
                    } else {
                        None
                    }
                })
                .unwrap_or_default();
            sel.text = v.get("text").and_then(Value::as_str).map(str::to_string);
            sel.optional = v.get("optional").and_then(Value::as_bool).unwrap_or(false);
            sel
        }
        _ => Selector::default(),
    }
}

fn parse_login_config(yaml: &Value) -> Result<Option<LoginConfig>, IndexerError> {
    let Some(login) = yaml.get("login") else {
        return Ok(None);
    };
    if !matches!(login, Value::Mapping(_)) {
        return Err(IndexerError::parse_error("`login` must be a mapping"));
    }

    let method = login
        .get("method")
        .and_then(Value::as_str)
        .ok_or_else(|| IndexerError::parse_error("missing `login.method`"))?
        .to_owned();

    let cookies = extract_string_seq(login.get("cookies"));
    let error: Vec<Selector> = match login.get("error") {
        None => Vec::new(),
        Some(Value::Sequence(seq)) => seq.iter().map(normalize_selector).collect(),
        Some(other) => vec![normalize_selector(other)],
    };

    Ok(Some(LoginConfig {
        method,
        path: login
            .get("path")
            .and_then(Value::as_str)
            .map(str::to_string),
        submitpath: login
            .get("submitpath")
            .and_then(Value::as_str)
            .map(str::to_string),
        inputs: login
            .get("inputs")
            .map(yaml_to_json)
            .unwrap_or(serde_json::Value::Null),
        error,
        test: login.get("test").map(yaml_to_json),
        cookies,
        captcha: login.get("captcha").map(yaml_to_json),
    }))
}

fn parse_download_config(yaml: &Value) -> Option<DownloadConfig> {
    let download = yaml.get("download")?;
    let selectors: Vec<Selector> = match download.get("selectors") {
        None => Vec::new(),
        Some(Value::Sequence(seq)) => seq.iter().map(normalize_selector).collect(),
        Some(other) => vec![normalize_selector(other)],
    };
    let infohash = download.get("infohash").map(normalize_selector);
    Some(DownloadConfig {
        selectors,
        before: download.get("before").map(yaml_to_json),
        method: download
            .get("method")
            .and_then(Value::as_str)
            .unwrap_or("get")
            .to_owned(),
        infohash,
    })
}

fn parse_settings(yaml: &Value) -> Vec<Setting> {
    let Some(Value::Sequence(seq)) = yaml.get("settings") else {
        return Vec::new();
    };
    seq.iter()
        .filter_map(|entry| {
            let name = entry.get("name").and_then(Value::as_str)?.to_owned();
            let r#type = entry.get("type").and_then(Value::as_str)?.to_owned();
            Some(Setting {
                name,
                r#type,
                label: entry
                    .get("label")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_owned(),
                default: entry.get("default").map(yaml_to_json),
                options: entry.get("options").map(yaml_to_json),
            })
        })
        .collect()
}

fn parse_capabilities(yaml: &Value) -> Result<Capabilities, IndexerError> {
    let Some(caps) = yaml.get("caps") else {
        return Err(IndexerError::parse_error("missing required field `caps`"));
    };
    let categorymappings: Vec<serde_json::Value> = match caps.get("categorymappings") {
        Some(Value::Sequence(seq)) => seq.iter().map(yaml_to_json).collect(),
        _ => Vec::new(),
    };
    Ok(Capabilities {
        modes: caps
            .get("modes")
            .map(yaml_to_json)
            .unwrap_or(serde_json::Value::Null),
        categories: caps
            .get("categories")
            .map(yaml_to_json)
            .unwrap_or(serde_json::Value::Null),
        categorymappings,
    })
}

fn validate(parsed: &ParsedDefinition) -> Result<(), IndexerError> {
    // Required search field selectors per Cardigann v11.
    for field in &["title", "size", "seeders"] {
        if !parsed.search.fields.contains_key(*field) {
            return Err(IndexerError::parse_error(format!(
                "missing required search.fields.{field}"
            )));
        }
    }
    // `caps.modes` must be present.
    if parsed.capabilities.modes.is_null() {
        return Err(IndexerError::parse_error("missing `caps.modes`"));
    }
    Ok(())
}

fn yaml_to_json(v: &Value) -> serde_json::Value {
    match v {
        Value::Null => serde_json::Value::Null,
        Value::Bool(b) => serde_json::Value::Bool(*b),
        Value::Number(n) => {
            if let Some(i) = n.as_i64() {
                serde_json::Value::from(i)
            } else if let Some(u) = n.as_u64() {
                serde_json::Value::from(u)
            } else if let Some(f) = n.as_f64() {
                serde_json::Value::from(f)
            } else {
                serde_json::Value::Null
            }
        }
        Value::String(s) => serde_json::Value::from(s.clone()),
        Value::Sequence(seq) => serde_json::Value::Array(seq.iter().map(yaml_to_json).collect()),
        Value::Mapping(map) => {
            let mut obj = serde_json::Map::new();
            for (k, v) in map {
                let key = match k {
                    Value::String(s) => s.clone(),
                    other => format!("{other:?}"),
                };
                obj.insert(key, yaml_to_json(v));
            }
            serde_json::Value::Object(obj)
        }
        Value::Tagged(tag) => yaml_to_json(&tag.value),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const MINIMAL: &str = r"
id: example
name: Example
description: An example indexer
language: en-US
type: public
encoding: UTF-8
links:
  - https://example.com
caps:
  modes:
    search:
      - q
  categorymappings: []
search:
  path: /search
  rows:
    selector: .row
  fields:
    title:
      selector: .title
    download:
      selector: a
      attribute: href
    size:
      selector: .size
    seeders:
      selector: .seeders
";

    #[test]
    fn parses_minimal_definition() {
        let p = parse_definition(MINIMAL).unwrap();
        assert_eq!(p.id, "example");
        assert_eq!(p.search.fields.len(), 4);
        assert_eq!(p.search.paths.len(), 1);
        assert_eq!(p.search.paths[0].path, "/search");
    }

    #[test]
    fn missing_required_field_errors() {
        let no_id = MINIMAL.replace("id: example\n", "");
        let err = parse_definition(&no_id).unwrap_err();
        assert_eq!(err.kind, crate::error::ErrorKind::ParseError);
    }
}
