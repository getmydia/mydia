//! Provider presets: where each supported service lives and how to list its
//! models. Chat always goes through the provider's OpenAI-compatible API.

use serde_json::Value;

pub const CUSTOM: &str = "Custom (OpenAI-compatible)";

/// How `/models` authenticates. Chat is always Bearer.
#[derive(Clone, Copy, Debug, PartialEq)]
pub enum ModelsAuth {
    Bearer,
    /// `x-api-key` plus `anthropic-version`; Anthropic's native models list.
    Anthropic,
}

#[derive(Debug, PartialEq)]
pub struct Preset {
    /// Equals the manifest's `provider` option string.
    pub label: &'static str,
    /// None means the operator supplies `base_url`.
    pub base_url: Option<&'static str>,
    pub models_auth: ModelsAuth,
    pub models_query: &'static str,
    pub needs_key: bool,
    /// A bare `http://host:port` gets `/v1` appended.
    pub local: bool,
}

const fn hosted(label: &'static str, base_url: &'static str) -> Preset {
    Preset { label, base_url: Some(base_url), models_auth: ModelsAuth::Bearer, models_query: "", needs_key: true, local: false }
}

const fn operator(label: &'static str, local: bool) -> Preset {
    Preset { label, base_url: None, models_auth: ModelsAuth::Bearer, models_query: "", needs_key: false, local }
}

/// Custom is first: it is the fallback for a missing or unknown provider.
static PRESETS: [Preset; 11] = [
    operator(CUSTOM, false),
    hosted("OpenAI", "https://api.openai.com/v1"),
    Preset { models_auth: ModelsAuth::Anthropic, models_query: "?limit=1000", ..hosted("Anthropic", "https://api.anthropic.com/v1") },
    Preset { models_query: "?supported_parameters=tools", ..hosted("OpenRouter", "https://openrouter.ai/api/v1") },
    hosted("Google Gemini", "https://generativelanguage.googleapis.com/v1beta/openai"),
    hosted("Groq", "https://api.groq.com/openai/v1"),
    hosted("Mistral", "https://api.mistral.ai/v1"),
    hosted("DeepSeek", "https://api.deepseek.com/v1"),
    hosted("xAI", "https://api.x.ai/v1"),
    operator("Ollama", true),
    operator("LM Studio", true),
];

pub struct Resolved {
    pub preset: &'static Preset,
    pub base_url: String,
    pub api_key: String,
}

fn field(settings: &Value, key: &str) -> String {
    settings[key].as_str().unwrap_or("").trim().to_string()
}

/// The preset named by the `provider` setting; Custom when missing or unknown,
/// which is how configs from before presets keep working.
pub fn selected(settings: &Value) -> &'static Preset {
    let label = field(settings, "provider");
    PRESETS.iter().find(|p| p.label == label).unwrap_or(&PRESETS[0])
}

fn with_v1(url: &str) -> String {
    let rest = url.split_once("://").map(|(_, r)| r).unwrap_or(url);
    if rest.contains('/') { url.to_string() } else { format!("{url}/v1") }
}

pub fn resolve(settings: &Value) -> Result<Resolved, String> {
    let preset = selected(settings);
    let api_key = field(settings, "api_key");
    let base_url = match preset.base_url {
        Some(url) => url.to_string(),
        None => {
            let raw = field(settings, "base_url");
            let raw = raw.trim_end_matches('/');
            if raw.is_empty() {
                return Err(format!("An admin needs to set the {} server URL in the plugin settings.", preset.label));
            }
            if preset.local { with_v1(raw) } else { raw.to_string() }
        }
    };
    if preset.needs_key && api_key.is_empty() {
        return Err(format!("An admin needs to add the {} API key in the plugin settings.", preset.label));
    }
    Ok(Resolved { preset, base_url, api_key })
}

impl Resolved {
    pub fn chat_url(&self) -> String {
        format!("{}/chat/completions", self.base_url)
    }

    pub fn models_url(&self) -> String {
        format!("{}/models{}", self.base_url, self.preset.models_query)
    }

    fn bearer(&self) -> Vec<(String, String)> {
        if self.api_key.is_empty() { vec![] } else { vec![("authorization".into(), format!("Bearer {}", self.api_key))] }
    }

    pub fn chat_headers(&self) -> Vec<(String, String)> {
        let mut h = vec![("content-type".to_string(), "application/json".to_string())];
        h.extend(self.bearer());
        h
    }

    pub fn models_headers(&self) -> Vec<(String, String)> {
        match self.preset.models_auth {
            ModelsAuth::Bearer => self.bearer(),
            ModelsAuth::Anthropic => vec![("x-api-key".into(), self.api_key.clone()), ("anthropic-version".into(), "2023-06-01".into())],
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn header<'a>(h: &'a [(String, String)], name: &str) -> Option<&'a str> {
        h.iter().find(|(k, _)| k == name).map(|(_, v)| v.as_str())
    }

