# Fill a shelf

A plugin can fill a rail on the Home dashboard. The plugin returns provider ids
and a one-line reason for each title. The host resolves the ids, filters out
what the user should not see, stores the result and draws the rail. This guide
declares a "Staff picks" shelf and fills it from a plugin.

For every field and function, see the
[`fill-shelf`](../reference/guest-exports.md#fill-shelf) reference and the
[manifest reference](../reference/manifest.md#shelves).

## 1. Declare the shelf

```json
{
  "slug": "staff-picks",
  "name": "Staff picks",
  "version": "0.1.0",
  "min_host_version": "0.16.0",
  "shelves": [
    {
      "key": "staff_picks",
      "title": "Picked for you",
      "placement": "home",
      "scope": "user",
      "ttl_seconds": 86400,
      "refresh_on": ["playback.finished"]
    }
  ],
  "capabilities": {
    "surfaces:shelf": [],
    "data:read": ["library_item", "watch_history"]
  }
}
```

`surfaces:shelf` takes an empty list and is required whenever `shelves` is
present. `events:subscribe` is not needed. The shelf appears once an
administrator approves the plugin. A plugin may declare at most four shelves.

## 2. Implement `fill-shelf`

Use the `fill_shelf` argument of the plugin macro. The host calls the function
for one user and expects the titles best first.

```rust
use mydia_plugin_sdk::types::{Event, MediaRef, ShelfItem, ShelfRequest};

fn fill(req: ShelfRequest) -> Result<Vec<ShelfItem>, String> {
    if req.shelf != "staff_picks" {
        return Err(format!("unknown shelf {}", req.shelf));
    }
    // A real shelf should return at least three titles. With fewer, the host stores nothing.
    Ok(vec![ShelfItem {
        item: MediaRef { media_type: "movie".into(), tmdb_id: Some(101), tvdb_id: None, imdb_id: None },
        reason: Some("A slow-burn mystery set on a lighthouse".into()),
    }])
}

#[mydia_plugin_sdk::plugin(fill_shelf = fill)]
fn on_event(_evt: Event) -> Result<String, String> {
    Ok("{}".into())
}
```

The request carries `shelf` (the key you declared), `user_id`, `limit`, `now`,
`config_json` and `exclude`. Leave out the titles in `exclude`: the host rejects
them. The full record is under [`fill-shelf`](../reference/guest-exports.md#fill-shelf).

Return an `Err` string when the fill fails, and an empty list when you have
nothing to suggest. An empty list keeps whatever the shelf held.

## 3. Know what the host does with the result

The host treats every returned title as untrusted. It resolves the provider ids
you return, drops titles that do not resolve or that this user should not see,
and takes the title, year and poster from its own metadata. When too few titles
survive, it keeps the previous list. The rules are listed under
[Return contract](../reference/guest-exports.md#return-contract), and the
numbers (how many titles to return, how many must survive, the reason length)
are in [Limits](../reference/limits.md#shelves).

## 4. Choose when it runs

A fill runs when a user opens Home and the shelf is stale. A shelf is stale when
it has never been filled, when `ttl_seconds` has passed since the last fill, or
when an event listed in `refresh_on` fired for that user. Keep `ttl_seconds`
generous: a fill that calls a language model can spend up to two minutes of
model calls. The refresh spacing, the backoff after a failed fill and the queue
size are in [Limits](../reference/limits.md#shelves).

## 5. Read only, and check failures

A fill acts as the shelf's user and cannot change that user's data: every such
function returns `denied`. With `state:kv` it can still write its own store. See
[What a fill may do](../reference/guest-exports.md#what-a-fill-may-do) for the
functions you can call. When fills fail, the plugin's row in
Admin > System > Plugins shows the most recent error your plugin returned, so
keep error strings short and free of secrets.

Operators and users see shelves on Home and can dismiss titles. That side is
covered in [Install and manage plugins](../../using/how-to/plugins.md#what-your-users-see).

## Try it

Build the guest and sideload it as in
[Test and iterate](test-and-iterate.md). The fixture used by Mydia's own tests,
`test/support/fixtures/plugins/shelf_fixture`, fills a shelf in a few lines.
