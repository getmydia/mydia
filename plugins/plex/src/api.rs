//! Plex Media Server calls. `base` is a resolved endpoint URL, `link_id` the
//! link whose token the host injects as `X-Plex-Token`.

use crate::host::Host;
use crate::http::{plex_headers, query, request, send, send_json, Auth, PlexError};
use serde::{Deserialize, Deserializer};

pub const PAGE_SIZE: u32 = 200;
const LIBRARY_IDENTIFIER: &str = "com.plexapp.plugins.library";

#[derive(Debug, Clone, Deserialize)]
pub struct Guid {
    pub id: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Section {
    #[serde(deserialize_with = "string_or_number")]
    pub key: String,
    #[serde(rename = "type")]
    pub kind: String,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Metadata {
    #[serde(rename = "ratingKey", deserialize_with = "string_or_number")]
    pub rating_key: String,
    #[serde(rename = "viewCount", default)]
    pub view_count: u32,
    #[serde(rename = "viewOffset", default)]
    pub view_offset: Option<u64>,
    #[serde(rename = "lastViewedAt", default)]
    pub last_viewed_at: Option<i64>,
    #[serde(rename = "parentIndex", default)]
    pub parent_index: Option<u32>,
    #[serde(default)]
    pub index: Option<u32>,
    #[serde(rename = "Guid", default)]
    pub guids: Vec<Guid>,
}

#[derive(Debug, Clone)]
pub struct Page {
    pub items: Vec<Metadata>,
}

#[derive(Deserialize)]
struct Container<T> {
    #[serde(rename = "MediaContainer")]
    media_container: T,
}

#[derive(Deserialize)]
struct Directories {
    #[serde(rename = "Directory", default)]
    directory: Vec<Section>,
}

#[derive(Deserialize)]
struct Metadatas {
    #[serde(rename = "Metadata", default)]
    metadata: Vec<Metadata>,
}

fn string_or_number<'de, D: Deserializer<'de>>(d: D) -> Result<String, D::Error> {
    match serde_json::Value::deserialize(d)? {
        serde_json::Value::String(s) => Ok(s),
        serde_json::Value::Number(n) => Ok(n.to_string()),
        other => Err(serde::de::Error::custom(format!(
            "expected string or number, got {other}"
        ))),
    }
}

fn url(base: &str, path: &str) -> String {
    format!("{}{}", base.trim_end_matches('/'), path)
}

pub fn sections(host: &mut dyn Host, base: &str, link_id: &str) -> Result<Vec<Section>, PlexError> {
    let req = request("GET", &url(base, "/library/sections"), plex_headers(), None);
    let c: Container<Directories> = send_json(host, &Auth::Link(link_id), req)?;
    Ok(c.media_container.directory)
}

pub fn section_items(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    section_key: &str,
    start: u32,
    since: Option<i64>,
) -> Result<Page, PlexError> {
    let mut path = format!("/library/sections/{section_key}/all?includeGuids=1");
    if let Some(since) = since {
        path.push_str(&format!("&lastViewedAt%3E={since}"));
    }
    let mut headers = plex_headers();
    headers.push(("X-Plex-Container-Start".to_string(), start.to_string()));
    headers.push(("X-Plex-Container-Size".to_string(), PAGE_SIZE.to_string()));
    let c: Container<Metadatas> = send_json(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &path), headers, None),
    )?;
    Ok(Page {
        items: c.media_container.metadata,
    })
}

/// Episodes of a show section as a flat list (`type=4`), viewed at or after
/// `since` when given. The pull pass uses this in place of one allLeaves call
/// per show per tick.
pub fn section_episodes(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    section_key: &str,
    start: u32,
    since: Option<i64>,
) -> Result<Page, PlexError> {
    let mut path = format!("/library/sections/{section_key}/all?type=4&includeGuids=1");
    if let Some(since) = since {
        path.push_str(&format!("&lastViewedAt%3E={since}"));
    }
    let mut headers = plex_headers();
    headers.push(("X-Plex-Container-Start".to_string(), start.to_string()));
    headers.push(("X-Plex-Container-Size".to_string(), PAGE_SIZE.to_string()));
    let c: Container<Metadatas> = send_json(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &path), headers, None),
    )?;
    Ok(Page {
        items: c.media_container.metadata,
    })
}

