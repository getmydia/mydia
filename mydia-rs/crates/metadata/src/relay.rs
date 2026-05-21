//! metadata-relay client — Rust port of
//! `lib/mydia/metadata/provider/relay.ex`.
//!
//! Talks to the self-hosted metadata-relay service (default endpoint
//! `https://relay.mydia.dev`), which proxies TMDB and TVDB. The
//! Elixir source is 980 lines and mostly response shaping; this
//! module mirrors the same endpoint paths and parsing rules.
//!
//! ## Endpoints (TMDB-side)
//!
//! - `/tmdb/movies/search` — movie search
//! - `/tmdb/tv/search` — TV search
//! - `/tmdb/movies/{id}` — movie details
//! - `/tmdb/tv/shows/{id}` — TV show details
//! - `/tmdb/movies/{id}/images` — movie images
//! - `/tmdb/tv/shows/{id}/images` — TV show images
//! - `/tmdb/tv/shows/{id}/{season_number}` — TV season details
//! - `/tmdb/movies/trending`, `/tmdb/tv/trending` — trending
//! - `/tmdb/movies/popular`, `/tmdb/tv/popular`, ... — curated lists
//! - `/tmdb/genre/movie`, `/tmdb/genre/tv` — genre lists
//!
//! ## Endpoints (TVDB-side)
//!
//! - `/tvdb/search` — TVDB-native search
//! - `/tvdb/series/{id}/extended` — series details (with `meta=translations`)
//! - `/tvdb/seasons/{id}/extended` — season details
//! - `/tvdb/episodes/{id}/extended` — per-episode translations
//!
//! The TVDB shape is normalized into TMDB-like JSON before the parser
//! runs, so the parsing functions see one shape regardless of source.

use async_trait::async_trait;
use chrono::NaiveDate;
use serde_json::Value;

use crate::error::MetadataError;
use crate::http::HttpClient;
use crate::provider::{
    FetchOpts, ImageOpts, Provider, ProviderConfig, SearchOpts, SeasonOpts, TrendingOpts,
};
use crate::structs::{
    CastMember, ConnectionInfo, CrewMember, EpisodeData, ImageData, ImagesResponse, MediaMetadata,
    MediaType, ProviderKind, SearchResult, SeasonData, SeasonInfo, Video,
};

const DEFAULT_LANGUAGE: &str = "en-US";

/// The metadata-relay adapter. Stateless — all configuration lives on
/// the [`ProviderConfig`] passed at call time. Reuse instances freely.
#[derive(Debug, Default, Clone)]
pub struct Relay;

impl Relay {
    /// Construct a new adapter. Equivalent to `Relay {}`.
    #[must_use]
    pub fn new() -> Self {
        Self
    }

    fn resolved_language(config: &ProviderConfig, override_lang: Option<&str>) -> String {
        override_lang.map_or_else(
            || config.option_str("language", DEFAULT_LANGUAGE).to_string(),
            str::to_string,
        )
    }
}

#[async_trait]
impl Provider for Relay {
    async fn test_connection(
        &self,
        config: &ProviderConfig,
    ) -> Result<ConnectionInfo, MetadataError> {
        let client = HttpClient::new(config)?;
        let _body: Value = client.get_value("/configuration", &[], config).await?;
        Ok(ConnectionInfo {
            status: "ok".into(),
            provider: "metadata_relay".into(),
        })
    }

    async fn search(
        &self,
        config: &ProviderConfig,
        query: &str,
        opts: &SearchOpts,
    ) -> Result<Vec<SearchResult>, MetadataError> {
        if query.is_empty() {
            return Err(MetadataError::invalid_request(
                "Query must be a non-empty string",
            ));
        }

        if matches!(opts.media_type, Some(MediaType::TvShow))
            && matches!(opts.provider_pref(), Some("tvdb"))
        {
            search_tvdb(config, query, opts).await
        } else {
            search_tmdb(config, query, opts).await
        }
    }

    async fn fetch_by_id(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        opts: &FetchOpts,
    ) -> Result<MediaMetadata, MetadataError> {
        let media_type = opts.media_type.unwrap_or(MediaType::Movie);
        let provider_pref = opts.provider;

        // TVDB when explicitly requested, or implicitly for TV shows
        // when not pinned to TMDB. Mirrors the Elixir routing rule.
        let use_tvdb = matches!(provider_pref, Some("tvdb"))
            || (matches!(media_type, MediaType::TvShow) && !matches!(provider_pref, Some("tmdb")));

        if use_tvdb {
            fetch_tvdb_by_id(config, provider_id, media_type).await
        } else {
            fetch_tmdb_by_id(config, provider_id, media_type, opts).await
        }
    }

    async fn fetch_images(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        opts: &ImageOpts,
    ) -> Result<ImagesResponse, MetadataError> {
        let media_type = opts.media_type.unwrap_or(MediaType::Movie);
        let provider_pref = opts.provider;

        let use_tvdb = matches!(provider_pref, Some("tvdb"))
            || (matches!(media_type, MediaType::TvShow) && !matches!(provider_pref, Some("tmdb")));

        if use_tvdb {
            fetch_tvdb_images(config, provider_id).await
        } else {
            fetch_tmdb_images(config, provider_id, media_type, opts).await
        }
    }

    async fn fetch_season(
        &self,
        config: &ProviderConfig,
        provider_id: &str,
        season_number: i32,
        opts: &SeasonOpts,
    ) -> Result<SeasonData, MetadataError> {
        if let Some(tvdb_season_id) = opts.tvdb_season_id {
            fetch_season_tvdb(config, tvdb_season_id).await
        } else {
            fetch_season_tmdb(config, provider_id, season_number, opts).await
        }
    }

