//! Bidirectional watched sync for one instance, ported from
//! `Mydia.WatchSync.Engine`. Every merge decision comes from `reconcile`, which
//! is pure; this module owns the I/O.
//!
//! One tick, per active user link:
//!   1. Pull pass. Items Plex reports as viewed since the link's pull cursor
//!      (minus a 15 minute overlap), resumable page by page through
//!      link/<id>/cursor/pull_page.
//!   2. Push pass. Local rows for that user updated since link/<id>/cursor/push
//!      that this instance did not write. Remote state is the snapshot when one
//!      exists, because the pull pass already covered every remote change;
//!      otherwise it is read from /library/metadata.
//!   3. Unwatch pass. Snapshots that say "watched" for an item the user has no
//!      local row for. Unwatching deletes the row locally, so its absence is the
//!      only signal, exactly as in the Elixir engine.

use crate::api::{self, Metadata};
use crate::host::Host;
use crate::http::{Direction, PlexError, PluginConfig};
use crate::mapping;
use crate::reconcile::{self, Change, Decision, Side};
use crate::store;
use crate::time;
use mydia_plugin_sdk::types::{
    AccountLink, EnsureWatchedStatus, HostError, KvEntry, LinkRole, LinkStatus, ListItem,
    ListRequest, PlaybackProgress, WatchStateTarget,
};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};

/// Rewind applied to the pull cursor. A view that lands during a pass carries a
/// lastViewedAt earlier than the cursor recorded at its end; rewinding by more
/// than a pass's duration turns that permanent loss into a little redundant
/// work that reconciles to Noop.
pub const CURSOR_OVERLAP_SECONDS: i64 = 900;
const FLUSH_EVERY: usize = 25;

pub const ABSENT: Side = Side {
    watched: false,
    position: None,
    at: None,
};

