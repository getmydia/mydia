# Build a Two-Way Sync Plugin

One recipe: keeping Mydia's watched state in sync with a third-party service,
per user, on a schedule and reactively. It assumes the
[tutorial](../tutorial/write-your-first-plugin.md)'s crate layout and build on
the same typed `Event` handler.

**Goal:** keep Mydia's watched state in sync with a third-party service per
user, on a schedule and reactively: the shape the bundled **Simkl** plugin
(`plugins/simkl_sync`) implements. Read its `src/lib.rs` for the complete,
tested version; this recipe is the skeleton and the invariants that matter.

The surfaces a sync plugin uses:

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
    // The host marks these users' connections errored (and ProfileLive offers
    // reconnect). Only users who actually hold a connection are flipped.
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
