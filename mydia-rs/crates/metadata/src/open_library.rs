//! Open Library client — Rust port of
//! `lib/mydia/metadata/provider/open_library.ex`.
//!
//! Talks to the metadata-relay's `/openlibrary/*` endpoints. Books
//! return [`BookMetadata`] rather than [`MediaMetadata`] because Open
//! Library's schema does not align with TMDB's. The same
//! [`crate::Provider`] trait is implemented; calls that don't apply to
//! books (`fetch_season`, `fetch_trending`) return
//! [`MetadataError::invalid_request`] / empty results to match the
//! Elixir behaviour.

use async_trait::async_trait;
use serde_json::Value;

use crate::error::MetadataError;
use crate::http::HttpClient;
use crate::provider::{
    FetchOpts, ImageOpts, Provider, ProviderConfig, SearchOpts, SeasonOpts, TrendingOpts,
};
use crate::structs::{
    BookMetadata, ConnectionInfo, ImagesResponse, MediaMetadata, MediaType, ProviderKind,
    SearchResult, SeasonData,
};

/// Open Library adapter.
#[derive(Debug, Default, Clone)]
pub struct OpenLibrary;

impl OpenLibrary {
    /// Construct a new adapter.
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    /// Fetch a book — Open-Library-specific call that returns a
    /// concrete [`BookMetadata`]. The trait's `fetch_by_id` returns
    /// [`MediaMetadata`], which doesn't fit books, so callers that
    /// want the typed shape go through this method directly.
    pub async fn fetch_book(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
    ) -> Result<BookMetadata, MetadataError> {
        let client = HttpClient::new(config)?;

        let (endpoint, id_kind) = if let Some(isbn) = provider_id.strip_prefix("ISBN:") {
            (format!("/openlibrary/isbn/{isbn}"), IdKind::Isbn)
        } else {
            (format!("/openlibrary/works/{provider_id}"), IdKind::Olid)
        };

        let body: Value = client.get_value(&endpoint, &[], config).await?;
        parse_book(&body, id_kind, provider_id)
            .ok_or_else(|| MetadataError::not_found(format!("Book not found: {provider_id}")))
    }
}

#[derive(Debug, Clone, Copy)]
enum IdKind {
    Isbn,
    Olid,
}

#[async_trait]
impl Provider for OpenLibrary {
    async fn test_connection(
        &self,
        config: &ProviderConfig,
    ) -> Result<ConnectionInfo, MetadataError> {
        let client = HttpClient::new(config)?;
        let _ = client
            .get_value(
                "/openlibrary/search",
                &[("q", "the".to_string()), ("limit", "1".to_string())],
                config,
            )
            .await?;
        Ok(ConnectionInfo {
            status: "ok".into(),
            provider: "open_library".into(),
        })
    }

    async fn search(
        &self,
        config: &ProviderConfig,
        query: &str,
        _opts: &SearchOpts,
    ) -> Result<Vec<SearchResult>, MetadataError> {
        let client = HttpClient::new(config)?;
        let body: Value = client
            .get_value("/openlibrary/search", &[("q", query.to_string())], config)
            .await?;
        Ok(parse_search_results(&body))
    }

    async fn fetch_by_id(
        &self,
        _config: &ProviderConfig,
        _provider_id: &str,
        _opts: &FetchOpts,
    ) -> Result<MediaMetadata, MetadataError> {
        // The trait's MediaMetadata shape does not represent books.
        // Callers should use OpenLibrary::fetch_book directly.
        Err(MetadataError::invalid_request(
            "use OpenLibrary::fetch_book for book metadata",
        ))
    }

    async fn fetch_images(
        &self,
        _config: &ProviderConfig,
        _provider_id: &str,
        _opts: &ImageOpts,
    ) -> Result<ImagesResponse, MetadataError> {
        Ok(ImagesResponse::default())
    }

    async fn fetch_season(
        &self,
        _config: &ProviderConfig,
        _provider_id: &str,
        _season_number: i32,
        _opts: &SeasonOpts,
    ) -> Result<SeasonData, MetadataError> {
        Err(MetadataError::invalid_request(
            "Season fetching is not supported for books",
        ))
    }

    async fn fetch_trending(
        &self,
        _config: &ProviderConfig,
        _opts: &TrendingOpts,
    ) -> Result<Vec<SearchResult>, MetadataError> {
        Ok(Vec::new())
    }
}

// ---------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------

fn parse_search_results(body: &Value) -> Vec<SearchResult> {
    let Some(docs) = body.get("docs").and_then(Value::as_array) else {
        return Vec::new();
    };
    docs.iter().map(parse_search_doc).collect()
}

fn parse_search_doc(doc: &Value) -> SearchResult {
    let provider_id = doc
        .get("key")
        .and_then(Value::as_str)
        .map(|key| key.strip_prefix("/works/").unwrap_or(key).to_string())
        .unwrap_or_default();

    let overview = doc
        .get("text")
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(Value::as_str)
        .map(str::to_string);

    SearchResult {
        provider_id,
        provider: ProviderKind::OpenLibrary,
        media_type: MediaType::Book,
        title: doc.get("title").and_then(Value::as_str).map(str::to_string),
        original_title: doc.get("title").and_then(Value::as_str).map(str::to_string),
        name: None,
        original_name: None,
        year: doc
            .get("first_publish_year")
            .and_then(Value::as_i64)
            .map(|n| n as i32),
        overview,
        poster_path: get_cover_url(doc.get("cover_i")),
        backdrop_path: None,
        popularity: None,
        vote_average: None,
        vote_count: doc.get("edition_count").and_then(Value::as_i64),
        release_date: None,
        first_air_date: None,
        id: None,
        imdb_id: None,
    }
}

