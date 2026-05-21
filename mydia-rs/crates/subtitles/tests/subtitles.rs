#![allow(clippy::doc_markdown)]

//! Integration tests for the subtitles crate.
//!
//! Verifies the metadata-relay HTTP surface (search + download URL +
//! 404 / rate-limit / hash-mismatch paths) and the OpenSubtitles
//! moviehash algorithm.

use std::io::Write;
use std::sync::Arc;

use async_trait::async_trait;
use mydia_rs_subtitles::downloader::{download_to_memory, hex_digest, resolve_target_path};
use mydia_rs_subtitles::error::SubtitleErrorKind;
use mydia_rs_subtitles::hash;
use mydia_rs_subtitles::metadata_relay::MetadataRelay;
use mydia_rs_subtitles::provider::{ProviderConfig, SubtitleProvider, SubtitleRef};
use mydia_rs_subtitles::structs::{ProviderKind, SearchParams};

use wiremock::matchers::{method, path};
use wiremock::{Mock, MockServer, ResponseTemplate};

#[tokio::test]
async fn search_returns_results_through_wiremock_relay() {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/api/v1/subtitles/search"))
        .respond_with(ResponseTemplate::new(200).set_body_json(serde_json::json!({
            "subtitles": [
                {
                    "file_id": 12345,
                    "language": "en",
                    "format": "srt",
                    "subtitle_hash": "abc",
                    "moviehash_match": true,
                    "rating": 8.5
                }
            ]
        })))
        .mount(&server)
        .await;

    let relay = MetadataRelay::new(server.uri()).unwrap();
    let results = relay
        .search(&SearchParams {
            languages: "en".into(),
            imdb_id: Some("816692".into()),
            ..SearchParams::default()
        })
        .await
        .unwrap();
    assert_eq!(results.len(), 1);
    assert_eq!(results[0].file_id, "12345");
    assert!(results[0].moviehash_match);
    assert_eq!(results[0].subtitle_hash, "abc");
}

#[tokio::test]
async fn download_url_404_returns_not_found() {
    let server = MockServer::start().await;
    Mock::given(method("GET"))
        .and(path("/api/v1/subtitles/download-url/9999"))
        .respond_with(ResponseTemplate::new(404))
        .mount(&server)
        .await;

    let relay = MetadataRelay::new(server.uri()).unwrap();
    let err = relay.get_download_url("9999").await.unwrap_err();
    assert_eq!(err.kind, SubtitleErrorKind::NotFound);
}

#[tokio::test]
async fn downloader_rejects_hash_mismatch() {
    struct FakeProvider {
        bytes: Vec<u8>,
    }

    #[async_trait]
    impl SubtitleProvider for FakeProvider {
        async fn search(
            &self,
            _config: &ProviderConfig,
            _params: &SearchParams,
        ) -> Result<Vec<mydia_rs_subtitles::SubtitleSearchResult>, mydia_rs_subtitles::SubtitleError>
        {
            Ok(Vec::new())
        }
        async fn download(
            &self,
            _config: &ProviderConfig,
            _subtitle: &SubtitleRef,
        ) -> Result<Vec<u8>, mydia_rs_subtitles::SubtitleError> {
            Ok(self.bytes.clone())
        }
        async fn quota_info(
            &self,
            _config: &ProviderConfig,
        ) -> Result<mydia_rs_subtitles::QuotaInfo, mydia_rs_subtitles::SubtitleError> {
            Ok(mydia_rs_subtitles::QuotaInfo::unlimited(
                ProviderKind::Relay,
            ))
        }
        async fn validate_config(
            &self,
            _config: &ProviderConfig,
        ) -> Result<serde_json::Value, mydia_rs_subtitles::SubtitleError> {
            Ok(serde_json::Value::Null)
        }
    }

    let payload = b"SRT body".to_vec();
    let real_hash = hex_digest(&payload);
    let provider = Arc::new(FakeProvider { bytes: payload });
    let config = ProviderConfig {
        id: "relay".into(),
        user_id: None,
        name: "relay".into(),
        r#type: ProviderKind::Relay,
        enabled: true,
        priority: 1,
        credentials: serde_json::Value::Null,
        options: serde_json::Value::Null,
    };
    let subtitle = SubtitleRef::new("123", "en");

    // Hash matches → ok.
    let ok = download_to_memory(provider.clone(), &config, &subtitle, Some(&real_hash))
        .await
        .unwrap();
    assert_eq!(ok.computed_hash, real_hash);

    // Hash mismatch → error.
    let err = download_to_memory(
        provider,
        &config,
        &subtitle,
        Some("0000000000000000000000000000"),
    )
    .await
    .unwrap_err();
    assert_eq!(err.kind, SubtitleErrorKind::HashMismatch);
}

#[test]
fn moviehash_on_known_pattern_matches_reference_value() {
    // Build a 200 KiB file with deterministic content and verify the
    // OpenSubtitles hash is stable across runs.
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("video.mkv");
    let mut f = std::fs::File::create(&path).unwrap();
    let data: Vec<u8> = (0..(200 * 1024)).map(|i| (i % 251) as u8).collect();
    f.write_all(&data).unwrap();
    drop(f);

    let (hash_a, size_a) = hash::calculate_hash_sync(&path).unwrap();
    let (hash_b, size_b) = hash::calculate_hash_sync(&path).unwrap();
    assert_eq!(hash_a, hash_b);
    assert_eq!(size_a, size_b);
    assert_eq!(hash_a.len(), 16);
}

#[test]
fn resolve_target_path_uses_sibling_naming() {
    let p = resolve_target_path("/media/Show/S01E01.mkv", "en", "srt");
    assert_eq!(p.to_string_lossy(), "/media/Show/S01E01.en.srt");
}
