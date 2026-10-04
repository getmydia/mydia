# Build a Two-Way Sync Plugin

One recipe: keeping Mydia's watched state in sync with a third-party service,
per user, on a schedule and reactively. It assumes the
[tutorial](../tutorial/write-your-first-plugin.md)'s crate layout and build on
the same typed `Event` handler.

**Goal:** keep Mydia's watched state in sync with a third-party service per
user, on a schedule and reactively: the shape the bundled **Simkl** plugin
(`plugins/simkl_sync`) implements. Read its `src/lib.rs` for the complete,
tested version; this recipe is the skeleton and the invariants that matter.

Each user connects their own account on the **Integrations** page
(`/integrations`). The plugin sees a user only after they connect. The surfaces
a sync plugin uses:

- `users:connections` + a manifest `connection` descriptor: the host runs the
  OAuth flow and holds each user's token; you get `connections-list` (identity
  + status) and `connection-request` (authenticated calls, token injected
  host-side).
- `schedule:interval` + `on-schedule`: a periodic full sync.
- `events:subscribe: ["playback.finished"]` (react to a fresh local watch).
- `state:kv`: watermarks, cursors, and an echo-guard set, **keyed per
  connection** under `conn/<connection-id>/...` so reconnecting a different
  account starts clean.
- `data:read playback_progress` + `surfaces:write playback:watched`: read what
  the user watched locally; mark what the service says they watched.
- `data:read library_item` + `surfaces:write collections:favorite`: read what
  the user owns in their library; favorite what the service lists but they do
  not own locally.

```rust
fn on_schedule(tick: ScheduleTick) -> Result<String, String> {
    let mut invalid = Vec::new();
    for conn in host::connections_list().unwrap_or_default() {
        match sync_one(&conn) {
            Ok(()) => {}
            Err(Unauthorized) => invalid.push(conn.user_id.clone()), // a 401
            Err(_) => {}
        }
    }
    // The host marks these users' connections errored, and the Integrations
    // page then offers Reconnect. Only users who actually hold a connection
    // are flipped.
    Ok(format!("{{\"connections_invalid\":{:?}}}", invalid))
}
```

Three invariants make a sync correct under interruption (the host kills a run on
wall-clock; there is no fuel metering):

1. **Pull checkpoints before applying.** Before you `ensure-watched` a pulled
   item, write its key into the durable pulled-set (`kv-set`). A kill after the
   checkpoint keeps the item out of the push even though the local write hasn't
   landed; the next run re-applies it (`ensure-watched` is idempotent).
2. **Push is at-least-once.** `kv-set` the pending batch before you POST, clear
   it after. A kill in between re-sends next run: a duplicate history entry is
   benign; a lost watch is not.
3. **Never echo.** An item you just pulled from the service must not be pushed
   back. Exclude anything in the pulled-set from the push batch.

Keep watermarks anchored to the **service's** timestamps (never local `now()`),
per user, per direction, so a clock skew or a re-run never re-syncs the world.

A reactive `playback.finished` handler (origin `player` only: your own
write-backs are already suppressed) can push that single watch immediately; the
scheduler's single-flight serializes it against a running sync so your KV state
never interleaves.

## Push an unwatch or a resume position

