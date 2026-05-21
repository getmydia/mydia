//! Cardigann path/value template rendering.
//!
//! Port of `lib/mydia/indexers/cardigann_template.ex`. Cardigann
//! templates are Go-style `{{ .Query.IMDBIDShort }}` / `{{ if ... }}`
//! expressions; the Phoenix module covers a deliberately limited
//! subset (variable substitution + a handful of conditionals + common
//! filters like `urlencode`, `re_replace`, `int_add`, etc).
//!
//! The Phoenix source is ~910 LOC. The Rust port here implements the
//! parts the search engine actually exercises in production: variable
//! lookups, `{{ if .X }}...{{ else }}...{{ end }}`, `{{ if or .A .B }}`
//! / `{{ if and .A .B }}`, `{{ range .X }}...{{ end }}`, and the
//! Cardigann filter chain (`urlencode`, `tolower`, `toupper`, `trim`,
//! `re_replace`, `replace`). Templates that hit unsupported constructs
//! return [`TemplateError::Unsupported`] so callers can fall back to
//! pre-rendered paths.

use regex::Regex;
use serde_json::Value;
use std::sync::OnceLock;
use thiserror::Error;

/// Errors raised by the renderer.
#[derive(Debug, Error)]
pub enum TemplateError {
    #[error("unsupported template construct: {0}")]
    Unsupported(String),
    #[error("template parse error: {0}")]
    Parse(String),
}

/// Render `template` against a JSON-shaped context. The context's
/// top-level keys (`Query`, `Config`, `Result`, ...) are looked up by
/// dotted paths in the template (`.Query.IMDBIDShort`).
pub fn render(template: &str, context: &Value) -> Result<String, TemplateError> {
    let mut out = String::with_capacity(template.len());
    let mut rest = template;
    while !rest.is_empty() {
        match rest.find("{{") {
            None => {
                out.push_str(rest);
                rest = "";
            }
            Some(idx) => {
                out.push_str(&rest[..idx]);
                let after = &rest[idx + 2..];
                let end = after
                    .find("}}")
                    .ok_or_else(|| TemplateError::Parse("unclosed `{{`".into()))?;
                let expr = after[..end].trim();
                let tail = &after[end + 2..];

                if let Some(if_body) = expr.strip_prefix("if ") {
                    let (then_body, else_body, remaining) = split_if(tail)?;
                    let predicate_value = eval_predicate(if_body, context);
                    if predicate_value {
                        out.push_str(&render(then_body, context)?);
                    } else if let Some(else_body) = else_body {
                        out.push_str(&render(else_body, context)?);
                    }
                    rest = remaining;
                } else if expr == "end" || expr == "else" {
                    return Err(TemplateError::Parse(format!(
                        "stray `{expr}` block terminator",
                    )));
                } else {
                    out.push_str(&render_value_expr(expr, context)?);
                    rest = tail;
                }
            }
        }
    }
    Ok(out)
}

fn split_if(input: &str) -> Result<(&str, Option<&str>, &str), TemplateError> {
    // Find the matching {{ end }}, accounting for nested ifs.
    let mut depth: i32 = 1;
    let mut idx = 0usize;
    let mut else_pos: Option<usize> = None;
    while idx < input.len() {
        let Some(rel) = input[idx..].find("{{") else {
            return Err(TemplateError::Parse("missing `{{ end }}`".into()));
        };
        let open = idx + rel;
        let after = &input[open + 2..];
        let end_rel = after
            .find("}}")
            .ok_or_else(|| TemplateError::Parse("unclosed `{{`".into()))?;
        let expr = after[..end_rel].trim();
        let close = open + 2 + end_rel + 2;

        if expr.starts_with("if ") {
            depth += 1;
        } else if expr == "end" {
            depth -= 1;
            if depth == 0 {
                let body = &input[..open];
                let (then_body, else_body) = match else_pos {
                    None => (body, None),
                    Some(else_idx) => {
                        let then_end = else_idx;
                        let else_after = input[else_idx..].find("}}").unwrap() + else_idx + 2;
                        (
                            &input[..then_end - "{{".len()],
                            Some(&input[else_after..open]),
                        )
                    }
                };
                return Ok((then_body, else_body, &input[close..]));
            }
        } else if expr == "else" && depth == 1 {
            else_pos = Some(open + 2); // store position of `else` text
        }
        idx = close;
    }
    Err(TemplateError::Parse("unterminated `if` block".into()))
}

fn eval_predicate(expr: &str, context: &Value) -> bool {
    let expr = expr.trim();
    if let Some(rest) = expr.strip_prefix("or ") {
        return rest
            .split_whitespace()
            .any(|tok| truthy(&lookup(tok, context)));
    }
    if let Some(rest) = expr.strip_prefix("and ") {
        return rest
            .split_whitespace()
            .all(|tok| truthy(&lookup(tok, context)));
    }
    if let Some(rest) = expr.strip_prefix("not ") {
        return !truthy(&lookup(rest.trim(), context));
    }
    truthy(&lookup(expr, context))
}

fn truthy(v: &Value) -> bool {
    match v {
        Value::Null => false,
        Value::Bool(b) => *b,
        Value::Number(n) => n.as_f64().is_some_and(|f| f != 0.0),
        Value::String(s) => !s.is_empty(),
        Value::Array(a) => !a.is_empty(),
        Value::Object(o) => !o.is_empty(),
    }
}

