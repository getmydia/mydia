//! Compatibility shims for older Cardigann definitions.
//!
//! Port of `lib/mydia/indexers/cardigann_compat.ex`. The upstream
//! Cardigann/Prowlarr repository has multiple schema versions in flight
//! at any time. The Phoenix module rewrites a small set of legacy
//! keys/shapes into the v11 form before the parser runs; this Rust
//! port covers the same transformations.

use serde_yaml::{Mapping, Value};

/// Apply any v11-compat transforms in-place. Returns `true` when the
/// YAML was modified.
pub fn normalize(yaml: &mut Value) -> bool {
    let mut changed = false;
    if let Value::Mapping(map) = yaml {
        changed |= rename_field(map, "site", "id");
        changed |= rename_field(map, "request-delay", "requestdelay");
        changed |= rename_field(map, "follow-redirect", "followredirect");
        changed |= rename_field(map, "test-link-torrent", "testlinktorrent");
        changed |= ensure_links_is_sequence(map);
    }
    changed
}

fn rename_field(map: &mut Mapping, old: &str, new: &str) -> bool {
    if map.contains_key(Value::String(new.into())) {
        return false;
    }
    let Some(value) = map.remove(Value::String(old.into())) else {
        return false;
    };
    map.insert(Value::String(new.into()), value);
    true
}

fn ensure_links_is_sequence(map: &mut Mapping) -> bool {
    let key = Value::String("links".into());
    let Some(existing) = map.get(&key).cloned() else {
        return false;
    };
    match existing {
        Value::String(s) => {
            map.insert(key, Value::Sequence(vec![Value::String(s)]));
            true
        }
        _ => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn renames_legacy_keys() {
        let mut yaml: Value =
            serde_yaml::from_str("site: example\nrequest-delay: 2.5\nlinks: https://example.com\n")
                .unwrap();
        assert!(normalize(&mut yaml));
        assert!(yaml.get("id").is_some());
        assert!(yaml.get("requestdelay").is_some());
        let links = yaml.get("links").unwrap().as_sequence().unwrap();
        assert_eq!(links.len(), 1);
    }

    #[test]
    fn idempotent_when_already_v11() {
        let mut yaml: Value = serde_yaml::from_str("id: a\nlinks:\n  - https://x\n").unwrap();
        assert!(!normalize(&mut yaml));
    }
}
