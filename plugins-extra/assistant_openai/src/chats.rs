//! The list of a user's chats, kept in plugin KV under `chats:<user-id>`,
//! newest first. Each chat's messages live under their own key (see history.rs).

use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Chats kept per user. The oldest falls off when a new one is added.
pub const MAX_CHATS: usize = 50;
const MAX_TITLE_CHARS: usize = 60;
const UNTITLED: &str = "New chat";
/// The id given to the single conversation stored before chats were listed.
pub const LEGACY_ID: &str = "00000000-0000-0000-0000-000000000000";

#[derive(Serialize, Deserialize, Clone, Debug, PartialEq)]
pub struct Chat {
    pub id: String,
    pub title: String,
    /// Unix milliseconds from the page's clock. Ordering and display only.
    pub updated_at: u64,
}

pub fn key(user_id: &str) -> String {
    format!("chats:{user_id}")
}

/// An id as the page or the host issues it: hex digits and dashes. Anything
/// else is refused, so an id never carries a key separator or free text.
pub fn valid_id(v: &Value) -> Option<&str> {
    v.as_str().filter(|s| !s.is_empty() && s.len() <= 36 && s.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
}

pub fn decode(raw: Option<String>) -> Vec<Chat> {
    raw.and_then(|s| serde_json::from_str(&s).ok()).unwrap_or_default()
}

pub fn encode(chats: &[Chat]) -> String {
    serde_json::to_string(chats).unwrap_or_else(|_| "[]".into())
}

/// The first user message, whitespace collapsed and cut to a line.
pub fn title_from(messages: &[Value]) -> String {
    let first = messages.iter().find(|m| m["role"] == "user").and_then(|m| m["content"].as_str()).unwrap_or("");
    let tidy = first.split_whitespace().collect::<Vec<_>>().join(" ");
    if tidy.is_empty() {
        UNTITLED.into()
    } else if tidy.chars().count() > MAX_TITLE_CHARS {
        format!("{}…", tidy.chars().take(MAX_TITLE_CHARS).collect::<String>())
    } else {
        tidy
    }
}

/// Moves `id` to the front with a new timestamp, naming it from `messages`
/// when it is new. Returns the ids pushed past `MAX_CHATS`, whose messages the
/// caller deletes.
pub fn touch(chats: &mut Vec<Chat>, id: &str, messages: &[Value], now: u64) -> Vec<String> {
    let title = match chats.iter().position(|c| c.id == id) {
        Some(i) => chats.remove(i).title,
        None => title_from(messages),
    };
    chats.insert(0, Chat { id: id.into(), title, updated_at: now });
    let keep = chats.len().min(MAX_CHATS);
    chats.drain(keep..).map(|c| c.id).collect()
}

pub fn remove(chats: &mut Vec<Chat>, id: &str) -> bool {
    let before = chats.len();
    chats.retain(|c| c.id != id);
    chats.len() != before
}

/// The index entry for the conversation stored before chats were listed.
pub fn adopt(legacy: &[Value]) -> Option<Chat> {
    (!legacy.is_empty()).then(|| Chat { id: LEGACY_ID.into(), title: title_from(legacy), updated_at: 0 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn user(text: &str) -> Value {
        json!({"role": "user", "content": text})
    }

    fn chat(id: &str, at: u64) -> Chat {
        Chat { id: id.into(), title: format!("t-{id}"), updated_at: at }
    }

    #[test]
    fn ids_are_hex_and_dashes_only() {
        assert_eq!(valid_id(&json!(LEGACY_ID)), Some(LEGACY_ID));
        assert_eq!(valid_id(&json!("abc-123")), Some("abc-123"));
        for bad in [json!(""), json!("a:b"), json!("../x"), json!("g"), json!("a".repeat(37)), json!(7), json!(null)] {
            assert_eq!(valid_id(&bad), None, "{bad}");
        }
    }

    #[test]
    fn roundtrip_and_bad_json() {
        let list = vec![chat("a", 2), chat("b", 1)];
        assert_eq!(decode(Some(encode(&list))), list);
        assert!(decode(Some("nope".into())).is_empty());
        assert!(decode(None).is_empty());
    }

    #[test]
    fn title_is_the_first_user_message_tidied() {
        let msgs = vec![json!({"role": "assistant", "content": "hi"}), user("  find\n  short   comedies "), user("second")];
        assert_eq!(title_from(&msgs), "find short comedies");
        assert_eq!(title_from(&[]), "New chat");
        assert_eq!(title_from(&[user("   ")]), "New chat");
    }

    #[test]
    fn long_titles_are_cut_on_a_character_boundary() {
        let title = title_from(&[user(&"é".repeat(80))]);
        assert_eq!(title.chars().count(), 61);
        assert!(title.ends_with('…'));
    }

    #[test]
    fn touch_inserts_at_the_front() {
        let mut list = vec![chat("a", 1)];
        let evicted = touch(&mut list, "b", &[user("hello")], 5);
        assert!(evicted.is_empty());
        assert_eq!(list[0], Chat { id: "b".into(), title: "hello".into(), updated_at: 5 });
        assert_eq!(list[1].id, "a");
    }

    #[test]
    fn touch_bumps_an_existing_chat_and_keeps_its_title() {
        let mut list = vec![chat("a", 3), chat("b", 2)];
        touch(&mut list, "b", &[user("something else")], 9);
        assert_eq!(list.iter().map(|c| c.id.as_str()).collect::<Vec<_>>(), ["b", "a"]);
        assert_eq!(list[0].title, "t-b");
        assert_eq!(list[0].updated_at, 9);
    }

    #[test]
    fn touch_evicts_past_the_cap() {
        let mut list: Vec<Chat> = (0..MAX_CHATS).map(|i| chat(&format!("{i:x}"), 100 - i as u64)).collect();
        let last = list.last().unwrap().id.clone();
        let evicted = touch(&mut list, "fff", &[user("new")], 200);
        assert_eq!(evicted, vec![last]);
        assert_eq!(list.len(), MAX_CHATS);
        assert_eq!(list[0].id, "fff");
    }

    #[test]
    fn remove_reports_whether_it_found_the_chat() {
        let mut list = vec![chat("a", 1), chat("b", 2)];
        assert!(remove(&mut list, "a"));
        assert!(!remove(&mut list, "a"));
        assert_eq!(list, vec![chat("b", 2)]);
    }

    #[test]
    fn adopt_names_a_non_empty_legacy_conversation() {
        let got = adopt(&[user("old question"), json!({"role": "assistant", "content": "old answer"})]);
        assert_eq!(got, Some(Chat { id: LEGACY_ID.into(), title: "old question".into(), updated_at: 0 }));
        assert_eq!(adopt(&[]), None);
    }
}