    async fn fetch_trending(
        &self,
        config: &ProviderConfig,
        opts: &TrendingOpts,
    ) -> Result<Vec<SearchResult>, MetadataError> {
        let endpoint = trending_endpoint(opts.media_type);
        let language = Self::resolved_language(config, opts.language.as_deref());
        let page = opts.page.unwrap_or(1);
        let params = vec![
            ("language".to_string(), language),
            ("page".to_string(), page.to_string()),
        ];

        let client = HttpClient::new(config)?;
        let body: Value = client
            .get_value(endpoint, &string_params(&params), config)
            .await?;
        Ok(parse_search_results(&body, opts.media_type))
    }
}

// Helper trait for `Option<&'static str>` provider hint extraction in
// the search path. Defined here so we can reuse the inline match.
trait ProviderPref {
    fn provider_pref(&self) -> Option<&str>;
}
impl ProviderPref for SearchOpts {
    fn provider_pref(&self) -> Option<&str> {
        // SearchOpts has no `provider` field today (matches Elixir
        // search/3, which doesn't accept :provider). Reserved for
        // future use.
        None
    }
}

// ---------------------------------------------------------------------
// Search
// ---------------------------------------------------------------------

async fn search_tmdb(
    config: &ProviderConfig,
    query: &str,
    opts: &SearchOpts,
) -> Result<Vec<SearchResult>, MetadataError> {
    let media_type = opts.media_type;
    let endpoint = search_endpoint(media_type);
    let language = Relay::resolved_language(config, opts.language.as_deref());
    let include_adult = opts
        .include_adult
        .unwrap_or_else(|| config.option_bool("include_adult", false));
    let page = opts.page.unwrap_or(1);

    let mut params = vec![
        ("query".to_string(), query.to_string()),
        ("language".to_string(), language),
        ("include_adult".to_string(), include_adult.to_string()),
        ("page".to_string(), page.to_string()),
    ];

    if let Some(year) = opts.year {
        match media_type {
            Some(MediaType::Movie) | None => params.push(("year".into(), year.to_string())),
            Some(MediaType::TvShow) => {
                params.push(("first_air_date_year".into(), year.to_string()));
            }
            Some(MediaType::Book) => {}
        }
    }

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(endpoint, &string_params(&params), config)
        .await?;
    Ok(parse_search_results(&body, media_type))
}

async fn search_tvdb(
    config: &ProviderConfig,
    query: &str,
    opts: &SearchOpts,
) -> Result<Vec<SearchResult>, MetadataError> {
    let mut params = vec![
        ("query".to_string(), query.to_string()),
        ("type".to_string(), "series".to_string()),
    ];
    if let Some(year) = opts.year {
        params.push(("year".into(), year.to_string()));
    }

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value("/tvdb/search", &string_params(&params), config)
        .await?;
    Ok(parse_tvdb_search_results(&body))
}

fn search_endpoint(media_type: Option<MediaType>) -> &'static str {
    match media_type {
        Some(MediaType::TvShow) => "/tmdb/tv/search",
        _ => "/tmdb/movies/search",
    }
}

fn trending_endpoint(media_type: Option<MediaType>) -> &'static str {
    match media_type {
        Some(MediaType::TvShow) => "/tmdb/tv/trending",
        _ => "/tmdb/movies/trending",
    }
}

fn details_endpoint(media_type: MediaType, id: &str) -> String {
    match media_type {
        MediaType::TvShow => format!("/tmdb/tv/shows/{id}"),
        _ => format!("/tmdb/movies/{id}"),
    }
}

fn images_endpoint(media_type: MediaType, id: &str) -> String {
    match media_type {
        MediaType::TvShow => format!("/tmdb/tv/shows/{id}/images"),
        _ => format!("/tmdb/movies/{id}/images"),
    }
}

// ---------------------------------------------------------------------
// Fetch by ID — TMDB
// ---------------------------------------------------------------------

async fn fetch_tmdb_by_id(
    config: &ProviderConfig,
    provider_id: &str,
    media_type: MediaType,
    opts: &FetchOpts,
) -> Result<MediaMetadata, MetadataError> {
    let endpoint = details_endpoint(media_type, provider_id);
    let language = Relay::resolved_language(config, opts.language.as_deref());

    let append = if opts.append_to_response.is_empty() {
        vec![
            "credits".to_string(),
            "alternative_titles".to_string(),
            "videos".to_string(),
        ]
    } else {
        opts.append_to_response.clone()
    };

    let params = vec![
        ("language".to_string(), language),
        ("append_to_response".to_string(), append.join(",")),
    ];

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(&endpoint, &string_params(&params), config)
        .await?;
    Ok(parse_metadata(
        &body,
        media_type,
        provider_id,
        ProviderKind::MetadataRelay,
    ))
}

// ---------------------------------------------------------------------
// Fetch by ID — TVDB
// ---------------------------------------------------------------------

async fn fetch_tvdb_by_id(
    config: &ProviderConfig,
    provider_id: &str,
    media_type: MediaType,
) -> Result<MediaMetadata, MetadataError> {
    let endpoint = format!("/tvdb/series/{provider_id}/extended");
    let params = vec![("meta".to_string(), "translations".to_string())];

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(&endpoint, &string_params(&params), config)
        .await?;

    let data = body.get("data").cloned().unwrap_or(body);
    let transformed = transform_tvdb_to_tmdb_format(&data);
    let mut metadata = parse_metadata(
        &transformed,
        media_type,
        provider_id,
        ProviderKind::MetadataRelay,
    );
    metadata.provider = ProviderKind::Tvdb;
    Ok(metadata)
}