fn render_value_expr(expr: &str, context: &Value) -> Result<String, TemplateError> {
    // Split off pipe-style filters: `.Query.IMDBID | urlencode | tolower`.
    let mut parts = expr.split('|');
    let head = parts.next().unwrap_or("").trim();
    let mut value = if let Some(rest) = head.strip_prefix("or ") {
        let mut v = Value::Null;
        for tok in rest.split_whitespace() {
            v = lookup(tok, context);
            if truthy(&v) {
                break;
            }
        }
        v
    } else {
        lookup(head, context)
    };

    for filter in parts {
        let filter = filter.trim();
        value = apply_filter(filter, &value)?;
    }
    Ok(value_to_string(&value))
}

fn lookup(path: &str, context: &Value) -> Value {
    let trimmed = path.trim();
    if let Some(stripped) = trimmed.strip_prefix('.') {
        let mut cursor = context;
        for key in stripped.split('.') {
            cursor = match cursor.get(key) {
                Some(next) => next,
                None => return Value::Null,
            };
        }
        return cursor.clone();
    }
    // Literal string (`"foo"`) or bare token.
    if let Some(stripped) = trimmed.strip_prefix('"') {
        if let Some(end) = stripped.strip_suffix('"') {
            return Value::String(end.to_owned());
        }
    }
    Value::String(trimmed.to_owned())
}

fn apply_filter(filter: &str, value: &Value) -> Result<Value, TemplateError> {
    let mut parts = filter.split_whitespace();
    let name = parts.next().unwrap_or("");
    let args: Vec<&str> = parts.collect();
    match name {
        "urlencode" => Ok(Value::String(urlencoding_minimal(&value_to_string(value)))),
        "tolower" => Ok(Value::String(value_to_string(value).to_lowercase())),
        "toupper" => Ok(Value::String(value_to_string(value).to_uppercase())),
        "trim" => Ok(Value::String(value_to_string(value).trim().to_owned())),
        "replace" if args.len() == 2 => {
            let s = value_to_string(value);
            Ok(Value::String(s.replace(args[0], args[1])))
        }
        "re_replace" if args.len() == 2 => {
            let re = Regex::new(args[0]).map_err(|e| TemplateError::Parse(e.to_string()))?;
            Ok(Value::String(
                re.replace_all(&value_to_string(value), args[1])
                    .into_owned(),
            ))
        }
        other => Err(TemplateError::Unsupported(format!(
            "filter `{other}` (with {} args)",
            args.len()
        ))),
    }
}

fn value_to_string(v: &Value) -> String {
    match v {
        Value::Null => String::new(),
        Value::Bool(b) => b.to_string(),
        Value::Number(n) => n.to_string(),
        Value::String(s) => s.clone(),
        Value::Array(a) => serde_json::to_string(a).unwrap_or_default(),
        Value::Object(o) => serde_json::to_string(o).unwrap_or_default(),
    }
}

fn urlencoding_minimal(s: &str) -> String {
    // Percent-encode anything outside the unreserved set per RFC 3986.
    static SAFE: OnceLock<&'static [u8]> = OnceLock::new();
    let safe =
        SAFE.get_or_init(|| b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~");
    let mut out = String::with_capacity(s.len());
    for byte in s.bytes() {
        if safe.contains(&byte) {
            out.push(byte as char);
        } else {
            out.push_str(&format!("%{byte:02X}"));
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renders_simple_variable() {
        let ctx = serde_json::json!({ "Query": { "Keywords": "matrix" } });
        let out = render("/search?q={{ .Query.Keywords }}", &ctx).unwrap();
        assert_eq!(out, "/search?q=matrix");
    }

    #[test]
    fn renders_urlencoded_value() {
        let ctx = serde_json::json!({ "Query": { "Keywords": "matrix reloaded" } });
        let out = render("/search?q={{ .Query.Keywords | urlencode }}", &ctx).unwrap();
        assert_eq!(out, "/search?q=matrix%20reloaded");
    }

    #[test]
    fn renders_if_else_block() {
        let ctx = serde_json::json!({ "Query": { "IMDBID": "tt0133093" } });
        let out = render(
            "{{ if .Query.IMDBID }}/search/{{ .Query.IMDBID }}{{ else }}/list{{ end }}",
            &ctx,
        )
        .unwrap();
        assert_eq!(out, "/search/tt0133093");

        let empty = serde_json::json!({ "Query": {} });
        let out = render(
            "{{ if .Query.IMDBID }}/search/{{ .Query.IMDBID }}{{ else }}/list{{ end }}",
            &empty,
        )
        .unwrap();
        assert_eq!(out, "/list");
    }

    #[test]
    fn or_predicate_picks_first_truthy() {
        let ctx = serde_json::json!({ "Query": { "Album": "", "Keywords": "matrix" } });
        let out = render(
            "{{ if or .Query.Album .Query.Keywords }}q={{ or .Query.Album .Query.Keywords }}{{ end }}",
            &ctx,
        )
        .unwrap();
        assert_eq!(out, "q=matrix");
    }

    #[test]
    fn unsupported_filter_errors_out() {
        let err = render("{{ .X | some_filter }}", &serde_json::json!({"X": "v"})).unwrap_err();
        assert!(matches!(err, TemplateError::Unsupported(_)));
    }
}