/// One item's current state as the link's own profile sees it. `None` once the
/// server no longer has it.
pub fn metadata(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    rating_key: &str,
) -> Result<Option<Metadata>, PlexError> {
    let path = format!("/library/metadata/{rating_key}?includeGuids=1");
    match send_json::<Container<Metadatas>>(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &path), plex_headers(), None),
    ) {
        Ok(c) => Ok(c.media_container.metadata.into_iter().next()),
        Err(PlexError::NotFound) => Ok(None),
        Err(e) => Err(e),
    }
}

pub fn all_leaves(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    show_rating_key: &str,
) -> Result<Vec<Metadata>, PlexError> {
    let path = format!("/library/metadata/{show_rating_key}/allLeaves?includeGuids=1");
    let c: Container<Metadatas> = send_json(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &path), plex_headers(), None),
    )?;
    Ok(c.media_container.metadata)
}

fn library_call(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    verb: &str,
    extra: &[(&str, String)],
) -> Result<(), PlexError> {
    let mut pairs = vec![("identifier", LIBRARY_IDENTIFIER.to_string())];
    pairs.extend(extra.iter().cloned());
    let path = format!("/:/{verb}?{}", query(&pairs));
    send(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &path), plex_headers(), None),
    )
    .map(|_| ())
}

pub fn scrobble(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    rating_key: &str,
) -> Result<(), PlexError> {
    library_call(
        host,
        base,
        link_id,
        "scrobble",
        &[("key", rating_key.to_string())],
    )
}

pub fn unscrobble(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    rating_key: &str,
) -> Result<(), PlexError> {
    library_call(
        host,
        base,
        link_id,
        "unscrobble",
        &[("key", rating_key.to_string())],
    )
}

/// `/:/progress` takes milliseconds.
pub fn progress(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    rating_key: &str,
    position_seconds: u32,
) -> Result<(), PlexError> {
    library_call(
        host,
        base,
        link_id,
        "progress",
        &[
            ("key", rating_key.to_string()),
            ("time", (u64::from(position_seconds) * 1000).to_string()),
            ("state", "stopped".to_string()),
        ],
    )
}