/// The origin tag the host stamps on this instance's watch-state writes.
pub fn origin(cfg: &PluginConfig) -> String {
    format!(
        "plugin:plex:{}",
        cfg.instance_id.as_deref().unwrap_or_default()
    )
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Counts {
    pub pulled: u32,
    pub pushed: u32,
    pub skipped: u32,
    pub errors: u32,
    pub unchanged: u32,
    pub not_found: u32,
}

impl Counts {
    pub fn add(&mut self, o: Counts) {
        self.pulled += o.pulled;
        self.pushed += o.pushed;
        self.skipped += o.skipped;
        self.errors += o.errors;
        self.unchanged += o.unchanged;
        self.not_found += o.not_found;
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum SyncError {
    Unauthorized,
    Failed(String),
}

impl From<PlexError> for SyncError {
    fn from(e: PlexError) -> Self {
        match e {
            PlexError::Unauthorized => SyncError::Unauthorized,
            other => SyncError::Failed(other.message()),
        }
    }
}

impl From<HostError> for SyncError {
    fn from(e: HostError) -> Self {
        SyncError::Failed(format!("host: {e:?}"))
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Snapshot {
    pub watched: bool,
    pub position: Option<i64>,
    pub synced_at: String,
    pub remote_last_watched_at: Option<String>,
}

impl Snapshot {
    /// `at` is the remote's last-watched time, as in Engine.snapshot_side/1.
    pub fn side(&self) -> Side {
        Side {
            watched: self.watched,
            position: self.position,
            at: self
                .remote_last_watched_at
                .as_deref()
                .and_then(time::parse_rfc3339),
        }
    }
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct PullPage {
    pub since: Option<i64>,
    pub started_at: i64,
    pub section_index: usize,
    /// The section the index pointed at when saved. A resume looks it up by
    /// key, so sections added or removed between ticks cannot shift it.
    #[serde(default)]
    pub section_key: Option<String>,
    pub offset: u32,
}

pub fn remote_side(item: &Metadata) -> Side {
    Side {
        watched: item.view_count > 0,
        // Plex speaks milliseconds; a zero offset means "not started".
        position: item
            .view_offset
            .filter(|ms| *ms > 0)
            .map(|ms| (ms / 1000) as i64),
        at: item.last_viewed_at,
    }
}

pub fn local_side(p: &PlaybackProgress) -> Side {
    Side {
        watched: p.watched,
        position: p.position_seconds.map(i64::from),
        at: p.last_watched_at.as_deref().and_then(time::parse_rfc3339),
    }
}

/// Client-side guard matching the native provider's changed_since?/2: an
/// in-progress item may have a viewOffset but no lastViewedAt stamp yet.
pub fn changed_since(item: &Metadata, since: Option<i64>) -> bool {
    match (since, item.last_viewed_at) {
        (None, _) => true,
        (Some(_), None) => item.view_offset.unwrap_or(0) > 0 || item.view_count > 0,
        (Some(s), Some(at)) => at >= s,
    }
}

#[derive(Debug, PartialEq, Eq)]
pub enum Action {
    Pull(Change),
    Push(Change),
    Record(Change),
    /// The reconciler wanted to move data against the operator's direction
    /// setting. The snapshot is still recorded so it stays truthful.
    SkippedByDirection(Change),
    Noop,
}

pub fn decide(local: &Side, remote: &Side, snapshot: Option<&Side>, dir: Direction) -> Action {
    match reconcile::resolve(local, remote, snapshot) {
        Decision::Noop => Action::Noop,
        Decision::Pull(c) if dir == Direction::Export => Action::SkippedByDirection(c),
        Decision::Push(c) if dir == Direction::Import => Action::SkippedByDirection(c),
        Decision::Pull(c) => Action::Pull(c),
        Decision::Push(c) => Action::Push(c),
        Decision::RecordOnly(c) => Action::Record(c),
    }
}

pub struct LocalRow {
    pub side: Side,
    pub updated_at: String,
    pub origin: Option<String>,
}

#[derive(Default)]
pub struct LocalIndex {
    rows: HashMap<(String, String), LocalRow>,
    pub unresolved: u32,
}

impl LocalIndex {
    pub fn build(progress: Vec<PlaybackProgress>, rev: &HashMap<String, String>) -> LocalIndex {
        let mut idx = LocalIndex::default();
        for p in progress {
            match mapping::rev_keys_for_progress(&p)
                .iter()
                .find_map(|k| rev.get(k))
                .cloned()
            {
                Some(rk) => {
                    idx.rows.insert(
                        (p.user_id.clone(), rk),
                        LocalRow {
                            side: local_side(&p),
                            updated_at: p.updated_at.clone(),
                            origin: p.origin.clone(),
                        },
                    );
                }
                None => idx.unresolved += 1,
            }
        }
        idx
    }

    pub fn get(&self, user_id: &str, rating_key: &str) -> Option<&LocalRow> {
        self.rows
            .get(&(user_id.to_string(), rating_key.to_string()))
    }

    pub fn for_user<'a>(
        &'a self,
        user_id: &'a str,
    ) -> impl Iterator<Item = (&'a String, &'a LocalRow)> + 'a {
        self.rows
            .iter()
            .filter(move |((u, _), _)| u == user_id)
            .map(|((_, rk), row)| (rk, row))
    }
}

#[derive(Debug, Default)]
pub struct TickOutcome {
    pub counts: Counts,
    pub complete: bool,
    pub unauthorized_links: Vec<String>,
}

enum LinkOutcome {
    Complete(Counts),
    Partial(Counts),
}

/// One scheduled tick. `server_link` (endpoint link, else owner) runs the crawl;
/// each user link reads and writes Plex with its own token, or through
/// `owner_link` when link/<id>/uses_owner is set. `Err(Unauthorized)` means the
/// instance credential itself was refused.
pub fn run_tick(
    h: &mut dyn Host,
    base: &str,
    server_link: &str,
    owner_link: &str,
    cfg: &PluginConfig,
    deadline_ms: u64,
) -> Result<TickOutcome, SyncError> {
    let mut out = TickOutcome::default();
    let had_map = mapping::crawled_once(h)?;
    // A re-crawl gets at most two thirds of the budget so sync still runs; the
    // first crawl gets all of it, since sync resolves nothing without it.
    let crawl_deadline = if had_map {
        deadline_ms.min(h.elapsed_ms() + 30_000)
    } else {
        deadline_ms
    };
    mapping::crawl_step(h, base, server_link, crawl_deadline)?;
    if !mapping::crawled_once(h)? {
        return Ok(out);
    }

    let rev = load_rev(h)?;
    let canonical: HashSet<String> = rev.values().cloned().collect();
    let local = LocalIndex::build(load_progress(h)?, &rev);
    if local.unresolved > 0 {
        h.log(
            "debug",
            &format!(
                "plex: {} local progress rows match nothing on this server",
                local.unresolved
            ),
        );
    }

    out.complete = true;
    let links: Vec<AccountLink> = h
        .links_list()?
        .into_iter()
        .filter(|l| {
            l.role == LinkRole::User && l.status == LinkStatus::Active && l.user_id.is_some()
        })
        .collect();

    for link in links {
        if h.elapsed_ms() >= deadline_ms {
            out.complete = false;
            break;
        }
        // One link's failure to resolve its request link must not stop the rest.
        let req_link = match request_link(h, &link, owner_link) {
            Ok(l) => l,
            Err(e) => {
                h.log(
                    "warn",
                    &format!("plex: cannot resolve request link for {}: {e:?}", link.id),
                );
                out.counts.errors += 1;
                continue;
            }
        };
        let ctx = LinkCtx {
            base,
            req_link,
            link_id: link.id.clone(),
            user_id: link.user_id.clone().unwrap_or_default(),
            direction: cfg.direction(),
            origin: origin(cfg),
            unwatch_pass: !rev.is_empty(),
            canonical: canonical.clone(),
        };
        match sync_link(h, &ctx, &local, deadline_ms) {
            Ok(LinkOutcome::Complete(c)) => out.counts.add(c),
            Ok(LinkOutcome::Partial(c)) => {
                out.counts.add(c);
                out.complete = false;
                break;
            }
            // A 401 on one profile invalidates just that link; others still sync.
            Err(SyncError::Unauthorized) => {
                h.set_link_status(
                    &link.id,
                    LinkStatus::Error,
                    Some("Plex rejected this profile's token (401)"),
                )?;
                out.unauthorized_links.push(link.id.clone());
            }
            Err(SyncError::Failed(msg)) => {
                h.log(
                    "warn",
                    &format!("plex: sync failed for link {}: {msg}", link.id),
                );
                out.counts.errors += 1;
            }
        }
    }
    Ok(out)
}

/// Pushes the one item a `playback.finished` event names, outside the tick.
pub fn push_one(
    h: &mut dyn Host,
    base: &str,
    owner_link: &str,
    link: &AccountLink,
    cfg: &PluginConfig,
    row: &PlaybackProgress,
    rating_key: &str,
) -> Result<Counts, SyncError> {
    let ctx = LinkCtx {
        base,
        req_link: request_link(h, link, owner_link)?,
        link_id: link.id.clone(),
        user_id: row.user_id.clone(),
        direction: cfg.direction(),
        origin: origin(cfg),
        unwatch_pass: false,
        canonical: HashSet::new(),
    };
    let remote = match api::metadata(h, base, &ctx.req_link, rating_key)? {
        Some(item) => remote_side(&item),
        None => {
            return Ok(Counts {
                not_found: 1,
                ..Counts::default()
            })
        }
    };
    let snapshot = read_snapshot(h, &ctx.link_id, rating_key)?;
    let mut ap = Applier::default();
    ap.item(
        h,
        &ctx,
        rating_key,
        &local_side(row),
        &remote,
        snapshot.as_ref(),
    )?;
    ap.flush(h)?;
    Ok(ap.counts)
}

struct LinkCtx<'a> {
    base: &'a str,
    /// The link whose token reads and writes Plex for this user.
    req_link: String,
    /// The user link that owns the state keys.
    link_id: String,
    user_id: String,
    direction: Direction,
    origin: String,
    unwatch_pass: bool,
    /// Rating keys the rev index resolves some identity to (see the unwatch pass).
    canonical: HashSet<String>,
}

fn request_link(
    h: &mut dyn Host,
    link: &AccountLink,
    owner_link: &str,
) -> Result<String, SyncError> {
    let uses_owner = h.kv_get(&store::link_uses_owner_key(&link.id))?.as_deref() == Some("1");
    Ok(if uses_owner {
        owner_link.to_string()
    } else {
        link.id.clone()
    })
}

fn sync_link(
    h: &mut dyn Host,
    ctx: &LinkCtx,
    local: &LocalIndex,
    deadline_ms: u64,
) -> Result<LinkOutcome, SyncError> {
    let mut ap = Applier::default();

    // 1. Pull pass
    let page_key = store::link_pull_page_key(&ctx.link_id);
    let mut page = match store::get_json::<PullPage>(h, &page_key)? {
        Some(p) => p,
        None => PullPage {
            since: h
                .kv_get(&store::link_pull_cursor_key(&ctx.link_id))?
                .and_then(|s| s.parse::<i64>().ok())
                .map(|c| c - CURSOR_OVERLAP_SECONDS),
            started_at: h.now(),
            section_index: 0,
            section_key: None,
            offset: 0,
        },
    };
    let sections: Vec<api::Section> = api::sections(h, ctx.base, &ctx.req_link)?
        .into_iter()
        .filter(|s| s.kind == "movie" || s.kind == "show")
        .collect();
    if let Some(key) = &page.section_key {
        match sections.iter().position(|s| &s.key == key) {
            Some(i) => page.section_index = i,
            // The section is gone: start the pass over rather than skip one.
            None => {
                page.section_index = 0;
                page.offset = 0;
            }
        }
    }
    let mut seen: HashSet<String> = HashSet::new();
    // Shrinks when the host refuses a response as too large; see mapping.rs.
    let mut page_size = api::PAGE_SIZE;

    while page.section_index < sections.len() {
        page.section_key = Some(sections[page.section_index].key.clone());
        if h.elapsed_ms() >= deadline_ms {
            ap.flush(h)?;
            store::put_json(h, &page_key, &page)?;
            return Ok(LinkOutcome::Partial(ap.counts));
        }
        let section = &sections[page.section_index];
        let (start, since, is_movie) = (page.offset, page.since, section.kind == "movie");
        let fetched = api::page_shrinking(
            h,
            page_size,
            &format!("library section {} at item {start}", section.key),
            |h, size| {
                if is_movie {
                    api::section_items(h, ctx.base, &ctx.req_link, &section.key, start, since, size)
                } else {
                    api::section_episodes(
                        h,
                        ctx.base,
                        &ctx.req_link,
                        &section.key,
                        start,
                        since,
                        size,
                    )
                }
            },
        )?;
        page_size = fetched.size;
        let items = &fetched.items;
        for item in items.iter().filter(|i| changed_since(i, page.since)) {
            let rk = item.rating_key.as_str();
            seen.insert(rk.to_string());
            let snapshot = read_snapshot(h, &ctx.link_id, rk)?;
            // A duplicate Plex copy never has a local row of its own (rows
            // resolve to the canonical key), so its "local" side is unknown, not
            // absent: reuse the snapshot so only Plex-side changes act on it.
            let local_side = if ctx.canonical.contains(rk) {
                local
                    .get(&ctx.user_id, rk)
                    .map(|r| r.side)
                    .unwrap_or(ABSENT)
            } else {
                snapshot.as_ref().map(Snapshot::side).unwrap_or(ABSENT)
            };
            ap.item(
                h,
                ctx,
                rk,
                &local_side,
                &remote_side(item),
                snapshot.as_ref(),
            )?;
        }
        if fetched.has_more() {
            // A skipped page (too large even at the minimum) advances by its
            // size so the pass never wedges on it.
            page.offset += fetched.size;
        } else {
            page.section_index += 1;
            page.offset = 0;
            page.section_key = sections.get(page.section_index).map(|s| s.key.clone());
        }
        ap.flush(h)?;
        store::put_json(h, &page_key, &page)?;
    }
    h.kv_set(
        &store::link_pull_cursor_key(&ctx.link_id),
        &page.started_at.to_string(),
    )?;
    h.kv_delete(&page_key)?;

    // 2. Push pass
    let push_key = store::link_push_cursor_key(&ctx.link_id);
    let push_cursor = h.kv_get(&push_key)?;
    let mut rows: Vec<(&String, &LocalRow)> = local
        .for_user(&ctx.user_id)
        .filter(|(rk, row)| {
            !seen.contains(rk.as_str())
                && row.origin.as_deref() != Some(ctx.origin.as_str())
                // RFC3339 with microseconds in UTC sorts lexically. ">=" re-reads
                // the previous pass's last row, which reconciles to Noop.
                && push_cursor
                    .as_deref()
                    .is_none_or(|c| row.updated_at.as_str() >= c)
        })
        .collect();
    rows.sort_by(|a, b| a.1.updated_at.cmp(&b.1.updated_at));

    let mut push_failed = false;
    for (i, (rk, row)) in rows.iter().enumerate() {
        if h.elapsed_ms() >= deadline_ms {
            ap.flush(h)?;
            return Ok(LinkOutcome::Partial(ap.counts));
        }
        let snapshot = read_snapshot(h, &ctx.link_id, rk)?;
        let remote = match &snapshot {
            Some(s) => s.side(),
            None => match api::metadata(h, ctx.base, &ctx.req_link, rk)? {
                Some(item) => remote_side(&item),
                None => {
                    ap.counts.not_found += 1;
                    continue;
                }
            },
        };
        let errors_before = ap.counts.errors;
        ap.item(h, ctx, rk, &row.side, &remote, snapshot.as_ref())?;
        // A failed push must be retried: from the first failure on, the cursor
        // stays at the last row that succeeded (rows read with ">=").
        push_failed |= ap.counts.errors > errors_before;
        if !push_failed {
            ap.pending.push(KvEntry {
                key: push_key.clone(),
                value: row.updated_at.clone(),
            });
        }
        if (i + 1) % FLUSH_EVERY == 0 {
            ap.flush(h)?;
        }
    }
    ap.flush(h)?;

    // 3. Unwatch pass
    // Skipped until the rev index exists: before that no local row resolves, so
    // every "watched" snapshot would look like an unwatch.
    if ctx.unwatch_pass {
        let prefix = format!("link/{}/state/", ctx.link_id);
        let mut cursor: Option<String> = None;
        loop {
            if h.elapsed_ms() >= deadline_ms {
                ap.flush(h)?;
                return Ok(LinkOutcome::Partial(ap.counts));
            }
            let kv_page = h.kv_list(&prefix, cursor.as_deref())?;
            for e in &kv_page.entries {
                let rk = &e.key[prefix.len()..];
                if seen.contains(rk) || local.get(&ctx.user_id, rk).is_some() {
                    continue;
                }
                // Local rows resolve only to the rating key the rev index keeps
                // for an identity. A second Plex copy of the same item (a 4K and
                // a 1080p file) is never that key, so "no local row" says
                // nothing about it: skip it rather than unscrobble a copy the
                // user still has watched locally.
                if !ctx.canonical.contains(rk) {
                    continue;
                }
                let Ok(snap) = serde_json::from_str::<Snapshot>(&e.value) else {
                    continue;
                };
                if snap.watched {
                    // Row gone, snapshot says watched: a local unwatch. Remote is
                    // taken as unchanged, since the pull pass saw nothing new.
                    ap.item(h, ctx, rk, &ABSENT, &snap.side(), Some(&snap))?;
                }
            }
            ap.flush(h)?;
            match kv_page.next_cursor {
                Some(c) => cursor = Some(c),
                None => break,
            }
        }
    }

    Ok(LinkOutcome::Complete(ap.counts))
}

#[derive(Default)]
struct Applier {
    pending: Vec<KvEntry>,
    counts: Counts,
}

impl Applier {
    fn item(
        &mut self,
        h: &mut dyn Host,
        ctx: &LinkCtx,
        rk: &str,
        local: &Side,
        remote: &Side,
        snapshot: Option<&Snapshot>,
    ) -> Result<(), SyncError> {
        let snap_side = snapshot.map(Snapshot::side);
        match decide(local, remote, snap_side.as_ref(), ctx.direction) {
            Action::Noop => self.counts.unchanged += 1,
            Action::Record(c) => {
                self.record(h, ctx, rk, c, remote.at, snapshot.is_some());
                self.counts.unchanged += 1;
            }
            Action::SkippedByDirection(c) => {
                self.record(h, ctx, rk, c, remote.at, snapshot.is_some());
                self.counts.skipped += 1;
            }
            Action::Pull(c) => {
                if pull(h, ctx, rk, c, remote.at)? {
                    self.record(h, ctx, rk, c, remote.at, snapshot.is_some());
                    self.counts.pulled += 1;
                } else {
                    self.counts.not_found += 1;
                }
            }
            Action::Push(c) => match push(h, ctx, rk, c) {
                Ok(()) => {
                    self.record(h, ctx, rk, c, remote.at, snapshot.is_some());
                    self.counts.pushed += 1;
                }
                Err(PlexError::Unauthorized) => return Err(SyncError::Unauthorized),
                Err(e) => {
                    h.log(
                        "warn",
                        &format!("plex: push of {rk} failed: {}", e.message()),
                    );
                    self.counts.errors += 1;
                }
            },
        }
        Ok(())
    }

    fn record(
        &mut self,
        h: &mut dyn Host,
        ctx: &LinkCtx,
        rk: &str,
        c: Change,
        remote_at: Option<i64>,
        has_snapshot: bool,
    ) {
        // A missing snapshot and an unwatched, position-less one reconcile
        // identically, so storing the latter for every unwatched item in the
        // library only spends quota. An existing snapshot is always refreshed:
        // leaving a stale "watched" behind would repeat the unwatch forever.
        if !has_snapshot && !c.watched && c.position.is_none() {
            return;
        }
        let snap = Snapshot {
            watched: c.watched,
            position: c.position,
            synced_at: time::to_rfc3339(h.now()),
            remote_last_watched_at: remote_at.map(time::to_rfc3339),
        };
        self.pending.push(KvEntry {
            key: store::link_state_key(&ctx.link_id, rk),
            value: serde_json::to_string(&snap).expect("Snapshot serializes"),
        });
    }

    fn flush(&mut self, h: &mut dyn Host) -> Result<(), SyncError> {
        if !self.pending.is_empty() {
            let batch = std::mem::take(&mut self.pending);
            store::set_many(h, &batch)?;
        }
        Ok(())
    }
}

fn pull(
    h: &mut dyn Host,
    ctx: &LinkCtx,
    rk: &str,
    c: Change,
    remote_at: Option<i64>,
) -> Result<bool, SyncError> {
    let Some(entry) = mapping::get_entry(h, rk)? else {
        return Ok(false);
    };
    // Episodes resolve by their show's ids plus coordinates, like the crawl.
    let (imdb, tmdb, tvdb) = if entry.kind == "episode" {
        (entry.show_imdb.clone(), entry.show_tmdb, entry.show_tvdb)
    } else {
        (entry.imdb.clone(), entry.tmdb, entry.tvdb)
    };
    let target = WatchStateTarget {
        user_id: ctx.user_id.clone(),
        imdb_id: imdb,
        tmdb_id: tmdb,
        tvdb_id: tvdb,
        season_number: entry.season,
        episode_number: entry.episode,
        watched: c.watched,
        position_seconds: c.position.map(|p| p.max(0) as u32),
        duration_seconds: None,
        watched_at: remote_at.map(time::to_rfc3339),
    };
    Ok(h.set_watch_state(&target)?.status != EnsureWatchedStatus::NotFound)
}

/// Watched flag first, then position: an unscrobble must never clear a resume
/// point written for an in-progress item, so the resume point is set after it.
/// An unwatched change always unscrobbles, position or not: the local unwatch
/// (a watched item with a resume point) has to clear Plex's watched flag, and
/// skipping the call would leave Plex watched for the next pull to bring back.
fn push(h: &mut dyn Host, ctx: &LinkCtx, rk: &str, c: Change) -> Result<(), PlexError> {
    if c.watched {
        api::scrobble(h, ctx.base, &ctx.req_link, rk)?;
    } else {
        api::unscrobble(h, ctx.base, &ctx.req_link, rk)?;
    }
    if let Some(p) = c.position {
        api::progress(h, ctx.base, &ctx.req_link, rk, p.max(0) as u32)?;
    }
    Ok(())
}

fn read_snapshot(h: &mut dyn Host, link_id: &str, rk: &str) -> Result<Option<Snapshot>, SyncError> {
    Ok(store::get_json(h, &store::link_state_key(link_id, rk))?)
}

fn load_rev(h: &mut dyn Host) -> Result<HashMap<String, String>, SyncError> {
    let mut out = HashMap::new();
    let mut cursor: Option<String> = None;
    loop {
        let page = h.kv_list("rev/", cursor.as_deref())?;
        for e in page.entries {
            if let Ok(rk) = serde_json::from_str::<String>(&e.value) {
                out.insert(e.key, rk);
            }
        }
        match page.next_cursor {
            Some(c) => cursor = Some(c),
            None => return Ok(out),
        }
    }
}

/// Every linked user's progress rows. data-list is consent-scoped host-side,
/// so one scan covers exactly the users with an active link.
fn load_progress(h: &mut dyn Host) -> Result<Vec<PlaybackProgress>, SyncError> {
    let mut out = Vec::new();
    let mut cursor: Option<String> = None;
    loop {
        let res = h.data_list(&ListRequest {
            namespace: "playback_progress".into(),
            cursor: cursor.clone(),
            updated_since: None,
            limit: Some(api::PAGE_SIZE),
        })?;
        for item in res.items {
            if let ListItem::PlaybackProgress(p) = item {
                out.push(p);
            }
        }
        match res.next_cursor {
            Some(c) => cursor = Some(c),
            None => return Ok(out),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::api::Metadata;
    use crate::host::fake::FakeHost;
    use crate::mapping::progress_row;
    use mydia_plugin_sdk::types::ListResult;

    const NOW: i64 = 1_767_225_600;
    const B: &str = "http://plex.test";

    fn meta(rk: &str, views: u32, offset_ms: Option<u64>, last: Option<i64>) -> Metadata {
        Metadata {
            rating_key: rk.into(),
            view_count: views,
            view_offset: offset_ms,
            last_viewed_at: last,
            parent_index: None,
            index: None,
            guids: vec![],
        }
    }

    #[test]
    fn origin_names_the_instance() {
        let cfg = PluginConfig::parse(r#"{"instance_id":"I1"}"#);
        assert_eq!(origin(&cfg), "plugin:plex:I1");
    }

    #[test]
    fn remote_position_is_converted_from_milliseconds() {
        assert_eq!(
            remote_side(&meta("1", 0, Some(95_500), Some(NOW))),
            Side {
                watched: false,
                position: Some(95),
                at: Some(NOW)
            }
        );
        assert_eq!(remote_side(&meta("1", 2, Some(0), None)).position, None);
    }

    #[test]
    fn changed_since_matches_the_native_filter() {
        assert!(changed_since(&meta("1", 0, None, None), None));
        assert!(changed_since(&meta("1", 0, Some(1000), None), Some(NOW)));
        assert!(!changed_since(&meta("1", 0, None, None), Some(NOW)));
        assert!(changed_since(&meta("1", 1, None, Some(NOW)), Some(NOW)));
        assert!(!changed_since(
            &meta("1", 1, None, Some(NOW - 1)),
            Some(NOW)
        ));
    }

    #[test]
    fn direction_is_honored_after_the_reconciler() {
        let snap = Side {
            watched: false,
            position: None,
            at: None,
        };
        let watched = Side {
            watched: true,
            position: None,
            at: None,
        };
        let c = Change {
            watched: true,
            position: None,
        };
        assert_eq!(
            decide(&ABSENT, &watched, Some(&snap), Direction::Export),
            Action::SkippedByDirection(c)
        );
        assert_eq!(
            decide(&watched, &ABSENT, Some(&snap), Direction::Import),
            Action::SkippedByDirection(c)
        );
        assert_eq!(
            decide(&ABSENT, &watched, Some(&snap), Direction::Import),
            Action::Pull(c)
        );
    }

    #[test]
    fn local_index_resolves_rows_through_the_rev_index() {
        let mut m = progress_row("movie");
        m.tmdb_id = Some(4001);
        m.watched = true;
        let mut lost = progress_row("movie");
        lost.tmdb_id = Some(9999);
        let rev: HashMap<String, String> =
            [("rev/movie/tmdb/4001".to_string(), "100".to_string())].into();

        let idx = LocalIndex::build(vec![m, lost], &rev);
        assert!(idx.get("u1", "100").unwrap().side.watched);
        assert_eq!(idx.unresolved, 1);
        assert_eq!(idx.for_user("u1").count(), 1);
        assert_eq!(idx.for_user("u2").count(), 0);
    }

    // run_tick against the fake host

    fn cfg() -> PluginConfig {
        PluginConfig::parse(r#"{"instance_id":"I1","sync_watched":"on"}"#)
    }

    fn add_user_link(host: &mut FakeHost, id: &str, user: &str) {
        host.with_link(
            id,
            LinkRole::User,
            Some(&format!("uuid-{user}")),
            Some(user),
        );
        host.links.last_mut().unwrap().user_id = Some(user.to_string());
    }

    /// A crawled one-movie library (rating key 100, tmdb 4001) with one user link.
    fn crawled() -> FakeHost {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        host.with_link("owner", LinkRole::Owner, None, None);
        add_user_link(&mut host, "L1", "u1");
        let state = mapping::CrawlState {
            completed_at: Some(NOW - 60),
            last_completed_at: Some(NOW - 60),
            ..Default::default()
        };
        host.kv
            .insert("crawl/state".into(), serde_json::to_string(&state).unwrap());
        host.kv.insert(
            "map/100".into(),
            r#"{"kind":"movie","imdb":null,"tmdb":4001,"tvdb":null,"season":null,"episode":null,"show_tmdb":null,"show_tvdb":null}"#.into(),
        );
        host.kv
            .insert("rev/movie/tmdb/4001".into(), "\"100\"".into());
        host.respond(
            "GET",
            &format!("{B}/library/sections"),
            200,
            r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Films"}]}}"#,
        );
        host
    }

    /// The fake queues responses per URL and pops them in order, so a test
    /// registers the first-pull listing exactly once: this, or its own.
    fn empty_movies(host: &mut FakeHost) {
        host.respond(
            "GET",
            &format!("{B}/library/sections/1/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{}}"#,
        );
    }

    fn with_progress(host: &mut FakeHost, rows: Vec<PlaybackProgress>) {
        host.data_pages.push_back(ListResult {
            items: rows.into_iter().map(ListItem::PlaybackProgress).collect(),
            next_cursor: None,
        });
    }

    fn tick(host: &mut FakeHost) -> TickOutcome {
        run_tick(host, B, "owner", "owner", &cfg(), 45_000).unwrap()
    }

    #[test]
    fn a_remote_watch_is_pulled_and_snapshotted() {
        let mut host = crawled();
        host.respond("GET", &format!("{B}/library/sections/1/all?includeGuids=1"), 200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":1,"lastViewedAt":1767225000}]}}"#);

        let out = tick(&mut host);
        assert!(out.complete);
        assert_eq!(out.counts.pulled, 1);

        let write = host.watch_writes.last().unwrap();
        assert_eq!(
            (write.user_id.as_str(), write.tmdb_id, write.watched),
            ("u1", Some(4001), true)
        );
        assert_eq!(write.watched_at.as_deref(), Some("2025-12-31T23:50:00Z"));

        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/100"]).unwrap();
        assert!(snap.watched);
        assert_eq!(
            host.kv.get("link/L1/cursor/pull").map(String::as_str),
            Some("1767225600")
        );
        assert!(!host.kv.contains_key("link/L1/cursor/pull_page"));
        // The profile's own link read Plex, not the owner's.
        let reads = host.requests_to(&format!("{B}/library/sections/1/all?includeGuids=1"));
        assert!(reads.iter().any(|s| s.link.as_deref() == Some("L1")));
    }

    #[test]
    fn a_second_tick_pulls_incrementally_with_overlap() {
        let mut host = crawled();
        host.kv
            .insert("link/L1/cursor/pull".into(), (NOW - 3600).to_string());
        let since = format!(
            "{B}/library/sections/1/all?includeGuids=1&lastViewedAt%3E={}",
            NOW - 3600 - 900
        );
        host.respond("GET", &since, 200, r#"{"MediaContainer":{}}"#);

        tick(&mut host);
        assert_eq!(host.requests_to(&since).len(), 1);
    }

    #[test]
    fn a_newer_local_position_is_pushed_in_milliseconds() {
        let mut host = crawled();
        empty_movies(&mut host);
        host.respond(
            "GET",
            &format!("{B}/library/metadata/100?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        let progress = format!(
            "{B}/:/progress?identifier=com.plexapp.plugins.library&key=100&time=95000&state=stopped"
        );
        host.respond("GET", &progress, 200, "");
        host.respond(
            "GET",
            &format!("{B}/:/unscrobble?identifier=com.plexapp.plugins.library&key=100"),
            200,
            "",
        );
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.position_seconds = Some(95);
        row.last_watched_at = Some("2026-01-01T00:00:00Z".into());
        row.origin = Some("player".into());
        with_progress(&mut host, vec![row]);

        let out = tick(&mut host);
        assert_eq!(out.counts.pushed, 1);
        assert_eq!(host.requests_to(&progress)[0].link.as_deref(), Some("L1"));
        // An unwatched change always clears the watched flag first (native
        // parity); the resume point is set after it.
        assert!(host.sent.iter().all(|s| !s.url.contains("/:/scrobble?")));
        assert_eq!(
            host.kv.get("link/L1/cursor/push").map(String::as_str),
            Some("2026-01-01T00:00:00.000000Z")
        );
    }

    #[test]
    fn rows_this_instance_wrote_are_not_pushed_back() {
        let mut host = crawled();
        empty_movies(&mut host);
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = true;
        row.origin = Some("plugin:plex:I1".into());
        with_progress(&mut host, vec![row]);

        let out = tick(&mut host);
        assert_eq!(out.counts.pushed, 0);
        assert!(host.sent.iter().all(|s| !s.url.contains("/:/")));
    }

    #[test]
    fn a_local_unwatch_after_a_snapshot_pushes_unscrobble() {
        let mut host = crawled();
        empty_movies(&mut host);
        let unscrobble = format!("{B}/:/unscrobble?identifier=com.plexapp.plugins.library&key=100");
        host.respond("GET", &unscrobble, 200, "");
        host.kv.insert(
            "link/L1/state/100".into(),
            r#"{"watched":true,"position":null,"synced_at":"2026-01-01T00:00:00Z","remote_last_watched_at":null}"#.into(),
        );

        let out = tick(&mut host);
        assert_eq!(out.counts.pushed, 1);
        assert_eq!(host.requests_to(&unscrobble)[0].link.as_deref(), Some("L1"));
        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/100"]).unwrap();
        assert!(!snap.watched);
    }

    #[test]
    fn a_second_plex_copy_of_a_locally_watched_item_is_never_unscrobbled() {
        // "101" is a second file of the item crawled as "100" (same tmdb id);
        // the rev index keeps "100", so the local row resolves there, and "101"
        // has a watched snapshot but no local row of its own.
        let mut host = crawled();
        empty_movies(&mut host);
        host.kv.insert(
            "link/L1/state/101".into(),
            r#"{"watched":true,"position":null,"synced_at":"2026-01-01T00:00:00Z","remote_last_watched_at":null}"#.into(),
        );
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = true;
        row.origin = Some("plugin:plex:I1".into());
        with_progress(&mut host, vec![row]);

        tick(&mut host);
        assert!(host.sent.iter().all(|s| !s.url.contains("/:/unscrobble")));
        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/101"]).unwrap();
        assert!(snap.watched);
    }

    #[test]
    fn without_state_a_remote_unwatched_item_is_never_unwatched_locally_or_remotely() {
        // Env-declared server: no migrated snapshot. Local says watched, Plex says
        // not: the baseline scrobbles, it never pulls the unwatch.
        let mut host = crawled();
        host.respond(
            "GET",
            &format!("{B}/library/sections/1/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        let scrobble = format!("{B}/:/scrobble?identifier=com.plexapp.plugins.library&key=100");
        host.respond("GET", &scrobble, 200, "");
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = true;
        row.origin = Some("player".into());
        with_progress(&mut host, vec![row]);

        let out = tick(&mut host);
        assert_eq!(out.counts.pushed, 1);
        assert_eq!(host.requests_to(&scrobble).len(), 1);
        assert!(
            host.watch_writes.iter().all(|w| w.watched),
            "never pulls an unwatch"
        );
    }

    #[test]
    fn a_user_without_home_syncs_through_the_owner_link() {
        let mut host = crawled();
        empty_movies(&mut host);
        host.kv.insert("link/L1/uses_owner".into(), "1".into());
        tick(&mut host);
        let reads = host.requests_to(&format!("{B}/library/sections/1/all?includeGuids=1"));
        assert!(!reads.is_empty());
        assert!(reads.iter().all(|s| s.link.as_deref() == Some("owner")));
        assert!(
            host.kv.contains_key("link/L1/cursor/pull"),
            "state stays keyed by the user link"
        );
    }

    #[test]
    fn the_pull_pass_never_unscrobbles_a_duplicate_plex_copy() {
        // "101" is a second copy of item "100": it has a snapshot and Plex lists
        // it as watched, but local rows only ever resolve to "100".
        let mut host = crawled();
        host.kv.insert(
            "link/L1/state/101".into(),
            r#"{"watched":true,"position":null,"synced_at":"2026-01-01T00:00:00Z","remote_last_watched_at":null}"#.into(),
        );
        host.respond("GET", &format!("{B}/library/sections/1/all?includeGuids=1"), 200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"101","type":"movie","viewCount":1,"lastViewedAt":1767225000}]}}"#);
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = true;
        row.origin = Some("plugin:plex:I1".into());
        with_progress(&mut host, vec![row]);

        tick(&mut host);
        assert!(host
            .sent
            .iter()
            .all(|s| !s.url.contains("/:/unscrobble") && !s.url.contains("/:/scrobble")));
    }

    #[test]
    fn a_failed_push_leaves_the_cursor_so_the_next_tick_retries() {
        let mut host = crawled();
        empty_movies(&mut host);
        host.respond(
            "GET",
            &format!("{B}/library/metadata/100?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        // No scrobble response is scripted, so the push fails as unreachable.
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = true;
        row.origin = Some("player".into());
        with_progress(&mut host, vec![row]);

        let out = tick(&mut host);
        assert_eq!(out.counts.errors, 1);
        assert_eq!(out.counts.pushed, 0);
        assert!(!host.kv.contains_key("link/L1/cursor/push"));
        assert!(!host.kv.contains_key("link/L1/state/100"));
    }

    #[test]
    fn a_link_whose_request_link_cannot_resolve_does_not_stop_the_others() {
        let mut host = crawled();
        empty_movies(&mut host);
        add_user_link(&mut host, "L2", "u2");
        host.kv_get_failures.push("link/L1/uses_owner".into());

        let out = tick(&mut host);
        assert_eq!(out.counts.errors, 1);
        assert!(!host.kv.contains_key("link/L1/cursor/pull"));
        assert!(host.kv.contains_key("link/L2/cursor/pull"));
    }

    #[test]
    fn a_resumed_pull_finds_its_section_by_key() {
        let mut host = crawled();
        host.responses
            .remove(&("GET".to_string(), format!("{B}/library/sections")));
        host.respond("GET", &format!("{B}/library/sections"), 200,
            r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Films"},{"key":"2","type":"show","title":"Series"}]}}"#);
        // The saved index is stale (0); the key says the pass was in section 2.
        host.kv.insert(
            "link/L1/cursor/pull_page".into(),
            r#"{"since":null,"started_at":1767225000,"section_index":0,"section_key":"2","offset":0}"#.into(),
        );
        host.respond(
            "GET",
            &format!("{B}/library/sections/2/all?type=4&includeGuids=1"),
            200,
            r#"{"MediaContainer":{}}"#,
        );

        tick(&mut host);
        assert!(host
            .requests_to(&format!("{B}/library/sections/1/all?includeGuids=1"))
            .is_empty());
        assert_eq!(
            host.requests_to(&format!("{B}/library/sections/2/all?type=4&includeGuids=1"))
                .len(),
            1
        );
        assert!(!host.kv.contains_key("link/L1/cursor/pull_page"));
    }

    #[test]
    fn a_401_on_one_link_marks_only_that_link() {
        let mut host = crawled();
        empty_movies(&mut host);
        add_user_link(&mut host, "L2", "u2");
        host.respond_link("L1", "GET", &format!("{B}/library/sections"), 401, "");

        let out = tick(&mut host);
        assert_eq!(out.unauthorized_links, vec!["L1".to_string()]);
        assert_eq!(host.statuses.len(), 1);
        assert_eq!(host.statuses[0].0, "L1");
        assert_eq!(host.statuses[0].1, LinkStatus::Error);
        assert!(host.kv.contains_key("link/L2/cursor/pull"));
    }

    #[test]
    fn an_exhausted_budget_leaves_the_cursor_and_reports_incomplete() {
        let mut host = crawled();
        host.elapsed = 45_000;
        let out = tick(&mut host);
        assert!(!out.complete);
        assert!(!host.kv.contains_key("link/L1/cursor/pull"));
    }

    #[test]
    fn nothing_syncs_before_the_first_crawl_completes() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        host.elapsed = 45_000;
        add_user_link(&mut host, "L1", "u1");
        host.respond(
            "GET",
            &format!("{B}/library/sections"),
            200,
            r#"{"MediaContainer":{"Directory":[{"key":"1","type":"movie","title":"Films"}]}}"#,
        );
        let out = tick(&mut host);
        assert!(!out.complete);
        assert!(host.watch_writes.is_empty());
        assert!(host.data_requests.is_empty());
    }

    #[test]
    fn a_too_large_pull_page_is_retried_smaller_at_the_same_offset() {
        let mut host = crawled();
        let url = format!("{B}/library/sections/1/all?includeGuids=1");
        host.fail(
            "GET",
            &url,
            HostError::Network("response exceeded 1048576 bytes".into()),
        );
        host.respond("GET", &url, 200, r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":1,"lastViewedAt":1767225000}]}}"#);

        let out = tick(&mut host);
        assert!(out.complete);
        assert_eq!(out.counts.pulled, 1);
        assert_eq!(out.counts.errors, 0);
        let sent = host.requests_to(&url);
        assert_eq!(sent[0].header("X-Plex-Container-Size"), Some("200"));
        assert_eq!(sent[1].header("X-Plex-Container-Size"), Some("100"));
        assert_eq!(sent[1].header("X-Plex-Container-Start"), Some("0"));
    }

    #[test]
    fn an_item_unwatched_on_both_sides_leaves_no_snapshot() {
        let mut host = crawled();
        host.respond(
            "GET",
            &format!("{B}/library/sections/1/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        let out = tick(&mut host);
        assert_eq!(out.counts.unchanged, 1);
        assert!(
            !host.kv.contains_key("link/L1/state/100"),
            "a missing snapshot and an unwatched one reconcile identically"
        );
    }

    #[test]
    fn an_item_with_a_position_or_a_watch_still_records_its_snapshot() {
        let mut host = crawled();
        host.respond(
            "GET",
            &format!("{B}/library/sections/1/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0,"viewOffset":120000}]}}"#,
        );
        let out = tick(&mut host);
        assert_eq!(out.counts.pulled, 1);
        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/100"]).unwrap();
        assert_eq!((snap.watched, snap.position), (false, Some(120)));
    }

    #[test]
    fn an_unwatch_of_a_known_item_still_updates_its_stale_snapshot() {
        // The snapshot said watched; both sides now agree on unwatched with no
        // position. Dropping the write would leave "watched" behind to be
        // unscrobbled again on every tick.
        let mut host = crawled();
        host.respond(
            "GET",
            &format!("{B}/library/sections/1/all?includeGuids=1"),
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0}]}}"#,
        );
        host.kv.insert(
            "link/L1/state/100".into(),
            r#"{"watched":true,"position":null,"synced_at":"2026-01-01T00:00:00Z","remote_last_watched_at":null}"#.into(),
        );
        tick(&mut host);
        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/100"]).unwrap();
        assert!(!snap.watched);
    }

    #[test]
    fn an_unwatch_with_a_resume_position_unscrobbles_first_then_sets_progress() {
        let mut host = crawled();
        empty_movies(&mut host);
        let unscrobble = format!("{B}/:/unscrobble?identifier=com.plexapp.plugins.library&key=100");
        let progress = format!(
            "{B}/:/progress?identifier=com.plexapp.plugins.library&key=100&time=95000&state=stopped"
        );
        host.respond("GET", &unscrobble, 200, "");
        host.respond("GET", &progress, 200, "");
        host.kv.insert(
            "link/L1/state/100".into(),
            r#"{"watched":true,"position":null,"synced_at":"2026-01-01T00:00:00Z","remote_last_watched_at":null}"#.into(),
        );
        let mut row = progress_row("movie");
        row.tmdb_id = Some(4001);
        row.watched = false;
        row.position_seconds = Some(95);
        row.origin = Some("player".into());
        with_progress(&mut host, vec![row.clone()]);

        let out = tick(&mut host);
        assert_eq!(out.counts.pushed, 1);
        let order: Vec<&str> = host
            .sent
            .iter()
            .filter(|s| s.url.contains("/:/"))
            .map(|s| s.url.as_str())
            .collect();
        assert_eq!(order, vec![unscrobble.as_str(), progress.as_str()]);
        let snap: Snapshot = serde_json::from_str(&host.kv["link/L1/state/100"]).unwrap();
        assert_eq!((snap.watched, snap.position), (false, Some(95)));

        // Next tick: Plex now reports the item unwatched with the resume point.
        // Nothing may be written again.
        let sent_before = host.sent.len();
        let since = format!(
            "{B}/library/sections/1/all?includeGuids=1&lastViewedAt%3E={}",
            NOW - 900
        );
        host.respond(
            "GET",
            &since,
            200,
            r#"{"MediaContainer":{"Metadata":[{"ratingKey":"100","type":"movie","viewCount":0,"viewOffset":95000}]}}"#,
        );
        with_progress(&mut host, vec![row]);
        let out = tick(&mut host);
        assert_eq!((out.counts.pushed, out.counts.pulled), (0, 0));
        assert!(host.sent[sent_before..]
            .iter()
            .all(|s| !s.url.contains("/:/")));
    }

    #[test]
    fn a_large_pending_set_is_flushed_in_batches_the_host_accepts() {
        let mut host = FakeHost::new();
        let mut ap = Applier::default();
        ap.pending = (0..1100)
            .map(|i| KvEntry {
                key: format!("link/L1/state/{i}"),
                value: "{}".into(),
            })
            .collect();
        ap.flush(&mut host).unwrap();
        assert_eq!(host.kv.len(), 1100);
        assert!(host.batches.iter().all(|b| b.len() <= 500));
        assert!(ap.pending.is_empty());
    }

    #[test]
    fn an_owner_401_during_the_crawl_is_an_error() {
        let mut host = FakeHost::new();
        host.now_value = NOW;
        host.respond("GET", &format!("{B}/library/sections"), 401, "");
        assert_eq!(
            run_tick(&mut host, B, "owner", "owner", &cfg(), 45_000).unwrap_err(),
            SyncError::Unauthorized
        );
    }
}
