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

/// Marks the assistant-role bookkeeping line stored after the user decides on
/// pending writes (see `outcome_note` in lib.rs).
pub const OUTCOME_PREFIX: &str = "[host outcome] ";

/// The stored conversation as the page shows it: user and assistant text, with
/// write outcomes turned into counts. Tool traffic and empty messages are dropped.
pub fn transcript(messages: &[Value]) -> Vec<Value> {
    messages.iter().filter_map(display_turn).collect()
}

fn display_turn(m: &Value) -> Option<Value> {
    let text = m["content"].as_str().filter(|s| !s.trim().is_empty())?;
    match m["role"].as_str()? {
        "user" => Some(json!({"role": "user", "text": text})),
        "assistant" => match text.strip_prefix(OUTCOME_PREFIX) {
            Some(rest) => outcome_counts(rest),
            None => Some(json!({"role": "assistant", "text": text})),
        },
        _ => None,
    }
}

/// Counts the `write <id>: <word>` entries of an outcome note.
fn outcome_counts(rest: &str) -> Option<Value> {
    let (mut applied, mut failed, mut denied, mut expired) = (0u32, 0u32, 0u32, 0u32);
    for entry in rest.split("; ") {
        match entry.rsplit(": ").next() {
            Some("applied") => applied += 1,
            Some("failed") => failed += 1,
            Some("denied") => denied += 1,
            Some("expired") => expired += 1,
            _ => {}
        }
    }
    (applied + failed + denied + expired > 0)
        .then(|| json!({"role": "status", "applied": applied, "failed": failed, "denied": denied, "expired": expired}))
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

    #[test]
    fn transcript_keeps_user_and_assistant_text() {
        let msgs = vec![
            json!({"role": "user", "content": "find comedies"}),
            json!({"role": "assistant", "content": null, "tool_calls": [{"id": "1"}]}),
            json!({"role": "tool", "tool_call_id": "1", "content": "{\"items\":[]}"}),
            json!({"role": "assistant", "content": "None found."}),
        ];
        assert_eq!(
            transcript(&msgs),
            vec![json!({"role": "user", "text": "find comedies"}), json!({"role": "assistant", "text": "None found."})]
        );
    }

    #[test]
    fn transcript_turns_outcome_notes_into_counts() {
        let msgs = vec![
            json!({"role": "assistant", "content": "[host outcome] write a1: applied; write b2: applied; write c3: failed"}),
            json!({"role": "assistant", "content": "[host outcome] write d4: denied"}),
            json!({"role": "assistant", "content": "[host outcome] write e5: expired"}),
        ];
        assert_eq!(
            transcript(&msgs),
            vec![
                json!({"role": "status", "applied": 2, "failed": 1, "denied": 0, "expired": 0}),
                json!({"role": "status", "applied": 0, "failed": 0, "denied": 1, "expired": 0}),
                json!({"role": "status", "applied": 0, "failed": 0, "denied": 0, "expired": 1}),
            ]
        );
    }

    #[test]
    fn transcript_drops_empty_and_unknown() {
        let msgs = vec![
            json!({"role": "assistant", "content": "[host outcome] no writes"}),
            json!({"role": "assistant", "content": "   "}),
            json!({"role": "system", "content": "hidden"}),
            json!({"role": "user", "content": ["parts"]}),
            json!("garbage"),
        ];
        assert!(transcript(&msgs).is_empty());
    }
}