pub fn refresh(
    host: &mut dyn Host,
    base: &str,
    link_id: &str,
    path: Option<&str>,
) -> Result<(), PlexError> {
    let target = match path {
        Some(p) => format!(
            "/library/sections/all/refresh?{}",
            query(&[("path", p.to_string())])
        ),
        None => "/library/sections/all/refresh".to_string(),
    };
    send(
        host,
        &Auth::Link(link_id),
        request("GET", &url(base, &target), plex_headers(), None),
    )
    .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    const BASE: &str = "http://192.168.1.20:32400";

    #[test]
    fn section_episodes_is_type_4_with_since_and_paging_headers() {
        let mut host = FakeHost::new();
        let u = "http://pms:32400/library/sections/2/all?type=4&includeGuids=1&lastViewedAt%3E=1767000000";
        host.respond("GET", u, 200, r#"{"MediaContainer":{"Metadata":[{"ratingKey":501,"type":"episode","parentIndex":1,"index":2,"viewCount":1}]}}"#);
        let page = section_episodes(
            &mut host,
            "http://pms:32400",
            "l1",
            "2",
            200,
            Some(1_767_000_000),
        )
        .unwrap();
        assert_eq!(page.items[0].rating_key, "501");
        let sent = host.requests_to(u)[0];
        assert_eq!(sent.link.as_deref(), Some("l1"));
        assert_eq!(sent.header("X-Plex-Container-Start"), Some("200"));
    }

    #[test]
    fn metadata_of_a_deleted_item_is_none() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            "http://pms:32400/library/metadata/9?includeGuids=1",
            404,
            "",
        );
        assert!(metadata(&mut host, "http://pms:32400", "l1", "9")
            .unwrap()
            .is_none());
    }

    #[test]
    fn sections_parse_the_directory_list() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/library/sections"),
            200,
            r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Films"},{"key":"2","type":"show","title":"Series"}]}}"#,
        );
        let s = sections(&mut host, BASE, "srv").unwrap();
        assert_eq!(s.len(), 2);
        assert_eq!((s[1].key.as_str(), s[1].kind.as_str()), ("2", "show"));
        assert_eq!(host.sent[0].link.as_deref(), Some("srv"));
    }

    #[test]
    fn section_items_pages_with_container_headers_and_since() {
        let mut host = FakeHost::new();
        let url =
            format!("{BASE}/library/sections/1/all?includeGuids=1&lastViewedAt%3E=1700000000");
        host.respond(
            "GET",
            &url,
            200,
            r#"{"MediaContainer":{"totalSize":1,"Metadata":[{"ratingKey":"77","type":"movie","title":"The Glass Orchard","viewCount":2,"viewOffset":5000,"lastViewedAt":1700000100,"Guid":[{"id":"tmdb://9001"}]}]}}"#,
        );
        let page = section_items(&mut host, BASE, "srv", "1", 400, Some(1_700_000_000)).unwrap();
        let item = &page.items[0];
        assert_eq!(
            (item.rating_key.as_str(), item.view_count, item.view_offset),
            ("77", 2, Some(5000))
        );
        assert_eq!(item.guids[0].id, "tmdb://9001");
        assert_eq!(host.sent[0].header("X-Plex-Container-Start"), Some("400"));
        assert_eq!(host.sent[0].header("X-Plex-Container-Size"), Some("200"));
    }

    #[test]
    fn numeric_rating_keys_are_accepted() {
        let mut host = FakeHost::new();
        let url = format!("{BASE}/library/sections/1/all?includeGuids=1");
        host.respond(
            "GET",
            &url,
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":77,"type":"movie","title":"X"}]}}"#,
        );
        let page = section_items(&mut host, BASE, "srv", "1", 0, None).unwrap();
        assert_eq!(page.items[0].rating_key, "77");
        assert_eq!(page.items[0].view_count, 0);
    }

    #[test]
    fn an_empty_section_has_no_metadata_key() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/library/sections/3/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"size":0}}"#,
        );
        assert!(section_items(&mut host, BASE, "srv", "3", 0, None)
            .unwrap()
            .items
            .is_empty());
    }

    #[test]
    fn all_leaves_reads_season_and_episode_numbers() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/library/metadata/10/allLeaves?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"11","type":"episode","title":"Harbor Lights","parentIndex":1,"index":2,"grandparentRatingKey":"10"}]}}"#,
        );
        let eps = all_leaves(&mut host, BASE, "srv", "10").unwrap();
        assert_eq!((eps[0].parent_index, eps[0].index), (Some(1), Some(2)));
    }

    #[test]
    fn scrobble_unscrobble_and_progress_use_the_library_identifier() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/:/scrobble?identifier=com.plexapp.plugins.library&key=77"),
            200,
            "",
        )
        .respond(
            "GET",
            &format!("{BASE}/:/unscrobble?identifier=com.plexapp.plugins.library&key=77"),
            200,
            "",
        )
        .respond(
            "GET",
            &format!(
                "{BASE}/:/progress?identifier=com.plexapp.plugins.library&key=77&time=90000&state=stopped"
            ),
            200,
            "",
        );
        scrobble(&mut host, BASE, "u1", "77").unwrap();
        unscrobble(&mut host, BASE, "u1", "77").unwrap();
        progress(&mut host, BASE, "u1", "77", 90).unwrap();
        assert!(host.sent.iter().all(|s| s.link.as_deref() == Some("u1")));
    }

    #[test]
    fn refresh_passes_the_path_or_scans_everything() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/library/sections/all/refresh?path=%2Fmedia%2Fmovies"),
            200,
            "",
        )
        .respond(
            "GET",
            &format!("{BASE}/library/sections/all/refresh"),
            200,
            "",
        );
        refresh(&mut host, BASE, "srv", Some("/media/movies")).unwrap();
        refresh(&mut host, BASE, "srv", None).unwrap();
        assert_eq!(host.sent.len(), 2);
    }

    #[test]
    fn a_trailing_slash_on_the_base_is_tolerated() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{BASE}/library/sections"),
            200,
            r#"{"MediaContainer":{}}"#,
        );
        assert!(sections(&mut host, &format!("{BASE}/"), "srv")
            .unwrap()
            .is_empty());
    }
}
