//! Which model a chat uses: the provider's `/models` list, the user's pick
//! (stored per user) and the admin's default and lock.

use crate::tools::clip;
use serde::Serialize;
use serde_json::Value;

/// Most models sent to the page; OpenRouter alone lists hundreds.
pub const MAX_MODELS: usize = 1000;
const MAX_ID_CHARS: usize = 200;
const LOCKED: &str = "Admin model only";

#[derive(Debug, PartialEq, Serialize)]
pub struct ModelInfo {
    pub id: String,
    pub name: String,
}

pub fn valid_id(id: &str) -> bool {
    !id.is_empty() && id.chars().count() <= MAX_ID_CHARS && !id.chars().any(|c| c.is_control() || c.is_whitespace())
}

pub fn key(user_id: &str) -> String {
    format!("model:{user_id}")
}

pub fn locked(settings: &Value) -> bool {
    settings["model_choice"].as_str().map(str::trim) == Some(LOCKED)
}

/// The user's pick when allowed and valid, else the admin default, else None.
pub fn effective(settings: &Value, user_pick: Option<&str>) -> Option<String> {
    if !locked(settings) {
        if let Some(pick) = user_pick.map(str::trim).filter(|p| valid_id(p)) {
            return Some(pick.to_string());
        }
    }
    let admin = settings["model"].as_str().unwrap_or("").trim();
    valid_id(admin).then(|| admin.to_string())
}

pub fn missing_message(settings: &Value) -> &'static str {
    if locked(settings) {
        "An admin needs to set a model in the plugin settings."
    } else {
        "Pick a model above to start."
    }
}

/// Parses an OpenAI-shaped `{"data": [{"id", ...}]}` list. Anthropic adds
/// `display_name`, OpenRouter `name`; Gemini prefixes ids with `models/`.
pub fn parse(status: u16, body: &str) -> Result<Vec<ModelInfo>, String> {
    let v: Value = serde_json::from_str(body).map_err(|_| format!("The model list answered {status} with something that is not JSON."))?;
    if !(200..300).contains(&status) {
        let detail = clip(v["error"]["message"].as_str().unwrap_or("no detail"), 200);
        return Err(format!("The model list answered {status}: {detail}"));
    }
    let data = v["data"].as_array().ok_or("The model list had no data.")?;
    let mut out: Vec<ModelInfo> = data
        .iter()
        .filter_map(|m| {
            let raw = m["id"].as_str()?;
            let id = raw.strip_prefix("models/").unwrap_or(raw).to_string();
            if !valid_id(&id) {
                return None;
            }
            let name = m["name"].as_str().or(m["display_name"].as_str()).map(str::to_string).unwrap_or_else(|| id.clone());
            Some(ModelInfo { id, name })
        })
        .collect();
    out.sort_by(|a, b| a.id.cmp(&b.id));
    out.dedup_by(|a, b| a.id == b.id);
    out.truncate(MAX_MODELS);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn parses_openai_shape_sorted_and_deduped() {
        let body = r#"{"object":"list","data":[{"id":"zeta-2"},{"id":"alpha-1"},{"id":"zeta-2"}]}"#;
        let ids: Vec<String> = parse(200, body).unwrap().into_iter().map(|m| m.id).collect();
        assert_eq!(ids, vec!["alpha-1", "zeta-2"]);
    }

    #[test]
    fn uses_name_or_display_name_when_present() {
        let body = r#"{"data":[{"id":"a/x","name":"Model X"},{"id":"y","display_name":"Model Y"},{"id":"z"}]}"#;
        let m = parse(200, body).unwrap();
        assert_eq!(m[0], ModelInfo { id: "a/x".into(), name: "Model X".into() });
        assert_eq!(m[1].name, "Model Y");
        assert_eq!(m[2].name, "z");
    }

    #[test]
    fn strips_the_gemini_models_prefix() {
        let m = parse(200, r#"{"data":[{"id":"models/gem-1"}]}"#).unwrap();
        assert_eq!(m[0].id, "gem-1");
    }

    #[test]
    fn skips_entries_with_unusable_ids() {
        let m = parse(200, r#"{"data":[{"id":""},{"id":"has space"},{"x":1},{"id":"ok"}]}"#).unwrap();
        assert_eq!(m.len(), 1);
    }

    #[test]
    fn errors_are_readable() {
        assert!(parse(200, "nope").is_err());
        assert!(parse(200, r#"{"data":"x"}"#).is_err());
        let e = parse(401, r#"{"error":{"message":"bad key"}}"#).err().unwrap();
        assert!(e.contains("401") && e.contains("bad key"), "{e}");
    }

    #[test]
    fn the_list_is_capped() {
        let data: Vec<_> = (0..MAX_MODELS + 10).map(|i| json!({"id": format!("m{i:05}")})).collect();
        assert_eq!(parse(200, &json!({"data": data}).to_string()).unwrap().len(), MAX_MODELS);
    }

    #[test]
    fn model_ids_are_validated() {
        assert!(valid_id("anthropic/some-model:free"));
        assert!(!valid_id(""));
        assert!(!valid_id("two words"));
        assert!(!valid_id("tab\there"));
        assert!(!valid_id(&"x".repeat(201)));
        assert!(valid_id(&"x".repeat(200)));
    }

    #[test]
    fn the_user_pick_wins_unless_locked() {
        let open = json!({"model": "admin-m", "model_choice": "Users can choose"});
        assert_eq!(effective(&open, Some("user-m")).as_deref(), Some("user-m"));
        assert_eq!(effective(&open, None).as_deref(), Some("admin-m"));
        let locked = json!({"model": "admin-m", "model_choice": "Admin model only"});
        assert_eq!(effective(&locked, Some("user-m")).as_deref(), Some("admin-m"));
    }

    #[test]
    fn a_missing_choice_setting_means_users_can_choose() {
        assert!(!locked(&json!({})));
        assert_eq!(effective(&json!({}), Some("u")).as_deref(), Some("u"));
    }

    #[test]
    fn invalid_or_absent_models_yield_none() {
        assert_eq!(effective(&json!({"model": "  "}), None), None);
        assert_eq!(effective(&json!({}), Some("bad pick")), None);
    }

    #[test]
    fn the_missing_message_depends_on_the_lock() {
        assert!(missing_message(&json!({})).contains("Pick a model"));
        assert!(missing_message(&json!({"model_choice": "Admin model only"})).contains("admin"));
    }

    #[test]
    fn key_is_per_user() {
        assert_eq!(key("u1"), "model:u1");
    }
}
