//! Cardigann filter chain.
//!
//! Port of `lib/mydia/indexers/cardigann_filters.ex`. The HTML/JSON
//! result parser invokes filters inline (see
//! [`crate::cardigann::result_parser::apply_filter`]). This module
//! re-exports the same logic as standalone helpers so unit tests and
//! template renderers can exercise individual filters without going
//! through the parser.

use serde_json::Value;

/// Apply a single filter directly to a string. Returns the unmodified
/// value when the filter is unknown (matches the Phoenix behaviour).
#[must_use]
pub fn apply(filter_name: &str, args: Option<&Value>, value: &str) -> String {
    let filter = match args {
        Some(a) => serde_json::json!({ "name": filter_name, "args": a }),
        None => serde_json::json!({ "name": filter_name }),
    };
    // Re-route through the parser's implementation so behaviour stays in sync.
    crate::cardigann::result_parser::apply_filter(&filter, value)
}

/// Apply a chain of filters in order.
#[must_use]
pub fn apply_chain(filters: &[Value], value: &str) -> String {
    filters.iter().fold(value.to_owned(), |acc, f| {
        crate::cardigann::result_parser::apply_filter(f, &acc)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn trim_strips_whitespace() {
        assert_eq!(apply("trim", None, "  hello  "), "hello");
    }

    #[test]
    fn replace_substitutes_first_arg_with_second() {
        let args = serde_json::json!(["world", "rust"]);
        assert_eq!(apply("replace", Some(&args), "hello world"), "hello rust");
    }

    #[test]
    fn unknown_filter_passes_through() {
        assert_eq!(apply("bogus", None, "x"), "x");
    }

    #[test]
    fn chain_runs_filters_in_order() {
        let filters = vec![
            serde_json::json!({"name": "trim"}),
            serde_json::json!({"name": "tolower"}),
        ];
        assert_eq!(apply_chain(&filters, "  HELLO  "), "hello");
    }
}
