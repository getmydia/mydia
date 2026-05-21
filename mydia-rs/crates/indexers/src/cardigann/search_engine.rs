//! Search execution driver.
//!
//! Port of `lib/mydia/indexers/cardigann_search_engine.ex`. Builds the
//! HTTP request from a parsed definition + a [`SearchRequest`], fires
//! it through `reqwest` (optionally proxied via FlareSolverr), and
//! hands the response to [`crate::cardigann::result_parser`].

use std::time::Duration;

use reqwest::Client;
use serde_json::Value;
use tracing::debug;

use crate::cardigann::definition_parsed::ParsedDefinition;
use crate::cardigann::result_parser::{self, HttpResponse};
use crate::cardigann::template;
use crate::error::IndexerError;
use crate::flaresolverr::{FlareSolverr, RequestOpts};
use crate::search_result::SearchResult;

/// Input for [`SearchEngine::execute`].
#[derive(Debug, Clone, Default)]
pub struct SearchRequest {
    pub keywords: Option<String>,
    pub imdb_id: Option<String>,
    pub tmdb_id: Option<i64>,
    pub tvdb_id: Option<i64>,
    pub season: Option<i32>,
    pub episode: Option<i32>,
    /// Newznab category IDs the caller wants to scope to.
    pub categories: Vec<i32>,
    pub limit: Option<u32>,
    /// User-provided settings (mapped from the definition's `settings`).
    pub config: Value,
}

impl SearchRequest {
    /// Build the template context map. The shape matches the Phoenix
    /// `Mydia.Indexers.CardigannTemplate.build_context/2` output —
    /// `.Query.*` keys for the search inputs, `.Config.*` keys for the
    /// user-provided settings.
    #[must_use]
    pub fn template_context(&self) -> Value {
        let mut query = serde_json::Map::new();
        if let Some(kw) = &self.keywords {
            query.insert("Keywords".into(), Value::from(kw.clone()));
        }
        if let Some(imdb) = &self.imdb_id {
            let shortened = imdb.trim_start_matches("tt").to_owned();
            query.insert("IMDBID".into(), Value::from(imdb.clone()));
            query.insert("IMDBIDShort".into(), Value::from(shortened));
        }
        if let Some(tmdb) = self.tmdb_id {
            query.insert("TMDBID".into(), Value::from(tmdb));
        }
        if let Some(tvdb) = self.tvdb_id {
            query.insert("TVDBID".into(), Value::from(tvdb));
        }
        if let Some(season) = self.season {
            query.insert("Season".into(), Value::from(season));
        }
        if let Some(episode) = self.episode {
            query.insert("Ep".into(), Value::from(episode));
        }
        if !self.categories.is_empty() {
            query.insert(
                "Categories".into(),
                Value::Array(self.categories.iter().map(|c| Value::from(*c)).collect()),
            );
        }

        let mut root = serde_json::Map::new();
        root.insert("Query".into(), Value::Object(query));
        root.insert("Config".into(), self.config.clone());
        Value::Object(root)
    }
}

/// Search-engine driver. Wraps an HTTP client and an optional
/// FlareSolverr proxy.
#[derive(Clone)]
pub struct SearchEngine {
    http: Client,
    flaresolverr: Option<FlareSolverr>,
}

impl SearchEngine {
    pub fn new() -> Result<Self, IndexerError> {
        let http = Client::builder()
            .timeout(Duration::from_secs(30))
            .build()
            .map_err(IndexerError::from)?;
        Ok(Self {
            http,
            flaresolverr: None,
        })
    }

    #[must_use]
    pub fn with_flaresolverr(mut self, fs: FlareSolverr) -> Self {
        self.flaresolverr = Some(fs);
        self
    }

    /// Run one search request against an indexer definition.
    pub async fn execute(
        &self,
        definition: &ParsedDefinition,
        base_url: &str,
        request: &SearchRequest,
        indexer_name: &str,
    ) -> Result<Vec<SearchResult>, IndexerError> {
        let context = request.template_context();
        let path = definition
            .search
            .paths
            .first()
            .ok_or_else(|| IndexerError::invalid_config("definition has no search paths"))?;
        let rendered_path = template::render(&path.path, &context)
            .map_err(|err| IndexerError::parse_error(format!("template error: {err}")))?;

        let full_url = if rendered_path.starts_with("http") {
            rendered_path
        } else {
            format!(
                "{}/{}",
                base_url.trim_end_matches('/'),
                rendered_path.trim_start_matches('/')
            )
        };

        debug!(url = %full_url, "cardigann search request");

        let body = self.fetch(&full_url, definition).await?;
        let response = HttpResponse {
            status: 200,
            body,
            content_type: None,
        };

        result_parser::parse_results(definition, &response, indexer_name, base_url)
    }

    async fn fetch(
        &self,
        url: &str,
        _definition: &ParsedDefinition,
    ) -> Result<String, IndexerError> {
        // If FlareSolverr is configured + the indexer needs it, route there.
        // The caller is responsible for setting `flaresolverr_required`; the
        // Cardigann YAML doesn't currently carry that hint directly.
        if let Some(fs) = &self.flaresolverr {
            if fs.config().is_usable() {
                match fs.get(url, &RequestOpts::default()).await {
                    Ok(resp) => {
                        if let Some(sol) = resp.solution {
                            if let Some(html) = sol.response {
                                return Ok(html);
                            }
                        }
                        return Err(IndexerError::parse_error("flaresolverr returned no body"));
                    }
                    Err(err) if err.kind == crate::error::ErrorKind::Timeout => {
                        // Fall through to a direct request.
                        debug!(error = %err, "flaresolverr timed out, falling back to direct fetch");
                    }
                    Err(err) => return Err(err),
                }
            }
        }

        let resp = self
            .http
            .get(url)
            .send()
            .await
            .map_err(IndexerError::from)?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.ok();
            return Err(IndexerError::from_response_status(
                status.as_u16(),
                None,
                body.as_deref(),
            ));
        }
        resp.text().await.map_err(IndexerError::from)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn template_context_includes_query_and_config() {
        let req = SearchRequest {
            keywords: Some("matrix".into()),
            imdb_id: Some("tt0133093".into()),
            categories: vec![2000, 5000],
            config: serde_json::json!({ "sort": "seeders" }),
            ..SearchRequest::default()
        };
        let ctx = req.template_context();
        assert_eq!(ctx["Query"]["Keywords"], "matrix");
        assert_eq!(ctx["Query"]["IMDBID"], "tt0133093");
        assert_eq!(ctx["Query"]["IMDBIDShort"], "0133093");
        assert_eq!(ctx["Config"]["sort"], "seeders");
        assert!(ctx["Query"]["Categories"].is_array());
    }
}