fn transform_tvdb_to_tmdb_format(data: &Value) -> Value {
    let translations = data.get("translations").cloned().unwrap_or(Value::Null);

    let english_name =
        extract_tvdb_english_translation(translations.get("nameTranslations"), "name");
    let english_overview =
        extract_tvdb_english_translation(translations.get("overviewTranslations"), "overview");

    let seasons = transform_tvdb_seasons(data.get("seasons"));
    let genres = transform_tvdb_genres(data.get("genres"));

    let mut obj = serde_json::Map::new();
    obj.insert("id".into(), data.get("id").cloned().unwrap_or(Value::Null));
    obj.insert(
        "name".into(),
        english_name.unwrap_or_else(|| data.get("name").cloned().unwrap_or(Value::Null)),
    );
    obj.insert(
        "original_name".into(),
        data.get("originalName")
            .cloned()
            .or_else(|| data.get("name").cloned())
            .unwrap_or(Value::Null),
    );
    obj.insert(
        "overview".into(),
        english_overview.unwrap_or_else(|| data.get("overview").cloned().unwrap_or(Value::Null)),
    );
    obj.insert(
        "first_air_date".into(),
        data.get("firstAired").cloned().unwrap_or(Value::Null),
    );
    obj.insert(
        "last_air_date".into(),
        data.get("lastAired").cloned().unwrap_or(Value::Null),
    );
    obj.insert(
        "status".into(),
        data.get("status")
            .and_then(|s| s.get("name"))
            .cloned()
            .unwrap_or(Value::Null),
    );
    obj.insert(
        "poster_path".into(),
        data.get("image").cloned().unwrap_or(Value::Null),
    );
    obj.insert(
        "backdrop_path".into(),
        transform_tvdb_artwork(data.get("artworks"), "background"),
    );
    obj.insert("genres".into(), Value::Array(genres));
    obj.insert(
        "popularity".into(),
        data.get("score").cloned().unwrap_or(Value::Null),
    );
    obj.insert("vote_average".into(), Value::Null);
    obj.insert(
        "number_of_seasons".into(),
        Value::from(seasons.len() as i64),
    );

    let episode_count = data
        .get("episodes")
        .and_then(Value::as_array)
        .map_or(0, Vec::len);
    obj.insert(
        "number_of_episodes".into(),
        Value::from(episode_count as i64),
    );

    let in_production = data
        .get("status")
        .and_then(|s| s.get("name"))
        .and_then(Value::as_str)
        .is_some_and(|name| name == "Continuing");
    obj.insert("in_production".into(), Value::from(in_production));

    obj.insert("seasons".into(), Value::Array(seasons));
    obj.insert(
        "origin_country".into(),
        transform_tvdb_origin_country(data.get("originalCountry")),
    );
    obj.insert(
        "original_language".into(),
        data.get("originalLanguage").cloned().unwrap_or(Value::Null),
    );

    Value::Object(obj)
}

fn transform_tvdb_seasons(seasons: Option<&Value>) -> Vec<Value> {
    let Some(arr) = seasons.and_then(Value::as_array) else {
        return Vec::new();
    };

    arr.iter()
        .filter(|s| {
            s.get("type")
                .and_then(|t| t.get("type"))
                .and_then(Value::as_str)
                == Some("official")
        })
        .map(|s| {
            let number = s.get("number").cloned().unwrap_or(Value::Null);
            let name = s.get("name").and_then(Value::as_str).map_or_else(
                || format!("Season {}", number.as_i64().unwrap_or(0)),
                str::to_string,
            );

            let mut entry = serde_json::Map::new();
            entry.insert("id".into(), s.get("id").cloned().unwrap_or(Value::Null));
            entry.insert("season_number".into(), number);
            entry.insert("name".into(), Value::from(name));
            entry.insert(
                "overview".into(),
                s.get("overview").cloned().unwrap_or(Value::Null),
            );
            entry.insert(
                "poster_path".into(),
                s.get("image").cloned().unwrap_or(Value::Null),
            );
            entry.insert("air_date".into(), Value::Null);
            entry.insert(
                "episode_count".into(),
                s.get("episodeCount").cloned().unwrap_or(Value::from(0)),
            );
            entry.insert(
                "tvdb_season_id".into(),
                s.get("id").cloned().unwrap_or(Value::Null),
            );
            Value::Object(entry)
        })
        .collect()
}

fn transform_tvdb_genres(genres: Option<&Value>) -> Vec<Value> {
    let Some(arr) = genres.and_then(Value::as_array) else {
        return Vec::new();
    };

    arr.iter()
        .map(|g| {
            let mut entry = serde_json::Map::new();
            entry.insert("id".into(), g.get("id").cloned().unwrap_or(Value::Null));
            entry.insert("name".into(), g.get("name").cloned().unwrap_or(Value::Null));
            Value::Object(entry)
        })
        .collect()
}

fn transform_tvdb_origin_country(country: Option<&Value>) -> Value {
    match country {
        Some(Value::String(s)) => Value::Array(vec![Value::String(s.clone())]),
        Some(Value::Array(arr)) => Value::Array(arr.clone()),
        // None / Null / unsupported shape — empty list matches the
        // Elixir default.
        _ => Value::Array(vec![]),
    }
}

fn extract_tvdb_english_translation(translations: Option<&Value>, field: &str) -> Option<Value> {
    let arr = translations?.as_array()?;
    arr.iter()
        .find(|t| t.get("language").and_then(Value::as_str) == Some("eng"))
        .and_then(|t| t.get(field).cloned())
}

const TVDB_ARTWORK_BACKGROUND_ID: i64 = 3;
const TVDB_ARTWORK_POSTER_ID: i64 = 2;
const TVDB_ARTWORK_BANNER_ID: i64 = 1;

fn tvdb_artwork_type_id(name: &str) -> Option<i64> {
    match name {
        "background" => Some(TVDB_ARTWORK_BACKGROUND_ID),
        "poster" => Some(TVDB_ARTWORK_POSTER_ID),
        "banner" => Some(TVDB_ARTWORK_BANNER_ID),
        _ => None,
    }
}

