use std::sync::LazyLock;

use regex::Regex;

static BRACKETED: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\[[^\]]*\]|\{[^}]*\}").expect("static pattern"));

static WHITESPACE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"\s+").expect("static pattern"));

/// Turns a raw filename fragment into a display title.
///
/// Scene names separate words with dots or underscores; hand-named files use
/// spaces and may contain meaningful dots ("Mr. Robot"). The rule is that a
/// fragment already containing a space keeps its dots, and one without a
/// space has its dots and underscores read as separators.
pub fn clean_title(raw: &str) -> String {
    let without_brackets = BRACKETED.replace_all(raw, " ").to_string();

    let separated = if without_brackets.contains(' ') {
        without_brackets.replace('_', " ")
    } else {
        without_brackets.replace(['.', '_'], " ")
    };

    let collapsed = WHITESPACE.replace_all(&separated, " ").to_string();

    collapsed
        .trim_matches(|c: char| c.is_whitespace() || c == '-' || c == '.' || c == '_')
        .to_string()
}

/// The grouping key for a title: lowercase, letters and digits only.
///
/// Two files whose titles differ only in punctuation, case or spacing belong
/// to the same item, so "Marvel's Agents" and "Marvels.Agents" collapse
/// together across a rescan.
pub fn identity_key(title: &str) -> String {
    title
        .to_lowercase()
        .chars()
        .filter(|c| c.is_alphanumeric())
        .collect()
}

/// Whether a four-digit number is plausibly a release year rather than a
/// title ("2012"), a resolution, or an episode number.
pub fn plausible_year(value: i32) -> bool {
    (1880..=2100).contains(&value)
}

#[cfg(test)]
mod tests {
    use super::{clean_title, identity_key, plausible_year};

    #[test]
    fn dotted_scene_titles_become_spaced() {
        assert_eq!(clean_title("Movie.Title"), "Movie Title");
    }

    #[test]
    fn underscores_become_spaces() {
        assert_eq!(clean_title("Movie_Title"), "Movie Title");
    }

    #[test]
    fn a_title_that_already_has_spaces_keeps_its_dots() {
        assert_eq!(clean_title("Mr. Robot"), "Mr. Robot");
    }

    #[test]
    fn bracketed_group_prefixes_are_dropped() {
        assert_eq!(clean_title("[SubsPlease] Show Name"), "Show Name");
    }

    #[test]
    fn brace_editions_are_dropped() {
        assert_eq!(
            clean_title("The Matrix {edition-Directors Cut}"),
            "The Matrix"
        );
    }

    #[test]
    fn trailing_separators_are_trimmed() {
        assert_eq!(clean_title("Show Name - "), "Show Name");
        assert_eq!(clean_title("Movie.Title."), "Movie Title");
    }

    #[test]
    fn runs_of_whitespace_collapse() {
        assert_eq!(clean_title("Movie   Title"), "Movie Title");
    }

    #[test]
    fn an_empty_result_stays_empty() {
        assert_eq!(clean_title("..."), "");
        assert_eq!(clean_title("[Group]"), "");
    }

    #[test]
    fn identity_keys_ignore_case_and_punctuation() {
        assert_eq!(identity_key("The Matrix"), identity_key("the matrix"));
        assert_eq!(
            identity_key("Marvel's Agents"),
            identity_key("Marvels Agents")
        );
        assert_eq!(identity_key("Spider-Man"), identity_key("Spider Man"));
    }

    #[test]
    fn identity_keys_keep_different_titles_apart() {
        assert_ne!(
            identity_key("The Matrix"),
            identity_key("The Matrix Reloaded")
        );
    }

    #[test]
    fn identity_keys_keep_digits() {
        assert_eq!(identity_key("2012"), "2012");
    }

    #[test]
    fn plausible_years_are_bounded() {
        assert!(plausible_year(1999));
        assert!(plausible_year(2026));
        assert!(!plausible_year(1799));
        assert!(!plausible_year(2400));
    }
}
