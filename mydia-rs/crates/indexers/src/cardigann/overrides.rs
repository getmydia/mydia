//! Patches for known upstream Cardigann/Prowlarr definitions.
//!
//! Port of `lib/mydia/indexers/cardigann_overrides.ex`. New overrides
//! are added in [`apply`] — keep the patch self-contained and document
//! why it exists.

use serde_yaml::{Mapping, Value};

/// Apply any registered override for `indexer_id` to `yaml`. Returns
/// `true` when the YAML was modified.
pub fn apply(indexer_id: &str, yaml: &mut Value) -> bool {
    match indexer_id {
        "1337x" => patch_1337x(yaml),
        _ => false,
    }
}

/// 1337x's upstream definition uses `/sort-search/{query}/.../.../.../`
/// which currently 500s; replace it with the working `/search/{query}/...`
/// shape across all four paginated paths.
fn patch_1337x(yaml: &mut Value) -> bool {
    let Some(search) = yaml.get_mut("search").and_then(Value::as_mapping_mut) else {
        return false;
    };

    let patched: Vec<Value> = ["Movies", "TV", "Music", "Other"]
        .iter()
        .map(|cat| {
            let mut m = Mapping::new();
            m.insert(
                Value::String("path".into()),
                Value::String(format!(
                    "{{{{ if or .Query.Album .Query.Artist .Keywords }}}}search/{{{{ or .Query.Album .Query.Artist .Keywords }}}}/1/{{{{ else }}}}cat/{cat}/{{{{ .Config.sort }}}}/{{{{ .Config.type }}}}/1/{{{{ end }}}}"
                )),
            );
            Value::Mapping(m)
        })
        .collect();

    search.insert(Value::String("paths".into()), Value::Sequence(patched));
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_op_for_unknown_indexer() {
        let mut yaml = Value::Mapping(Mapping::new());
        assert!(!apply("unknown-thing", &mut yaml));
    }

    #[test]
    fn patches_1337x_paths() {
        let mut yaml = serde_yaml::from_str::<Value>(
            "search:\n  paths:\n    - path: /sort-search/{{ .Keywords }}/seeders/desc/1/\n",
        )
        .unwrap();
        assert!(apply("1337x", &mut yaml));
        let paths = yaml
            .get("search")
            .and_then(|s| s.get("paths"))
            .and_then(Value::as_sequence)
            .unwrap();
        assert_eq!(paths.len(), 4);
        let first = paths[0].get("path").and_then(Value::as_str).unwrap();
        assert!(first.starts_with("{{ if or .Query.Album"));
    }
}