`ensure-watched` can only mark an item watched. To clear a watch, or to carry a
resume position, call [`set-watch-state`](../reference/host-functions.md#set-watch-state).
It takes the same external ids as `ensure-watched`, plus `watched`,
`position-seconds` and `duration-seconds`:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{EnsureWatchedStatus, WatchStateTarget};

/// Mirror one remote entry onto the user's Mydia watch state.
fn apply_remote(user_id: &str, tmdb_id: i64, watched: bool, resume: Option<(u32, u32)>) {
    let target = WatchStateTarget {
        user_id: user_id.to_string(),
        imdb_id: None,
        tmdb_id: Some(tmdb_id),
        tvdb_id: None,
        season_number: None,
        episode_number: None,
        watched,
        // A present position is written as given, so a half-watched title
        // stays half-watched. Without one, `watched: false` clears the watch.
        position_seconds: resume.map(|(position, _)| position),
        duration_seconds: resume.map(|(_, duration)| duration),
        watched_at: None,
    };
    match host::set_watch_state(&target) {
        Ok(result) if result.status == EnsureWatchedStatus::NotFound => {
            host::log("info", "no local match for that title");
        }
        Ok(_) => {}
        Err(e) => host::log("warn", &format!("set-watch-state failed: {e:?}")),
    }
}
```

The call needs `surfaces:write` with `playback:watched` and an active connection
for the user, like `ensure-watched`. Its result status is `changed`,
`already-watched` or `not-found` (no local item matches the ids). The Simkl
guest builds the same target in `to_target`, with `watched: true` and no
position.

Apply the same invariants as for a pull: write the item's key to the pulled-set
before calling `set-watch-state`, so the unwatch you just applied is not pushed
back to the service.

## React to an unwatch

When a user marks an item unwatched in Mydia, the host deletes their progress
row and emits [`playback.unwatched`](../reference/events.md#playbackunwatched).
Subscribe to it next to `playback.finished`:

```json
"capabilities": {
  "events:subscribe": ["playback.finished", "playback.unwatched"]
}
```

The event carries the user in `actor_id` and, for a movie, the item id as
`media_item_id` in `metadata`. The host withholds an event whose `origin` is
your own plugin, so your `set-watch-state` calls never come back to you. Resolve
the external ids with `data-read`, then push the removal to the service:

```rust
use mydia_plugin_sdk::host;
use mydia_plugin_sdk::types::{DataRequest, Event, ReadResult};
use serde_json::Value;

#[mydia_plugin_sdk::plugin]
fn on_event(evt: Event) -> Result<String, String> {
    if evt.event == "playback.unwatched" && evt.resource_type.as_deref() == Some("media_item") {
        let user_id = evt.actor_id.clone().unwrap_or_default();
        let root: Value = serde_json::from_str(&evt.metadata_json).map_err(|e| e.to_string())?;
        let origin = root["metadata"]["origin"].as_str().unwrap_or_default();
        let id = root["metadata"]["media_item_id"].as_str().unwrap_or_default();

        // Only a player-side unwatch is news to the service.
        if origin == "player" && !id.is_empty() {
            if let Ok(ReadResult::MediaItem(item)) =
                host::data_read(&DataRequest { namespace: "media_item".into(), id: id.into() })
            {
                // Remove `item.tmdb_id` from the service's history for `user_id`,
                // using `connection-request` as in the push leg.
                host::log("info", &format!("unwatched {} for {user_id}", item.title));
            }
        }
    }
    Ok("{}".into())
}
```

This needs `data:read` with `media_item`. An episode event carries `episode_id`
instead, which `data-read` does not serve, so let the scheduled sync pick up
unwatched episodes by comparing the user's `playback_progress` rows with the
service. Hiding a title from Continue Watching does not emit the event.

## List sync (Plan to Watch and Favorites)

When a service exposes a "plan to watch" or wishlist alongside watch history, use
the same set-difference guard as the history echo guard, without storing an echo
set:

- **D** is the set of unwatched, owned library items (`data-list library_item`
  where `owned` is true and the item is not watched).
- **P** is the set of plan-to-watch ids the service reports for the user.

Push **D \\ P** to the service (items you own locally that the service does not
yet list). Favorite **P \\ D** locally (items the service lists that you have
catalogued but do not own). An item in **D ∩ P** was pushed on a prior run and
echoed back by the stub or the live API: the intersection is excluded from both
directions, so push-then-pull never favorites its own output and no durable echo
state is needed.

`ensure-favorite` is additive and idempotent: re-adding reports
`already-favorited`. There is no remove counterpart, so a deletion on the
service side cannot strip local Favorites.

## Next steps

- [Test and iterate](test-and-iterate.md) - install a build, fire test events, and read logs
- [Read media and event data](media-data.md) - the `data:read` and `surfaces:write` calls this recipe leans on
- [Manifest reference](../reference/manifest.md) - the `connection` descriptor, `schedule`, and every capability string
- [Host functions reference](../reference/host-functions.md) - exact signatures for [`connections-list`](../reference/host-functions.md#connections-list), [`connection-request`](../reference/host-functions.md#connection-request), [`ensure-watched`](../reference/host-functions.md#ensure-watched), and [`ensure-favorite`](../reference/host-functions.md#ensure-favorite)
