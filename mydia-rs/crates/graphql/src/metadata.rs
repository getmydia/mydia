//! Metadata-blob field accessors.
//!
//! Port of `Mydia.Metadata.Access` and `Mydia.Metadata.ImageUrl`,
//! the helpers Phoenix resolvers reach for to pull derived fields
//! out of the media-item / episode metadata JSON.
//!
//! All accessors return `Option<T>` for missing or null values;
//! callers fold to defaults at the GraphQL boundary.

use serde_json::Value;

const TMDB_BASE: &str = "https://image.tmdb.org/t/p";

/// Extract a string field from the metadata blob. Returns `None` for
/// missing keys, null values, or non-string types.
pub fn get_str<'a>(metadata: Option<&'a Value>, key: &str) -> Option<&'a str> {
    metadata.and_then(|v| v.get(key)).and_then(|v| v.as_str())
}

/// Extract an i64 from the metadata blob (rounds floats).
pub fn get_i64(metadata: Option<&Value>, key: &str) -> Option<i64> {
    metadata
        .and_then(|v| v.get(key))
        .and_then(|v| v.as_i64().or_else(|| v.as_f64().map(|f| f as i64)))
}

/// Extract an f64 from the metadata blob.
pub fn get_f64(metadata: Option<&Value>, key: &str) -> Option<f64> {
    metadata
        .and_then(|v| v.get(key))
        .and_then(serde_json::Value::as_f64)
}

/// Extract a `Vec<String>` from a JSON array field. Returns an
/// empty Vec when the field is missing or not an array. Filters
/// out non-string entries silently (matches Phoenix's
/// `MetadataAccess.get_field/2` behaviour).
pub fn get_string_array(metadata: Option<&Value>, key: &str) -> Vec<String> {
    metadata
        .and_then(|v| v.get(key))
        .and_then(|v| v.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|v| v.as_str().map(std::borrow::ToOwned::to_owned))
                .collect()
        })
        .unwrap_or_default()
}

/// Build a poster image URL. Mirrors `Mydia.Metadata.ImageUrl.poster_url/1`:
/// - `None` for missing / empty
/// - Returned as-is for absolute URLs (anything starting with `http`)
/// - TMDB CDN prefix + normalized leading slash for relative paths
pub fn poster_url(path: Option<&str>) -> Option<String> {
    image_url(path, "w500")
}

/// Build a backdrop image URL (`original` size by default).
pub fn backdrop_url(path: Option<&str>) -> Option<String> {
    image_url(path, "original")
}

/// Build an episode thumbnail image URL (`w300` size).
pub fn still_url(path: Option<&str>) -> Option<String> {
    image_url(path, "w300")
}

/// Generic image URL builder.
pub fn image_url(path: Option<&str>, size: &str) -> Option<String> {
    let raw = path?;
    if raw.is_empty() {
        return None;
    }
    if raw.starts_with("http://") || raw.starts_with("https://") {
        return Some(raw.to_owned());
    }
    let normalized = if raw.starts_with('/') {
        raw.to_owned()
    } else {
        format!("/{raw}")
    };
    Some(format!("{TMDB_BASE}/{size}{normalized}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn poster_url_prefixes_tmdb_base() {
        assert_eq!(
            poster_url(Some("/abc.jpg")).as_deref(),
            Some("https://image.tmdb.org/t/p/w500/abc.jpg")
        );
    }

    #[test]
    fn poster_url_returns_absolute_urls_unchanged() {
        let url = "https://artworks.thetvdb.com/posters/123-1.jpg";
        assert_eq!(poster_url(Some(url)).as_deref(), Some(url));
    }

    #[test]
    fn poster_url_normalises_missing_leading_slash() {
        assert_eq!(
            poster_url(Some("abc.jpg")).as_deref(),
            Some("https://image.tmdb.org/t/p/w500/abc.jpg")
        );
    }

    #[test]
    fn poster_url_handles_none_and_empty() {
        assert!(poster_url(None).is_none());
        assert!(poster_url(Some("")).is_none());
    }

    #[test]
    fn backdrop_uses_original_size() {
        assert_eq!(
            backdrop_url(Some("/x.jpg")).as_deref(),
            Some("https://image.tmdb.org/t/p/original/x.jpg")
        );
    }

    #[test]
    fn still_uses_w300_size() {
        assert_eq!(
            still_url(Some("/y.jpg")).as_deref(),
            Some("https://image.tmdb.org/t/p/w300/y.jpg")
        );
    }

    #[test]
    fn get_string_array_handles_missing() {
        let v = serde_json::json!({"genres": ["Sci-Fi", "Action"]});
        assert_eq!(
            get_string_array(Some(&v), "genres"),
            vec!["Sci-Fi".to_owned(), "Action".to_owned()]
        );
        assert!(get_string_array(Some(&v), "missing").is_empty());
        assert!(get_string_array(None, "genres").is_empty());
    }

    #[test]
    fn get_f64_unwraps_floats() {
        let v = serde_json::json!({"vote_average": 8.5, "runtime": 120});
        assert_eq!(get_f64(Some(&v), "vote_average"), Some(8.5));
        // serde_json::Value::as_f64 happily coerces integer-shaped
        // values to f64. Phoenix's resolver receives a numeric value
        // and lets the GraphQL layer coerce; the Rust path matches
        // that — the int 120 surfaces as 120.0 when the caller asks
        // for an f64.
        assert_eq!(get_f64(Some(&v), "runtime"), Some(120.0));
    }

    #[test]
    fn get_i64_accepts_both_ints_and_floats() {
        let v = serde_json::json!({"a": 120, "b": 120.0});
        assert_eq!(get_i64(Some(&v), "a"), Some(120));
        assert_eq!(get_i64(Some(&v), "b"), Some(120));
    }
}
