//! OpenAI-compatible /chat/completions: request building and reply parsing.

use serde_json::{json, Value};

pub fn request_body(model: &str, messages: &[Value], tools: &Value) -> String {
    json!({ "model": model, "messages": messages, "tools": tools, "tool_choice": "auto" }).to_string()
}

pub struct ToolCall {
    pub id: String,
    pub name: String,
    /// Err carries the reason the model's arguments could not be used.
    pub arguments: Result<Value, String>,
}

pub enum Reply {
    Text { message: Value, text: String },
    Tools { message: Value, calls: Vec<ToolCall> },
}

/// Models send arguments as a JSON string; empty means no arguments. Anything
/// that does not decode to an object is an error the model gets to see.
fn parse_arguments(raw: &Value) -> Result<Value, String> {
    match raw {
        Value::Null => Ok(json!({})),
        Value::String(s) if s.trim().is_empty() => Ok(json!({})),
        Value::String(s) => match serde_json::from_str::<Value>(s) {
            Ok(v) if v.is_object() => Ok(v),
            _ => Err("invalid arguments: not a JSON object".into()),
        },
        Value::Object(_) => Ok(raw.clone()),
        _ => Err("invalid arguments".into()),
    }
}

/// Keeps only the fields the chat API needs when replaying a message, so
/// provider extras (reasoning traces, usage, refusals) are not stored.
pub fn sanitize(message: &Value) -> Value {
    let mut out = serde_json::Map::new();
    for k in ["role", "content", "tool_calls", "tool_call_id", "name"] {
        if let Some(v) = message.get(k) {
            out.insert(k.to_string(), v.clone());
        }
    }
    Value::Object(out)
}

pub fn parse_reply(status: u16, body: &str) -> Result<Reply, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| format!("The model server answered {status} with something that is not JSON."))?;
    if !(200..300).contains(&status) {
        let detail: String = v["error"]["message"].as_str().unwrap_or("no detail").chars().take(200).collect();
        return Err(format!("The model server answered {status}: {detail}"));
    }
    let message = sanitize(&v["choices"][0]["message"]);
    if v["choices"][0]["message"].is_null() {
        return Err("The model server returned no message.".into());
    }
    let calls: Vec<ToolCall> = message["tool_calls"]
        .as_array()
        .map(|arr| {
            arr.iter()
                .map(|c| ToolCall {
                    id: c["id"].as_str().unwrap_or("").to_string(),
                    name: c["function"]["name"].as_str().unwrap_or("").to_string(),
                    arguments: parse_arguments(&c["function"]["arguments"]),
                })
                .collect()
        })
        .unwrap_or_default();

    if calls.is_empty() {
        let text = message["content"].as_str().unwrap_or("").to_string();
        Ok(Reply::Text { message, text })
    } else {
        Ok(Reply::Tools { message, calls })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_body_carries_the_model() {
        let body: Value = serde_json::from_str(&request_body("m-1", &[json!({"role":"user","content":"hi"})], &json!([]))).unwrap();
        assert_eq!(body["model"], "m-1");
        assert_eq!(body["tool_choice"], "auto");
        assert_eq!(body["messages"][0]["content"], "hi");
    }

    #[test]
    fn parses_text_reply() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":"hi"}}]}"#;
        match parse_reply(200, body).unwrap() {
            Reply::Text { text, .. } => assert_eq!(text, "hi"),
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn parses_tool_calls() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":null,"tool_calls":[{"id":"c1","type":"function","function":{"name":"search_library","arguments":"{\"query\":\"x\"}"}}]}}]}"#;
        match parse_reply(200, body).unwrap() {
            Reply::Tools { calls, .. } => {
                assert_eq!(calls[0].name, "search_library");
                assert_eq!(calls[0].arguments.as_ref().unwrap()["query"], "x");
            }
            _ => panic!("expected tools"),
        }
    }

    #[test]
    fn malformed_arguments_are_an_error() {
        let body = r#"{"choices":[{"message":{"role":"assistant","tool_calls":[{"id":"c1","function":{"name":"list","arguments":"{oops"}}]}}]}"#;
        match parse_reply(200, body).unwrap() {
            Reply::Tools { calls, .. } => assert!(calls[0].arguments.is_err()),
            _ => panic!("expected tools"),
        }
    }

    #[test]
    fn empty_arguments_are_an_empty_object() {
        assert_eq!(parse_arguments(&json!("")).unwrap(), json!({}));
    }

    #[test]
    fn provider_extras_are_dropped() {
        let body = r#"{"choices":[{"message":{"role":"assistant","content":"hi","reasoning":"secret","refusal":null}}]}"#;
        match parse_reply(200, body).unwrap() {
            Reply::Text { message, .. } => {
                assert!(message.get("reasoning").is_none());
                assert_eq!(message["content"], "hi");
            }
            _ => panic!("expected text"),
        }
    }

    #[test]
    fn provider_error_detail_is_clipped() {
        let body = format!(r#"{{"error":{{"message":"{}"}}}}"#, "z".repeat(600));
        assert!(parse_reply(500, &body).err().unwrap().len() < 300);
    }

    #[test]
    fn surfaces_provider_errors() {
        let err = parse_reply(401, r#"{"error":{"message":"bad key"}}"#).err().unwrap();
        assert!(err.contains("401") && err.contains("bad key"));
    }
}