fn transform_tvdb_artwork(artworks: Option<&Value>, type_name: &str) -> Value {
    let Some(arr) = artworks.and_then(Value::as_array) else {
        return Value::Null;
    };
    let type_id = tvdb_artwork_type_id(type_name);

    let matched = arr.iter().find(|a| match a.get("type") {
        Some(Value::Object(_)) => {
            a.get("type")
                .and_then(|t| t.get("name"))
                .and_then(Value::as_str)
                == Some(type_name)
        }
        Some(Value::String(s)) => s == type_name,
        Some(Value::Number(n)) => type_id.is_some() && n.as_i64() == type_id,
        _ => false,
    });

    matched
        .and_then(|a| a.get("image").cloned().or_else(|| a.get("url").cloned()))
        .unwrap_or(Value::Null)
}

// ---------------------------------------------------------------------
// Fetch images
// ---------------------------------------------------------------------

async fn fetch_tmdb_images(
    config: &ProviderConfig,
    provider_id: &str,
    media_type: MediaType,
    opts: &ImageOpts,
) -> Result<ImagesResponse, MetadataError> {
    let endpoint = images_endpoint(media_type, provider_id);
    let mut params = Vec::new();
    if let Some(lang) = &opts.language {
        params.push(("language".into(), lang.clone()));
    }
    if let Some(lang) = &opts.include_image_language {
        params.push(("include_image_language".into(), lang.clone()));
    }

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(&endpoint, &string_params(&params), config)
        .await?;
    Ok(parse_images(&body))
}

async fn fetch_tvdb_images(
    config: &ProviderConfig,
    provider_id: &str,
) -> Result<ImagesResponse, MetadataError> {
    let endpoint = format!("/tvdb/series/{provider_id}/extended");
    let client = HttpClient::new(config)?;
    let body: Value = client.get_value(&endpoint, &[], config).await?;
    let data = body.get("data").cloned().unwrap_or(body);
    Ok(parse_tvdb_artworks(data.get("artworks")))
}

fn parse_tvdb_artworks(artworks: Option<&Value>) -> ImagesResponse {
    let Some(arr) = artworks.and_then(Value::as_array) else {
        return ImagesResponse::default();
    };

    let mut posters = Vec::new();
    let mut backdrops = Vec::new();

    for artwork in arr {
        let type_name = match artwork.get("type") {
            Some(Value::Object(_)) => artwork
                .get("type")
                .and_then(|t| t.get("name"))
                .and_then(Value::as_str),
            Some(Value::String(s)) => Some(s.as_str()),
            _ => None,
        };

        let image_url = artwork
            .get("image")
            .and_then(Value::as_str)
            .or_else(|| artwork.get("url").and_then(Value::as_str))
            .map(str::to_string);

        let entry = ImageData {
            file_path: image_url,
            width: artwork
                .get("width")
                .and_then(Value::as_u64)
                .map(|w| w as u32),
            height: artwork
                .get("height")
                .and_then(Value::as_u64)
                .map(|h| h as u32),
            ..Default::default()
        };

        match type_name {
            Some("poster") => posters.push(entry),
            Some("background") => backdrops.push(entry),
            _ => {}
        }
    }

    ImagesResponse {
        posters,
        backdrops,
        logos: Vec::new(),
    }
}

// ---------------------------------------------------------------------
// Fetch season
// ---------------------------------------------------------------------

async fn fetch_season_tmdb(
    config: &ProviderConfig,
    provider_id: &str,
    season_number: i32,
    opts: &SeasonOpts,
) -> Result<SeasonData, MetadataError> {
    let endpoint = format!("/tmdb/tv/shows/{provider_id}/{season_number}");
    let language = Relay::resolved_language(config, opts.language.as_deref());
    let params = vec![("language".into(), language)];

    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(&endpoint, &string_params(&params), config)
        .await?;
    Ok(parse_season(&body))
}

async fn fetch_season_tvdb(
    config: &ProviderConfig,
    tvdb_season_id: i64,
) -> Result<SeasonData, MetadataError> {
    let endpoint = format!("/tvdb/seasons/{tvdb_season_id}/extended");
    let client = HttpClient::new(config)?;
    let body: Value = client
        .get_value(
            &endpoint,
            &string_params(&[("meta".into(), "translations".into())]),
            config,
        )
        .await?;
    let data = body.get("data").cloned().unwrap_or(body);
    Ok(parse_season_tvdb(&data))
}

// ---------------------------------------------------------------------
// Parsers
// ---------------------------------------------------------------------

fn parse_search_results(body: &Value, media_type: Option<MediaType>) -> Vec<SearchResult> {
    let Some(results) = body.get("results").and_then(Value::as_array) else {
        return Vec::new();
    };
    results
        .iter()
        .map(|r| parse_search_result(r, media_type))
        .collect()
}