fn parse_book(body: &Value, kind: IdKind, provider_id: &str) -> Option<BookMetadata> {
    match kind {
        IdKind::Isbn => {
            // Body is `{"ISBN:<isbn>" => {...}}`. Pick the requested
            // key if present, fall back to the first value.
            let data = body
                .get(provider_id)
                .cloned()
                .or_else(|| body.as_object().and_then(|m| m.values().next().cloned()))?;
            Some(map_book_data(&data, provider_id))
        }
        IdKind::Olid => Some(map_work_data(body, provider_id)),
    }
}

fn map_book_data(data: &Value, provider_id: &str) -> BookMetadata {
    BookMetadata {
        provider_id: provider_id.to_string(),
        provider: ProviderKind::OpenLibrary,
        title: data
            .get("title")
            .and_then(Value::as_str)
            .map(str::to_string),
        subtitle: data
            .get("subtitle")
            .and_then(Value::as_str)
            .map(str::to_string),
        authors: parse_authors(data.get("authors")),
        isbn_10: get_isbn(data, "isbn_10"),
        isbn_13: get_isbn(data, "isbn_13"),
        publish_date: data
            .get("publish_date")
            .and_then(Value::as_str)
            .map(str::to_string),
        publisher: parse_publisher(data.get("publishers")),
        number_of_pages: data
            .get("number_of_pages")
            .and_then(Value::as_i64)
            .map(|n| n as i32),
        description: None,
        cover_url: data
            .get("cover")
            .or_else(|| data.get("covers"))
            .and_then(get_cover_url_from_value),
        genres: parse_subjects(data.get("subjects")),
        series_name: None,
        series_position: None,
        language: None,
        identifiers: data.get("identifiers").cloned(),
    }
}

fn map_work_data(data: &Value, provider_id: &str) -> BookMetadata {
    BookMetadata {
        provider_id: provider_id.to_string(),
        provider: ProviderKind::OpenLibrary,
        title: data
            .get("title")
            .and_then(Value::as_str)
            .map(str::to_string),
        subtitle: None,
        authors: Vec::new(),
        isbn_10: None,
        isbn_13: None,
        publish_date: data
            .get("first_publish_date")
            .and_then(Value::as_str)
            .map(str::to_string),
        publisher: None,
        number_of_pages: None,
        description: parse_description(data.get("description")),
        cover_url: data.get("covers").and_then(get_cover_url_from_value),
        genres: parse_subjects(data.get("subjects")),
        series_name: None,
        series_position: None,
        language: None,
        identifiers: None,
    }
}

fn parse_authors(value: Option<&Value>) -> Vec<String> {
    let Some(arr) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|a| a.get("name").and_then(Value::as_str).map(str::to_string))
        .collect()
}

fn parse_publisher(value: Option<&Value>) -> Option<String> {
    value
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(|p| p.get("name"))
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn get_isbn(data: &Value, key: &str) -> Option<String> {
    data.get("identifiers")
        .and_then(|i| i.get(key))
        .and_then(Value::as_array)
        .and_then(|arr| arr.first())
        .and_then(Value::as_str)
        .map(str::to_string)
}

fn parse_subjects(value: Option<&Value>) -> Vec<String> {
    let Some(arr) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|s| {
            s.as_str()
                .map(str::to_string)
                .or_else(|| s.get("name").and_then(Value::as_str).map(str::to_string))
        })
        .collect()
}

fn parse_description(value: Option<&Value>) -> Option<String> {
    match value {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s.clone()),
        Some(v) => v.get("value").and_then(Value::as_str).map(str::to_string),
    }
}

fn get_cover_url(value: Option<&Value>) -> Option<String> {
    let id = value?.as_i64()?;
    Some(format!("https://covers.openlibrary.org/b/id/{id}-L.jpg"))
}

fn get_cover_url_from_value(value: &Value) -> Option<String> {
    match value {
        Value::Number(n) => n
            .as_i64()
            .map(|id| format!("https://covers.openlibrary.org/b/id/{id}-L.jpg")),
        Value::Array(arr) => arr.first().and_then(get_cover_url_from_value),
        Value::Object(obj) => obj
            .get("medium")
            .or_else(|| obj.get("large"))
            .and_then(Value::as_str)
            .map(str::to_string),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_doc_parses_work_key() {
        let doc = serde_json::json!({
            "key": "/works/OL12345W",
            "title": "Dune",
            "first_publish_year": 1965,
            "cover_i": 8_739_161
        });
        let result = parse_search_doc(&doc);
        assert_eq!(result.provider_id, "OL12345W");
        assert_eq!(result.title.as_deref(), Some("Dune"));
        assert_eq!(result.year, Some(1965));
        assert!(result.poster_path.is_some());
    }

    #[test]
    fn parse_isbn_pulls_inner_object() {
        let body = serde_json::json!({
            "ISBN:9780441172719": {
                "title": "Dune",
                "authors": [{"name": "Frank Herbert"}],
                "publishers": [{"name": "Ace"}],
                "number_of_pages": 412,
                "identifiers": {"isbn_13": ["9780441172719"]}
            }
        });
        let book = parse_book(&body, IdKind::Isbn, "ISBN:9780441172719").unwrap();
        assert_eq!(book.title.as_deref(), Some("Dune"));
        assert_eq!(book.authors, vec!["Frank Herbert"]);
        assert_eq!(book.publisher.as_deref(), Some("Ace"));
        assert_eq!(book.isbn_13.as_deref(), Some("9780441172719"));
        assert_eq!(book.number_of_pages, Some(412));
    }
}
