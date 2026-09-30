//! The mapping crawl: every movie and episode on the server, keyed by rating
//! key, with reverse indexes from external ids. The crawl is the expensive call,
//! so it is resumable (crawl/state) and repeats every 24 hours, the interval
//! native watched sync used, so media added later and fixes to id matching are
//! picked up. Stale map/ entries for deleted items stay: nothing on the server
//! lists their rating key again, so they are never reached.

use crate::api::{self, Metadata};
use crate::guid::{self, ExternalIds};
use crate::host::Host;
use crate::http::PlexError;
use crate::store;
use mydia_plugin_sdk::types::{KvEntry, PlaybackProgress};
use serde::{Deserialize, Serialize};

pub const MAPPING_REFRESH_INTERVAL_SECONDS: i64 = 24 * 60 * 60;

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct MapEntry {
    pub kind: String, // "movie" | "episode"
    pub imdb: Option<String>,
    pub tmdb: Option<i64>,
    pub tvdb: Option<i64>,
    pub season: Option<u32>,
    pub episode: Option<u32>,
    pub show_tmdb: Option<i64>,
    pub show_tvdb: Option<i64>,
    #[serde(default)]
    pub show_imdb: Option<String>,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct CrawlState {
    pub section_keys: Vec<String>, // "<kind>:<key>", e.g. "movie:1", "show:2"
    pub section_index: usize,
    pub offset: u32,
    pub started_at: i64,
    pub completed_at: Option<i64>,
    #[serde(default)]
    pub last_completed_at: Option<i64>,
}

#[derive(Debug, PartialEq, Eq)]
pub enum CrawlProgress {
    /// A crawl pass finished in this call.
    Complete,
    /// The budget ran out; the next call resumes from crawl/state.
    Partial,
    /// Nothing to do: the last full crawl is younger than the interval.
    Fresh,
}

#[derive(Debug, PartialEq, Eq)]
enum Plan {
    Start,
    Continue,
    Fresh,
}

fn plan(state: Option<&CrawlState>, now: i64) -> Plan {
    match state {
        None => Plan::Start,
        Some(s) => match s.completed_at {
            None => Plan::Continue,
            Some(done) if now - done >= MAPPING_REFRESH_INTERVAL_SECONDS => Plan::Start,
            Some(_) => Plan::Fresh,
        },
    }
}

pub fn movie_entries(item: &Metadata) -> Vec<KvEntry> {
    let ids = guid::parse_guids(&item.guids);
    let entry = MapEntry {
        kind: "movie".into(),
        imdb: ids.imdb.clone(),
        tmdb: ids.tmdb,
        tvdb: ids.tvdb,
        season: None,
        episode: None,
        show_tmdb: None,
        show_tvdb: None,
        show_imdb: None,
    };
    let mut out = vec![map_entry(&item.rating_key, &entry)];
    for (source, id) in id_pairs(&ids) {
        out.push(rev_entry(
            store::rev_movie_key(source, &id),
            &item.rating_key,
        ));
    }
    out
}

pub fn episode_entries(show: &ExternalIds, ep: &Metadata) -> Vec<KvEntry> {
    let (season, episode) = match (ep.parent_index, ep.index) {
        (Some(s), Some(e)) => (s, e),
        _ => return Vec::new(),
    };
    let own = guid::parse_guids(&ep.guids);
    let entry = MapEntry {
        kind: "episode".into(),
        imdb: own.imdb,
        tmdb: own.tmdb,
        tvdb: own.tvdb,
        season: Some(season),
        episode: Some(episode),
        show_tmdb: show.tmdb,
        show_tvdb: show.tvdb,
        show_imdb: show.imdb.clone(),
    };
    let mut out = vec![map_entry(&ep.rating_key, &entry)];
    // Episodes resolve by the show's ids plus coordinates, exactly as the native
    // crawl mapped them: Plex puts every id on the show, and a local show often
    // carries only one of them.
    for (source, id) in id_pairs(show) {
        out.push(rev_entry(
            store::rev_episode_key(source, &id, season, episode),
            &ep.rating_key,
        ));
    }
    out
}

/// Candidate rev keys for a local progress row, in lookup order. An episode row
/// carries its show's ids (HostFunctions.to_playback_progress/1).
pub fn rev_keys_for_progress(p: &PlaybackProgress) -> Vec<String> {
    let mut sources: Vec<(&str, String)> = Vec::new();
    if let Some(t) = p.tmdb_id {
        sources.push(("tmdb", t.to_string()));
    }
    if let Some(t) = p.tvdb_id {
        sources.push(("tvdb", t.to_string()));
    }
    if let Some(i) = &p.imdb_id {
        sources.push(("imdb", i.clone()));
    }
    match (p.item_type.as_str(), p.season_number, p.episode_number) {
        ("episode", Some(s), Some(e)) => sources
            .into_iter()
            .map(|(src, id)| store::rev_episode_key(src, &id, s, e))
            .collect(),
        ("movie", _, _) => sources
            .into_iter()
            .map(|(src, id)| store::rev_movie_key(src, &id))
            .collect(),
        _ => Vec::new(),
    }
}

fn id_pairs(ids: &ExternalIds) -> Vec<(&'static str, String)> {
    let mut out = Vec::new();
    if let Some(i) = &ids.imdb {
        out.push(("imdb", i.clone()));
    }
    if let Some(t) = ids.tmdb {
        out.push(("tmdb", t.to_string()));
    }
    if let Some(t) = ids.tvdb {
        out.push(("tvdb", t.to_string()));
    }
    out
}

fn map_entry(rating_key: &str, entry: &MapEntry) -> KvEntry {
    KvEntry {
        key: store::map_key(rating_key),
        value: serde_json::to_string(entry).expect("MapEntry serializes"),
    }
}

fn rev_entry(key: String, rating_key: &str) -> KvEntry {
    KvEntry {
        key,
        value: serde_json::to_string(rating_key).expect("string serializes"),
    }
}

pub fn crawl_step(
    host: &mut dyn Host,
    base: &str,
    link: &str,
    deadline_ms: u64,
) -> Result<CrawlProgress, PlexError> {
    let now = host.now();
    let existing: Option<CrawlState> = store::get_json(host, store::CRAWL_STATE)?;
    let mut state = match plan(existing.as_ref(), now) {
        Plan::Fresh => return Ok(CrawlProgress::Fresh),
        Plan::Continue => existing.expect("continue implies state"),
        Plan::Start => {
            let section_keys = api::sections(host, base, link)?
                .into_iter()
                .filter(|s| s.kind == "movie" || s.kind == "show")
                .map(|s| format!("{}:{}", s.kind, s.key))
                .collect();
            let state = CrawlState {
                section_keys,
                section_index: 0,
                offset: 0,
                started_at: now,
                completed_at: None,
                last_completed_at: existing.and_then(|s| s.last_completed_at),
            };
            store::put_json(host, store::CRAWL_STATE, &state)?;
            state
        }
    };

    while state.section_index < state.section_keys.len() {
        if host.elapsed_ms() >= deadline_ms {
            store::put_json(host, store::CRAWL_STATE, &state)?;
            return Ok(CrawlProgress::Partial);
        }
        let (kind, key) = match state.section_keys[state.section_index].split_once(':') {
            Some((k, v)) => (k.to_string(), v.to_string()),
            None => (String::new(), String::new()),
        };
        let page = api::section_items(host, base, link, &key, state.offset, None)?;
        let full_page = page.items.len() as u32 == api::PAGE_SIZE;

        if kind == "show" {
            // One allLeaves per show, so the budget is checked per show and the
            // offset advances per show: a big page never overruns the tick.
            for show in &page.items {
                if host.elapsed_ms() >= deadline_ms {
                    store::put_json(host, store::CRAWL_STATE, &state)?;
                    return Ok(CrawlProgress::Partial);
                }
                let show_ids = guid::parse_guids(&show.guids);
                let mut entries = Vec::new();
                match api::all_leaves(host, base, link, &show.rating_key) {
                    Ok(episodes) => {
                        for ep in &episodes {
                            entries.extend(episode_entries(&show_ids, ep));
                        }
                    }
                    Err(PlexError::Unauthorized) => return Err(PlexError::Unauthorized),
                    // One broken show must not stall the crawl (native parity).
                    Err(e) => host.log(
                        "warn",
                        &format!(
                            "plex: allLeaves failed for show {}: {}",
                            show.rating_key,
                            e.message()
                        ),
                    ),
                }
                state.offset += 1;
                entries.push(state_entry(&state));
                host.kv_set_many(&entries).map_err(host_err)?;
            }
        } else {
            let mut entries: Vec<KvEntry> = page.items.iter().flat_map(movie_entries).collect();
            state.offset += page.items.len() as u32;
            entries.push(state_entry(&state));
            host.kv_set_many(&entries).map_err(host_err)?;
        }

        if !full_page {
            state.section_index += 1;
            state.offset = 0;
            store::put_json(host, store::CRAWL_STATE, &state)?;
        }
    }

    let now = host.now();
    state.completed_at = Some(now);
    state.last_completed_at = Some(now);
    store::put_json(host, store::CRAWL_STATE, &state)?;
    Ok(CrawlProgress::Complete)
}

/// True once any crawl pass has ever finished, including while a later re-crawl
/// is still running. Sync can resolve nothing before this is true.
pub fn crawled_once(host: &mut dyn Host) -> Result<bool, PlexError> {
    Ok(store::get_json::<CrawlState>(host, store::CRAWL_STATE)?
        .and_then(|s| s.last_completed_at)
        .is_some())
}

pub fn get_entry(host: &mut dyn Host, rating_key: &str) -> Result<Option<MapEntry>, PlexError> {
    store::get_json(host, &store::map_key(rating_key))
}

/// The rating key for a local progress row, or `None` when the crawl has not
/// seen the item under any id the local row carries.
pub fn lookup_rating_key(
    host: &mut dyn Host,
    p: &PlaybackProgress,
) -> Result<Option<String>, PlexError> {
    for key in rev_keys_for_progress(p) {
        if let Some(rk) = store::get_json::<String>(host, &key)? {
            return Ok(Some(rk));
        }
    }
    Ok(None)
}

fn state_entry(state: &CrawlState) -> KvEntry {
    KvEntry {
        key: store::CRAWL_STATE.into(),
        value: serde_json::to_string(state).expect("CrawlState serializes"),
    }
}

fn host_err(e: mydia_plugin_sdk::types::HostError) -> PlexError {
    PlexError::Unexpected(format!("store: {e:?}"))
}

/// A local progress row for tests in this crate.
#[cfg(test)]
pub(crate) fn progress_row(kind: &str) -> PlaybackProgress {
    PlaybackProgress {
        user_id: "u1".into(),
        item_type: kind.into(),
        media_item_id: None,
        episode_id: None,
        tmdb_id: None,
        tvdb_id: None,
        imdb_id: None,
        season_number: None,
        episode_number: None,
        watched: false,
        position_seconds: None,
        duration_seconds: None,
        last_watched_at: None,
        updated_at: "2026-01-01T00:00:00.000000Z".into(),
        origin: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Guid;
    use crate::host::fake::FakeHost;

    const NOW: i64 = 1_767_225_600;
    const B: &str = "http://plex.test";

    fn meta(
        rk: &str,
        kind: &str,
        guids: &[&str],
        season: Option<u32>,
        ep: Option<u32>,
    ) -> Metadata {
        Metadata {
            rating_key: rk.into(),
            kind: kind.into(),
            title: String::new(),
            view_count: 0,
            view_offset: None,
            last_viewed_at: None,
            parent_index: season,
            index: ep,
            grandparent_rating_key: None,
            guids: guids.iter().map(|g| Guid { id: g.to_string() }).collect(),
        }
    }

    fn keys(entries: &[KvEntry]) -> Vec<String> {
        entries.iter().map(|e| e.key.clone()).collect()
    }

    #[test]
    fn a_movie_maps_and_indexes_every_id_it_has() {
        let e = movie_entries(&meta(
            "100",
            "movie",
            &["imdb://tt9000001", "tmdb://4001"],
            None,
            None,
        ));
        assert_eq!(
            keys(&e),
            vec!["map/100", "rev/movie/imdb/tt9000001", "rev/movie/tmdb/4001"]
        );
        let entry: MapEntry = serde_json::from_str(&e[0].value).unwrap();
        assert_eq!((entry.kind.as_str(), entry.tmdb), ("movie", Some(4001)));
        assert_eq!(e[1].value, "\"100\"");
    }

    #[test]
    fn an_episode_indexes_by_show_ids_and_coordinates() {
        let show = guid::parse_guids(&[
            Guid {
                id: "imdb://tt9000002".into(),
            },
            Guid {
                id: "tmdb://5001".into(),
            },
            Guid {
                id: "tvdb://378000".into(),
            },
        ]);
        let e = episode_entries(&show, &meta("201", "episode", &[], Some(1), Some(2)));
        assert_eq!(
            keys(&e),
            vec![
                "map/201",
                "rev/episode/imdb/tt9000002/1/2",
                "rev/episode/tmdb/5001/1/2",
                "rev/episode/tvdb/378000/1/2",
            ]
        );
        let entry: MapEntry = serde_json::from_str(&e[0].value).unwrap();
        assert_eq!(
            (entry.season, entry.episode, entry.show_tvdb),
            (Some(1), Some(2), Some(378_000))
        );
        assert_eq!(entry.show_imdb.as_deref(), Some("tt9000002"));
    }

    #[test]
    fn an_episode_without_coordinates_is_skipped() {
        let show = ExternalIds {
            imdb: None,
            tmdb: None,
            tvdb: Some(1),
        };
        assert!(episode_entries(&show, &meta("202", "episode", &[], None, Some(2))).is_empty());
    }

    #[test]
    fn progress_rev_keys_try_every_local_id() {
        let mut p = progress_row("episode");
        p.tvdb_id = Some(378_000);
        p.season_number = Some(1);
        p.episode_number = Some(2);
        assert_eq!(
            rev_keys_for_progress(&p),
            vec!["rev/episode/tvdb/378000/1/2"]
        );

        let mut m = progress_row("movie");
        m.tmdb_id = Some(4001);
        m.imdb_id = Some("tt9000001".into());
        assert_eq!(
            rev_keys_for_progress(&m),
            vec!["rev/movie/tmdb/4001", "rev/movie/imdb/tt9000001"]
        );
    }

    #[test]
    fn plan_starts_continues_and_respects_the_interval() {
        let now = 1_767_225_600;
        assert_eq!(plan(None, now), Plan::Start);
        assert_eq!(plan(Some(&CrawlState::default()), now), Plan::Continue);
        let fresh = CrawlState {
            completed_at: Some(now - 3600),
            ..Default::default()
        };
        assert_eq!(plan(Some(&fresh), now), Plan::Fresh);
        let stale = CrawlState {
            completed_at: Some(now - MAPPING_REFRESH_INTERVAL_SECONDS),
            ..Default::default()
        };
        assert_eq!(plan(Some(&stale), now), Plan::Start);
    }

    fn script_small_library(host: &mut FakeHost) {
        host.respond("GET", &format!("{B}/library/sections"), 200, r#"{"MediaContainer":{"Directory":[
                {"key":"1","type":"movie","title":"Films"},
                {"key":"2","type":"show","title":"Series"},
                {"key":"3","type":"artist","title":"Music"}]}}"#)
            .respond("GET", &format!("{B}/library/sections/1/all?includeGuids=1"), 200,
                r#"{"MediaContainer":{"Metadata":[
                {"ratingKey":"100","type":"movie","Guid":[{"id":"tmdb://4001"},{"id":"imdb://tt9000001"}]}]}}"#)
            .respond("GET", &format!("{B}/library/sections/2/all?includeGuids=1"), 200,
                r#"{"MediaContainer":{"Metadata":[
                {"ratingKey":"20","type":"show","Guid":[{"id":"tvdb://378000"}]}]}}"#)
            .respond("GET", &format!("{B}/library/metadata/20/allLeaves?includeGuids=1"), 200,
                r#"{"MediaContainer":{"Metadata":[
                {"ratingKey":"201","type":"episode","parentIndex":1,"index":1},
                {"ratingKey":"202","type":"episode","parentIndex":1,"index":2}]}}"#);
    }

    #[test]
    fn a_first_crawl_maps_movies_and_episodes_and_completes() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        script_small_library(&mut host);

        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000).unwrap(),
            CrawlProgress::Complete
        );

        assert!(host.kv.contains_key("map/100"));
        assert_eq!(
            host.kv.get("rev/movie/tmdb/4001").map(String::as_str),
            Some("\"100\"")
        );
        assert_eq!(
            host.kv
                .get("rev/episode/tvdb/378000/1/2")
                .map(String::as_str),
            Some("\"202\"")
        );
        let state: CrawlState = serde_json::from_str(&host.kv["crawl/state"]).unwrap();
        assert_eq!(state.completed_at, Some(NOW));
        assert_eq!(state.last_completed_at, Some(NOW));
        assert_eq!(state.section_keys, vec!["movie:1", "show:2"]);
        assert!(crawled_once(&mut host).unwrap());
        assert!(host.sent.iter().all(|s| s.link.as_deref() == Some("owner")));
    }

    #[test]
    fn a_fresh_crawl_makes_no_requests() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        let state = CrawlState {
            completed_at: Some(NOW - 60),
            last_completed_at: Some(NOW - 60),
            ..Default::default()
        };
        host.kv
            .insert("crawl/state".into(), serde_json::to_string(&state).unwrap());

        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000).unwrap(),
            CrawlProgress::Fresh
        );
        assert!(host.sent.is_empty());
    }

    #[test]
    fn a_stale_crawl_restarts_but_keeps_last_completed_at_until_done() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        host.elapsed = 45_000; // budget already spent
        let old = NOW - MAPPING_REFRESH_INTERVAL_SECONDS - 1;
        let state = CrawlState {
            completed_at: Some(old),
            last_completed_at: Some(old),
            ..Default::default()
        };
        host.kv
            .insert("crawl/state".into(), serde_json::to_string(&state).unwrap());
        script_small_library(&mut host);

        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000).unwrap(),
            CrawlProgress::Partial
        );
        let saved: CrawlState = serde_json::from_str(&host.kv["crawl/state"]).unwrap();
        assert_eq!(saved.completed_at, None);
        assert_eq!(saved.last_completed_at, Some(old));
        assert!(crawled_once(&mut host).unwrap());
    }

    #[test]
    fn a_show_page_costs_one_all_leaves_per_show() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        let state = CrawlState {
            section_keys: vec!["show:2".into()],
            section_index: 0,
            offset: 0,
            started_at: NOW,
            completed_at: None,
            last_completed_at: None,
        };
        host.kv
            .insert("crawl/state".into(), serde_json::to_string(&state).unwrap());
        host.respond("GET", &format!("{B}/library/sections/2/all?includeGuids=1"), 200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"20","type":"show"},{"ratingKey":"21","type":"show"}]}}"#);
        host.respond(
            "GET",
            &format!("{B}/library/metadata/20/allLeaves?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[]}}"#,
        );
        host.respond(
            "GET",
            &format!("{B}/library/metadata/21/allLeaves?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[]}}"#,
        );

        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000).unwrap(),
            CrawlProgress::Complete
        );
        assert_eq!(host.sent.len(), 3, "one page and one allLeaves per show");
        let saved: CrawlState = serde_json::from_str(&host.kv["crawl/state"]).unwrap();
        assert_eq!(saved.last_completed_at, Some(NOW));
    }

    #[test]
    fn an_owner_401_surfaces_as_unauthorized() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        host.respond("GET", &format!("{B}/library/sections"), 401, "");
        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000),
            Err(PlexError::Unauthorized)
        );
    }

    #[test]
    fn a_saved_show_offset_resumes_from_the_next_show() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        let state = CrawlState {
            section_keys: vec!["show:2".into()],
            section_index: 0,
            offset: 1,
            started_at: NOW,
            completed_at: None,
            last_completed_at: None,
        };
        host.kv
            .insert("crawl/state".into(), serde_json::to_string(&state).unwrap());
        host.respond(
            "GET",
            &format!("{B}/library/sections/2/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"21","type":"show"}]}}"#,
        );
        host.respond(
            "GET",
            &format!("{B}/library/metadata/21/allLeaves?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[]}}"#,
        );

        assert_eq!(
            crawl_step(&mut host, B, "owner", 45_000).unwrap(),
            CrawlProgress::Complete
        );
        let page = host.requests_to(&format!("{B}/library/sections/2/all?includeGuids=1"))[0];
        assert_eq!(page.header("X-Plex-Container-Start"), Some("1"));
    }
}