fn parse_search_result(data: &Value, media_type_override: Option<MediaType>) -> SearchResult {
    let media_type = media_type_override
        .or_else(|| normalize_media_type(data.get("media_type").and_then(Value::as_str)))
        .unwrap_or(MediaType::Movie);

    let title = get_title(data, media_type);
    let year = extract_year(data, media_type);

    SearchResult {
        provider_id: to_string_field(data.get("id")),
        provider: ProviderKind::MetadataRelay,
        media_type,
        title,
        original_title: data
            .get("original_title")
            .or_else(|| data.get("original_name"))
            .and_then(Value::as_str)
            .map(str::to_string),
        name: data.get("name").and_then(Value::as_str).map(str::to_string),
        original_name: data
            .get("original_name")
            .and_then(Value::as_str)
            .map(str::to_string),
        year,
        release_date: data
            .get("release_date")
            .and_then(Value::as_str)
            .map(str::to_string),
        first_air_date: data
            .get("first_air_date")
            .and_then(Value::as_str)
            .map(str::to_string),
        poster_path: data
            .get("poster_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        backdrop_path: data
            .get("backdrop_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        id: data.get("id").and_then(Value::as_i64),
        imdb_id: data
            .get("imdb_id")
            .and_then(Value::as_str)
            .map(str::to_string),
        overview: data
            .get("overview")
            .and_then(Value::as_str)
            .map(str::to_string),
        popularity: data.get("popularity").and_then(Value::as_f64),
        vote_average: data.get("vote_average").and_then(Value::as_f64),
        vote_count: data.get("vote_count").and_then(Value::as_i64),
    }
}

fn parse_tvdb_search_results(body: &Value) -> Vec<SearchResult> {
    let Some(data) = body.get("data").and_then(Value::as_array) else {
        return Vec::new();
    };
    data.iter().map(parse_tvdb_search_result).collect()
}

fn parse_tvdb_search_result(data: &Value) -> SearchResult {
    let provider_id = data
        .get("tvdb_id")
        .or_else(|| data.get("id"))
        .map(value_to_string)
        .unwrap_or_default();

    let year = match data.get("year") {
        Some(Value::String(s)) => s
            .parse::<i32>()
            .ok()
            .or_else(|| extract_year_from_date(data.get("first_air_time").and_then(Value::as_str))),
        Some(Value::Number(n)) => n.as_i64().map(|n| n as i32),
        _ => extract_year_from_date(data.get("first_air_time").and_then(Value::as_str)),
    };

    let translations = data.get("translations").cloned().unwrap_or(Value::Null);
    let english_title = translations
        .get("eng")
        .and_then(Value::as_str)
        .map(str::to_string);
    let display_title = english_title
        .clone()
        .or_else(|| data.get("name").and_then(Value::as_str).map(str::to_string));

    let overviews = data.get("overviews").cloned().unwrap_or(Value::Null);
    let english_overview = overviews
        .get("eng")
        .and_then(Value::as_str)
        .map(str::to_string);
    let display_overview = english_overview.or_else(|| {
        data.get("overview")
            .and_then(Value::as_str)
            .map(str::to_string)
    });

    SearchResult {
        provider_id,
        provider: ProviderKind::Tvdb,
        media_type: MediaType::TvShow,
        title: display_title.clone(),
        name: display_title,
        original_title: data.get("name").and_then(Value::as_str).map(str::to_string),
        original_name: None,
        year,
        overview: display_overview,
        poster_path: data
            .get("image_url")
            .and_then(Value::as_str)
            .map(str::to_string),
        backdrop_path: None,
        first_air_date: data
            .get("first_air_time")
            .and_then(Value::as_str)
            .map(str::to_string),
        release_date: None,
        id: data
            .get("tvdb_id")
            .or_else(|| data.get("id"))
            .and_then(Value::as_i64),
        imdb_id: None,
        popularity: None,
        vote_average: None,
        vote_count: None,
    }
}

fn parse_metadata(
    data: &Value,
    media_type: MediaType,
    provider_id: &str,
    provider: ProviderKind,
) -> MediaMetadata {
    let title = get_title(data, media_type);
    let year = extract_year(data, media_type);
    let release_date = parse_date(get_release_date(data, media_type));

    let mut metadata = MediaMetadata {
        provider_id: provider_id.to_string(),
        provider,
        media_type,
        id: data.get("id").and_then(Value::as_i64),
        title,
        original_title: data
            .get("original_title")
            .or_else(|| data.get("original_name"))
            .and_then(Value::as_str)
            .map(str::to_string),
        year,
        release_date,
        overview: data
            .get("overview")
            .and_then(Value::as_str)
            .map(str::to_string),
        tagline: data
            .get("tagline")
            .and_then(Value::as_str)
            .map(str::to_string),
        runtime: get_runtime(data, media_type),
        status: data
            .get("status")
            .and_then(Value::as_str)
            .map(str::to_string),
        genres: parse_genres(data.get("genres")),
        poster_path: data
            .get("poster_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        backdrop_path: data
            .get("backdrop_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        popularity: data.get("popularity").and_then(Value::as_f64),
        vote_average: data.get("vote_average").and_then(Value::as_f64),
        vote_count: data.get("vote_count").and_then(Value::as_i64),
        imdb_id: data
            .get("imdb_id")
            .and_then(Value::as_str)
            .map(str::to_string),
        production_companies: parse_named_list(data.get("production_companies"), "name"),
        production_countries: parse_named_list(data.get("production_countries"), "iso_3166_1"),
        spoken_languages: parse_named_list(data.get("spoken_languages"), "iso_639_1"),
        homepage: data
            .get("homepage")
            .and_then(Value::as_str)
            .map(str::to_string),
        cast: parse_cast(data.get("credits").and_then(|c| c.get("cast"))),
        crew: parse_crew(data.get("credits").and_then(|c| c.get("crew"))),
        alternative_titles: parse_alternative_titles(data.get("alternative_titles")),
        videos: parse_videos(data.get("videos")),
        origin_country: parse_origin_country(data.get("origin_country")),
        original_language: data
            .get("original_language")
            .and_then(Value::as_str)
            .map(str::to_string),
        number_of_seasons: None,
        number_of_episodes: None,
        episode_run_time: Vec::new(),
        first_air_date: None,
        last_air_date: None,
        in_production: None,
        seasons: Vec::new(),
    };

    if matches!(media_type, MediaType::TvShow) {
        metadata.number_of_seasons = data
            .get("number_of_seasons")
            .and_then(Value::as_i64)
            .map(|n| n as i32);
        metadata.number_of_episodes = data
            .get("number_of_episodes")
            .and_then(Value::as_i64)
            .map(|n| n as i32);
        metadata.episode_run_time = data
            .get("episode_run_time")
            .and_then(Value::as_array)
            .map(|arr| {
                arr.iter()
                    .filter_map(Value::as_i64)
                    .map(|n| n as i32)
                    .collect()
            })
            .unwrap_or_default();
        metadata.first_air_date = parse_date(data.get("first_air_date").and_then(Value::as_str));
        metadata.last_air_date = parse_date(data.get("last_air_date").and_then(Value::as_str));
        metadata.in_production = data.get("in_production").and_then(Value::as_bool);
        metadata.seasons = parse_seasons_list(data.get("seasons"));
    }

    metadata
}

fn parse_images(data: &Value) -> ImagesResponse {
    fn parse_image_list(arr: Option<&Value>) -> Vec<ImageData> {
        arr.and_then(Value::as_array)
            .map(|items| items.iter().map(parse_image).collect())
            .unwrap_or_default()
    }

    ImagesResponse {
        posters: parse_image_list(data.get("posters")),
        backdrops: parse_image_list(data.get("backdrops")),
        logos: parse_image_list(data.get("logos")),
    }
}

fn parse_image(data: &Value) -> ImageData {
    ImageData {
        file_path: data
            .get("file_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        width: data.get("width").and_then(Value::as_u64).map(|w| w as u32),
        height: data.get("height").and_then(Value::as_u64).map(|h| h as u32),
        aspect_ratio: data.get("aspect_ratio").and_then(Value::as_f64),
        vote_average: data.get("vote_average").and_then(Value::as_f64),
        vote_count: data
            .get("vote_count")
            .and_then(Value::as_u64)
            .map(|v| v as u32),
    }
}

fn parse_season(data: &Value) -> SeasonData {
    let episodes = data
        .get("episodes")
        .and_then(Value::as_array)
        .map(|arr| arr.iter().map(parse_episode).collect::<Vec<_>>())
        .unwrap_or_default();
    let episode_count = episodes.len() as i32;

    SeasonData {
        season_number: data
            .get("season_number")
            .and_then(Value::as_i64)
            .map_or(0, |n| n as i32),
        name: data.get("name").and_then(Value::as_str).map(str::to_string),
        overview: data
            .get("overview")
            .and_then(Value::as_str)
            .map(str::to_string),
        air_date: parse_date(data.get("air_date").and_then(Value::as_str)),
        poster_path: data
            .get("poster_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        episode_count: Some(episode_count),
        episodes,
    }
}

fn parse_season_tvdb(data: &Value) -> SeasonData {
    let episodes_arr = data
        .get("episodes")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();

    let translations = data.get("translations").cloned().unwrap_or(Value::Null);
    let english_name =
        extract_tvdb_english_translation(translations.get("nameTranslations"), "name");
    let english_overview =
        extract_tvdb_english_translation(translations.get("overviewTranslations"), "overview");

    let season_number = data
        .get("number")
        .and_then(Value::as_i64)
        .map_or(0, |n| n as i32);

    let name = english_name
        .and_then(|v| v.as_str().map(str::to_string))
        .or_else(|| data.get("name").and_then(Value::as_str).map(str::to_string))
        .or_else(|| Some(format!("Season {season_number}")));

    let overview = english_overview
        .and_then(|v| v.as_str().map(str::to_string))
        .or_else(|| {
            data.get("overview")
                .and_then(Value::as_str)
                .map(str::to_string)
        });

    let episodes: Vec<EpisodeData> = episodes_arr.iter().map(parse_episode_tvdb).collect();
    let episode_count = episodes.len() as i32;

    SeasonData {
        season_number,
        name,
        overview,
        air_date: None,
        poster_path: data
            .get("image")
            .and_then(Value::as_str)
            .map(str::to_string),
        episode_count: Some(episode_count),
        episodes,
    }
}

fn parse_episode(data: &Value) -> EpisodeData {
    EpisodeData {
        season_number: data
            .get("season_number")
            .and_then(Value::as_i64)
            .map_or(0, |n| n as i32),
        episode_number: data
            .get("episode_number")
            .and_then(Value::as_i64)
            .map_or(0, |n| n as i32),
        name: data.get("name").and_then(Value::as_str).map(str::to_string),
        overview: data
            .get("overview")
            .and_then(Value::as_str)
            .map(str::to_string),
        air_date: parse_date(data.get("air_date").and_then(Value::as_str)),
        runtime: data
            .get("runtime")
            .and_then(Value::as_i64)
            .map(|n| n as i32),
        still_path: data
            .get("still_path")
            .and_then(Value::as_str)
            .map(str::to_string),
        vote_average: data.get("vote_average").and_then(Value::as_f64),
        vote_count: data.get("vote_count").and_then(Value::as_i64),
    }
}

fn parse_episode_tvdb(data: &Value) -> EpisodeData {
    let translations = data.get("translations").cloned().unwrap_or(Value::Null);
    let english_name =
        extract_tvdb_english_translation(translations.get("nameTranslations"), "name")
            .and_then(|v| v.as_str().map(str::to_string));
    let english_overview =
        extract_tvdb_english_translation(translations.get("overviewTranslations"), "overview")
            .and_then(|v| v.as_str().map(str::to_string));

    EpisodeData {
        season_number: data
            .get("seasonNumber")
            .and_then(Value::as_i64)
            .map_or(0, |n| n as i32),
        episode_number: data
            .get("number")
            .and_then(Value::as_i64)
            .map_or(0, |n| n as i32),
        name: english_name.or_else(|| data.get("name").and_then(Value::as_str).map(str::to_string)),
        overview: english_overview.or_else(|| {
            data.get("overview")
                .and_then(Value::as_str)
                .map(str::to_string)
        }),
        air_date: parse_date(data.get("aired").and_then(Value::as_str)),
        runtime: data
            .get("runtime")
            .and_then(Value::as_i64)
            .map(|n| n as i32),
        still_path: data
            .get("image")
            .and_then(Value::as_str)
            .map(str::to_string),
        vote_average: None,
        vote_count: None,
    }
}

fn parse_seasons_list(seasons: Option<&Value>) -> Vec<SeasonInfo> {
    let Some(arr) = seasons.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .map(|s| SeasonInfo {
            season_number: s
                .get("season_number")
                .and_then(Value::as_i64)
                .map_or(0, |n| n as i32),
            name: s.get("name").and_then(Value::as_str).map(str::to_string),
            overview: s
                .get("overview")
                .and_then(Value::as_str)
                .map(str::to_string),
            air_date: s
                .get("air_date")
                .and_then(Value::as_str)
                .map(str::to_string),
            episode_count: s
                .get("episode_count")
                .and_then(Value::as_i64)
                .map(|n| n as i32),
            poster_path: s
                .get("poster_path")
                .and_then(Value::as_str)
                .map(str::to_string),
            tvdb_season_id: s.get("tvdb_season_id").and_then(Value::as_i64),
        })
        .collect()
}

fn parse_genres(genres: Option<&Value>) -> Vec<String> {
    parse_named_list(genres, "name")
}

fn parse_named_list(items: Option<&Value>, key: &str) -> Vec<String> {
    let Some(arr) = items.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter_map(|item| item.get(key).and_then(Value::as_str).map(str::to_string))
        .collect()
}

fn parse_origin_country(value: Option<&Value>) -> Vec<String> {
    match value {
        Some(Value::Array(arr)) => arr
            .iter()
            .filter_map(|v| v.as_str().map(str::to_string))
            .collect(),
        _ => Vec::new(),
    }
}

fn parse_cast(value: Option<&Value>) -> Vec<CastMember> {
    let Some(arr) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .take(20)
        .filter_map(|member| {
            let name = member.get("name").and_then(Value::as_str)?.to_string();
            Some(CastMember {
                name,
                character: member
                    .get("character")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                order: member
                    .get("order")
                    .and_then(Value::as_i64)
                    .map(|n| n as i32),
                profile_path: member
                    .get("profile_path")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect()
}

fn parse_crew(value: Option<&Value>) -> Vec<CrewMember> {
    const ALLOWED_JOBS: &[&str] = &["Director", "Producer", "Writer", "Screenplay"];
    let Some(arr) = value.and_then(Value::as_array) else {
        return Vec::new();
    };
    arr.iter()
        .filter(|m| {
            m.get("job")
                .and_then(Value::as_str)
                .is_some_and(|j| ALLOWED_JOBS.contains(&j))
        })
        .take(10)
        .filter_map(|member| {
            let name = member.get("name").and_then(Value::as_str)?.to_string();
            let job = member.get("job").and_then(Value::as_str)?.to_string();
            Some(CrewMember {
                name,
                job,
                department: member
                    .get("department")
                    .and_then(Value::as_str)
                    .map(str::to_string),
                profile_path: member
                    .get("profile_path")
                    .and_then(Value::as_str)
                    .map(str::to_string),
            })
        })
        .collect()
}

fn parse_alternative_titles(value: Option<&Value>) -> Vec<String> {
    let Some(arr) = value
        .and_then(|v| v.get("titles"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };
    let mut seen = std::collections::HashSet::new();
    let mut out = Vec::new();
    for item in arr {
        if let Some(title) = item.get("title").and_then(Value::as_str) {
            if seen.insert(title.to_string()) {
                out.push(title.to_string());
            }
        }
    }
    out
}

fn parse_videos(value: Option<&Value>) -> Vec<Video> {
    let Some(arr) = value
        .and_then(|v| v.get("results"))
        .and_then(Value::as_array)
    else {
        return Vec::new();
    };

    let mut filtered: Vec<&Value> = arr
        .iter()
        .filter(|v| {
            v.get("site").and_then(Value::as_str) == Some("YouTube")
                && v.get("type").and_then(Value::as_str) == Some("Trailer")
        })
        .collect();

    // Match Elixir sort: official=true first, then most recent. Reverse-sort
    // on (!official, published_at) descending — i.e., official trailers
    // sort before unofficial, recent ones before older.
    filtered.sort_by(|a, b| {
        let a_official = a.get("official").and_then(Value::as_bool).unwrap_or(false);
        let b_official = b.get("official").and_then(Value::as_bool).unwrap_or(false);
        let a_pub = a.get("published_at").and_then(Value::as_str).unwrap_or("");
        let b_pub = b.get("published_at").and_then(Value::as_str).unwrap_or("");
        // official=true comes first => reverse order of bool
        b_official.cmp(&a_official).then_with(|| b_pub.cmp(a_pub))
    });

    filtered.into_iter().take(5).map(parse_video).collect()
}

fn parse_video(data: &Value) -> Video {
    let published_at = data
        .get("published_at")
        .and_then(Value::as_str)
        .and_then(|s| chrono::DateTime::parse_from_rfc3339(s).ok())
        .map(|dt| dt.with_timezone(&chrono::Utc));

    Video {
        id: data.get("id").and_then(Value::as_str).map(str::to_string),
        key: data
            .get("key")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_default(),
        name: data.get("name").and_then(Value::as_str).map(str::to_string),
        site: data
            .get("site")
            .and_then(Value::as_str)
            .map(str::to_string)
            .unwrap_or_default(),
        r#type: data.get("type").and_then(Value::as_str).map(str::to_string),
        official: data.get("official").and_then(Value::as_bool),
        published_at,
    }
}

// ---------------------------------------------------------------------
// Shared helpers
// ---------------------------------------------------------------------

fn string_params(params: &[(String, String)]) -> Vec<(&str, String)> {
    params
        .iter()
        .map(|(k, v)| (k.as_str(), v.clone()))
        .collect()
}

fn normalize_media_type(s: Option<&str>) -> Option<MediaType> {
    match s {
        Some("movie") => Some(MediaType::Movie),
        Some("tv") => Some(MediaType::TvShow),
        _ => None,
    }
}

fn get_title(data: &Value, media_type: MediaType) -> Option<String> {
    let primary = match media_type {
        MediaType::Movie | MediaType::Book => "title",
        MediaType::TvShow => "name",
    };
    let fallback = match media_type {
        MediaType::Movie | MediaType::Book => "name",
        MediaType::TvShow => "title",
    };
    data.get(primary)
        .and_then(Value::as_str)
        .or_else(|| data.get(fallback).and_then(Value::as_str))
        .map(str::to_string)
}

fn get_release_date(data: &Value, media_type: MediaType) -> Option<&str> {
    let field = match media_type {
        MediaType::Movie | MediaType::Book => "release_date",
        MediaType::TvShow => "first_air_date",
    };
    data.get(field).and_then(Value::as_str)
}

fn get_runtime(data: &Value, media_type: MediaType) -> Option<i32> {
    match media_type {
        MediaType::Movie | MediaType::Book => data
            .get("runtime")
            .and_then(Value::as_i64)
            .map(|n| n as i32),
        MediaType::TvShow => data
            .get("episode_run_time")
            .and_then(Value::as_array)
            .and_then(|arr| arr.first())
            .and_then(Value::as_i64)
            .map(|n| n as i32),
    }
}

fn extract_year(data: &Value, media_type: MediaType) -> Option<i32> {
    let field = match media_type {
        MediaType::Movie | MediaType::Book => "release_date",
        MediaType::TvShow => "first_air_date",
    };
    extract_year_from_date(data.get(field).and_then(Value::as_str))
}

fn extract_year_from_date(date: Option<&str>) -> Option<i32> {
    let date = date?;
    date.split('-').next()?.parse::<i32>().ok()
}

fn parse_date(value: Option<&str>) -> Option<NaiveDate> {
    let value = value?;
    if value.is_empty() {
        return None;
    }
    NaiveDate::parse_from_str(value, "%Y-%m-%d").ok()
}

fn to_string_field(value: Option<&Value>) -> String {
    value.map(value_to_string).unwrap_or_default()
}

fn value_to_string(value: &Value) -> String {
    match value {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        Value::Null => String::new(),
        other => other.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_search_results_handles_empty_body() {
        let body = serde_json::json!({});
        assert!(parse_search_results(&body, Some(MediaType::Movie)).is_empty());
    }

    #[test]
    fn parse_search_results_extracts_movie_fields() {
        let body = serde_json::json!({
            "results": [{
                "id": 603,
                "title": "The Matrix",
                "release_date": "1999-03-31",
                "overview": "A hacker...",
                "poster_path": "/p.jpg",
                "vote_average": 8.7
            }]
        });
        let results = parse_search_results(&body, Some(MediaType::Movie));
        assert_eq!(results.len(), 1);
        let r = &results[0];
        assert_eq!(r.provider_id, "603");
        assert_eq!(r.title.as_deref(), Some("The Matrix"));
        assert_eq!(r.year, Some(1999));
        assert_eq!(r.vote_average, Some(8.7));
    }

    #[test]
    fn parse_metadata_extracts_movie_runtime() {
        let body = serde_json::json!({
            "id": 603,
            "title": "The Matrix",
            "release_date": "1999-03-31",
            "runtime": 136,
            "genres": [{"name": "Action"}, {"name": "Science Fiction"}],
            "credits": {
                "cast": [{"name": "Keanu Reeves", "character": "Neo", "order": 0}],
                "crew": [{"name": "Lana Wachowski", "job": "Director", "department": "Directing"}]
            }
        });
        let meta = parse_metadata(&body, MediaType::Movie, "603", ProviderKind::MetadataRelay);
        assert_eq!(meta.runtime, Some(136));
        assert_eq!(meta.genres, vec!["Action", "Science Fiction"]);
        assert_eq!(meta.cast.len(), 1);
        assert_eq!(meta.cast[0].character.as_deref(), Some("Neo"));
        assert_eq!(meta.crew.len(), 1);
        assert_eq!(meta.crew[0].job, "Director");
    }

    #[test]
    fn parse_metadata_extracts_tv_runtime_from_first_episode() {
        let body = serde_json::json!({
            "id": 1396,
            "name": "Breaking Bad",
            "first_air_date": "2008-01-20",
            "episode_run_time": [45, 50],
            "number_of_seasons": 5
        });
        let meta = parse_metadata(
            &body,
            MediaType::TvShow,
            "1396",
            ProviderKind::MetadataRelay,
        );
        assert_eq!(meta.runtime, Some(45));
        assert_eq!(meta.number_of_seasons, Some(5));
        assert_eq!(meta.year, Some(2008));
    }

    #[test]
    fn parse_season_counts_episodes() {
        let body = serde_json::json!({
            "season_number": 1,
            "name": "Season 1",
            "air_date": "2008-01-20",
            "episodes": [
                {"season_number": 1, "episode_number": 1, "name": "Pilot", "air_date": "2008-01-20"},
                {"season_number": 1, "episode_number": 2, "name": "Cat's in the Bag"}
            ]
        });
        let season = parse_season(&body);
        assert_eq!(season.season_number, 1);
        assert_eq!(season.episode_count, Some(2));
        assert_eq!(season.episodes.len(), 2);
        assert_eq!(season.air_date, NaiveDate::from_ymd_opt(2008, 1, 20));
    }

    #[test]
    fn videos_sorted_official_first() {
        let body = serde_json::json!({
            "videos": {
                "results": [
                    {"site": "YouTube", "type": "Trailer", "key": "old", "official": false, "published_at": "2010-01-01T00:00:00Z"},
                    {"site": "YouTube", "type": "Trailer", "key": "new-official", "official": true, "published_at": "2024-01-01T00:00:00Z"},
                    {"site": "Vimeo", "type": "Trailer", "key": "vimeo", "official": true}
                ]
            }
        });
        let videos = parse_videos(body.get("videos"));
        assert_eq!(videos.len(), 2);
        assert_eq!(videos[0].key, "new-official");
        assert_eq!(videos[1].key, "old");
    }

    #[test]
    fn tvdb_artwork_lookup_handles_int_type() {
        let artworks = serde_json::json!([
            {"type": 3, "image": "https://example.com/bg.jpg"},
            {"type": 2, "image": "https://example.com/poster.jpg"}
        ]);
        let bg = transform_tvdb_artwork(Some(&artworks), "background");
        assert_eq!(bg.as_str(), Some("https://example.com/bg.jpg"));
    }
}
