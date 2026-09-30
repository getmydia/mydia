//! Conversation memory kept in plugin KV under `conv:<user-id>`, as OpenAI chat
//! messages. Trimmed to fit one KV value.

use serde_json::{json, Value};

/// KV values are capped at 64 KiB; stay under it with room for encoding.
pub const MAX_BYTES: usize = 60_000;
/// Tool results are stored truncated: the model already used them.
pub const MAX_TOOL_CHARS: usize = 2_000;

pub fn key(user_id: &str) -> String {
    format!("conv:{user_id}")
}

pub fn decode(raw: Option<String>) -> Vec<Value> {
    raw.and_then(|s| serde_json::from_str::<Vec<Value>>(&s).ok()).unwrap_or_default()
}

/// Shrinks tool results, then drops whole oldest turns (a user message and
/// everything up to the next one) until the encoding fits.
pub fn encode(mut messages: Vec<Value>) -> String {
    for m in messages.iter_mut() {
        if m["role"] == "tool" {
            if let Some(c) = m["content"].as_str() {
                if c.chars().count() > MAX_TOOL_CHARS {
                    let cut: String = c.chars().take(MAX_TOOL_CHARS).collect();
                    m["content"] = json!(format!("{cut}…"));
                }
            }
        }
    }

    loop {
        let s = serde_json::to_string(&messages).unwrap_or_else(|_| "[]".into());
        if s.len() <= MAX_BYTES || messages.is_empty() {
            return s;
        }
        let next_user = messages.iter().skip(1).position(|m| m["role"] == "user").map(|i| i + 1);
        match next_user {
            Some(i) => {
                messages.drain(0..i);
            }
            None => messages.clear(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn roundtrip() {
        let msgs = vec![json!({"role":"user","content":"hi"}), json!({"role":"assistant","content":"hello"})];
        assert_eq!(decode(Some(encode(msgs.clone()))), msgs);
    }

    #[test]
    fn truncates_tool_results() {
        let big = "x".repeat(MAX_TOOL_CHARS + 50);
        let out = decode(Some(encode(vec![json!({"role":"tool","content":big,"tool_call_id":"1"})])));
        assert!(out[0]["content"].as_str().unwrap().chars().count() <= MAX_TOOL_CHARS + 1);
    }

    #[test]
    fn drops_oldest_turns_first() {
        let filler = "y".repeat(20_000);
        let msgs: Vec<Value> = (0..6)
            .flat_map(|i| vec![json!({"role":"user","content":format!("q{i}")}), json!({"role":"assistant","content":filler})])
            .collect();
        let out = decode(Some(encode(msgs)));
        assert!(serde_json::to_string(&out).unwrap().len() <= MAX_BYTES);
        assert_eq!(out[0]["role"], "user");
        assert_eq!(out.last().unwrap()["role"], "assistant");
        assert_ne!(out[0]["content"], "q0");
    }

    #[test]
    fn bad_json_is_empty() {
        assert!(decode(Some("nope".into())).is_empty());
        assert!(decode(None).is_empty());
    }
}
