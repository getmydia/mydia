//! `SUBTITLE_FEATURE_ENABLED` feature flag.
//!
//! Port of `lib/mydia/subtitles/feature_flags.ex`. Default is `false`
//! (subtitles are opt-in). Resolves from the `SUBTITLE_FEATURE_ENABLED`
//! environment variable when callers prefer a one-liner.

const ENV_VAR: &str = "SUBTITLE_FEATURE_ENABLED";

pub const DEFAULT: bool = false;

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
    fn truthy_variants_resolve_to_true() {
        assert!(parse_bool("TRUE"));
        assert!(parse_bool("1"));
        assert!(!parse_bool("nope"));
    }
}
