//! `ENABLE_CARDIGANN` feature flag.
//!
//! Port of `lib/mydia/indexers/cardigann_feature_flags.ex`. Default is
//! `false`. Callers pass the resolved value at construction time; this
//! module just defines the constant + the env-var lookup helper for
//! callers that prefer a one-liner.

const ENV_VAR: &str = "ENABLE_CARDIGANN";

/// Default value: Cardigann is opt-in.
pub const DEFAULT: bool = false;

/// Read the env var, returning [`DEFAULT`] when unset or unrecognized.
#[must_use]
pub fn enabled_from_env() -> bool {
    std::env::var(ENV_VAR)
        .ok()
        .as_deref()
        .map_or(DEFAULT, parse_bool)
}

fn parse_bool(s: &str) -> bool {
    matches!(
        s.to_ascii_lowercase().as_str(),
        "true" | "1" | "yes" | "on" | "enabled"
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_bool_accepts_common_truthy_forms() {
        assert!(parse_bool("true"));
        assert!(parse_bool("True"));
        assert!(parse_bool("YES"));
        assert!(parse_bool("1"));
        assert!(!parse_bool("false"));
        assert!(!parse_bool("nope"));
        assert!(!parse_bool(""));
    }
}