    #[test]
    fn hosted_presets_use_their_fixed_url() {
        let r = resolve(&json!({"provider": "OpenRouter", "api_key": "k"})).unwrap();
        assert_eq!(r.chat_url(), "https://openrouter.ai/api/v1/chat/completions");
        assert_eq!(r.models_url(), "https://openrouter.ai/api/v1/models?supported_parameters=tools");
        let r = resolve(&json!({"provider": "Google Gemini", "api_key": "k"})).unwrap();
        assert_eq!(r.chat_url(), "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions");
    }

    #[test]
    fn a_stale_base_url_is_ignored_for_hosted_presets() {
        let r = resolve(&json!({"provider": "OpenAI", "api_key": "k", "base_url": "http://old.lan/v1"})).unwrap();
        assert_eq!(r.base_url, "https://api.openai.com/v1");
    }

    #[test]
    fn legacy_config_without_provider_is_custom() {
        let r = resolve(&json!({"base_url": "http://x/v1/", "model": "m"})).unwrap();
        assert_eq!(r.preset.label, CUSTOM);
        assert_eq!(r.chat_url(), "http://x/v1/chat/completions");
        let r = resolve(&json!({"provider": "Nonsense", "base_url": "http://x/v1"})).unwrap();
        assert_eq!(r.preset.label, CUSTOM);
        let r = resolve(&json!({"provider": "", "base_url": "http://x/v1"})).unwrap();
        assert_eq!(r.preset.label, CUSTOM);
    }

    #[test]
    fn custom_keeps_the_path_it_was_given() {
        let r = resolve(&json!({"provider": CUSTOM, "base_url": "http://x:8080"})).unwrap();
        assert_eq!(r.base_url, "http://x:8080");
    }

    #[test]
    fn local_presets_append_v1_to_a_bare_host() {
        let r = resolve(&json!({"provider": "Ollama", "base_url": "http://ollama.lan:11434/"})).unwrap();
        assert_eq!(r.base_url, "http://ollama.lan:11434/v1");
        let r = resolve(&json!({"provider": "LM Studio", "base_url": "http://box:1234/v1"})).unwrap();
        assert_eq!(r.base_url, "http://box:1234/v1");
    }

    #[test]
    fn missing_url_names_the_provider() {
        let e = resolve(&json!({"provider": "Ollama"})).err().unwrap();
        assert!(e.contains("Ollama") && e.contains("URL"), "{e}");
        assert!(resolve(&json!({})).is_err());
    }

    #[test]
    fn missing_key_names_the_provider() {
        let e = resolve(&json!({"provider": "Anthropic"})).err().unwrap();
        assert!(e.contains("Anthropic") && e.contains("API key"), "{e}");
        assert!(resolve(&json!({"provider": "Ollama", "base_url": "http://o:11434"})).is_ok());
    }

    #[test]
    fn chat_uses_bearer_only_when_a_key_is_set() {
        let r = resolve(&json!({"provider": "Anthropic", "api_key": "k"})).unwrap();
        let h = r.chat_headers();
        assert_eq!(header(&h, "authorization"), Some("Bearer k"));
        assert_eq!(header(&h, "content-type"), Some("application/json"));
        let r = resolve(&json!({"provider": "Ollama", "base_url": "http://o:11434"})).unwrap();
        assert_eq!(header(&r.chat_headers(), "authorization"), None);
    }

    #[test]
    fn anthropic_models_use_its_own_headers() {
        let r = resolve(&json!({"provider": "Anthropic", "api_key": "k"})).unwrap();
        let h = r.models_headers();
        assert_eq!(header(&h, "x-api-key"), Some("k"));
        assert_eq!(header(&h, "anthropic-version"), Some("2023-06-01"));
        assert_eq!(header(&h, "authorization"), None);
        assert_eq!(r.models_url(), "https://api.anthropic.com/v1/models?limit=1000");
        let r = resolve(&json!({"provider": "OpenAI", "api_key": "k"})).unwrap();
        assert_eq!(header(&r.models_headers(), "authorization"), Some("Bearer k"));
    }

    #[test]
    fn selected_falls_back_to_custom() {
        assert_eq!(selected(&json!({})).label, CUSTOM);
        assert_eq!(selected(&json!({"provider": "xAI"})).label, "xAI");
    }

    #[test]
    fn manifest_options_match_presets() {
        let manifest: Value = serde_json::from_str(include_str!("../manifest.json")).unwrap();
        let schema = manifest["settings_schema"].as_array().unwrap();
        let options = |key: &str| -> Vec<String> {
            schema
                .iter()
                .find(|f| f["key"] == key)
                .unwrap()["options"]
                .as_array()
                .unwrap()
                .iter()
                .map(|o| o.as_str().unwrap().to_string())
                .collect()
        };
        let labels: Vec<String> = PRESETS.iter().map(|p| p.label.to_string()).collect();
        assert_eq!(options("provider"), labels);
        assert_eq!(options("model_choice"), vec!["Users can choose", "Admin model only"]);

        let hosts: Vec<String> = manifest["capabilities"]["net:http"]
            .as_array()
            .unwrap()
            .iter()
            .map(|h| h.as_str().unwrap().to_string())
            .collect();
        for p in PRESETS.iter().filter_map(|p| p.base_url) {
            let host = p.split("://").nth(1).unwrap().split('/').next().unwrap();
            assert!(hosts.contains(&host.to_string()), "{host} missing from net:http");
        }
    }
}
