# Fill a shelf

A plugin can fill a rail on the Home dashboard. The plugin returns provider ids
and a one-line reason for each title. The host resolves the ids, filters out
what the user should not see, stores the result and draws the rail. This guide
declares a "Staff picks" shelf and fills it from a plugin.

For every field and function, see the
[host API](../reference/host-api.md#fill-shelf-16) and the
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
`config_json` and `exclude`. `exclude` lists titles the host will reject because
they are already shown or were dismissed, so returning them wastes a slot. The
host asks for 24 items and shows the first 12 that survive.

Return an `Err` string when the fill fails, and an empty list when you have
nothing to suggest. An empty list keeps whatever the shelf held.

## 3. What the host does with the result

The host treats every returned title as untrusted. For each one it:

- Resolves the TMDB id first. A TVDB id is used only for a TV show. A title
  with only an IMDb id is dropped.
- Drops a title that does not resolve, that is already in the library, that
  someone has requested, that this user dismissed, or that the user's
  restrictions do not allow. Repeats are dropped too.
- Collapses the reason to one line and clips it to 140 characters.
- Resolves at most 48 candidates per fill, four times the 12 the rail shows,
  taken in your order.

The host takes the title, year and poster from its own metadata, never from
the plugin. When fewer than three titles survive, the host keeps the previous
list and counts the fill as done.

## 4. When it runs

A fill runs when a user opens Home and the shelf is stale. A shelf is stale
when it has never been filled, when `ttl_seconds` has passed since the last
fill, or when an event listed in `refresh_on` fired for that user. An event
makes the shelf stale no sooner than one hour after the last fill, so a busy
user does not trigger a fill per event.

When a fill fails, the host waits one hour before asking again, then six hours,
then the full `ttl_seconds`. A shelf with a shorter TTL never waits longer than
its TTL. The host shows the previous list while it waits.

Fills run on their own queue with two slots. At most two fills run at once, and
each may spend up to two minutes. For a plugin that calls a language model,
that is up to two minutes of model calls per fill. Operators see this cost, so
keep `ttl_seconds` generous.

## 5. What a fill may do

A fill acts as the shelf's user and can only read:

- `search`, with `data:search`.
- `data-list`, with `data:read`. Results are scoped to the shelf's user, the
  same projections that user would see.
- `data-read`, with `data:read`. It returns a media item by id and does not
  apply the user's restrictions.
- `http-request`, with `net:http`. A fill gets the same outbound budget as a
  page call.
- `kv-get`, `kv-set` and the other KV functions, with `state:kv`. Keys are
  yours, so use per-user keys such as `user/<user_id>/seen`.

Every function that changes the user's data is refused during a fill, because
nobody is present to approve a change. Each returns `denied`, whatever the
plugin has been granted. Two groups are refused:

- The functions that return a `write-outcome`: `media-add`,
  `collection-create`, `collection-update`, `collection-add-items`,
  `collection-remove-items`, `mark-watched-state` and `add-favorite`.
- The sync writes: `ensure-watched`, `set-watch-state` and `ensure-favorite`.

A plugin's own KV store is not user data and stays writable.

## Limits

- A fill has 120 seconds. A slow guest is stopped and the fill counts as failed.
- A plugin declares at most four shelves, each key unique within the plugin.
- Shelves are per user and appear on Home only.

## What users see

Home shows one "Picked for you" entry in Customize Home that turns on every
home shelf. People who customised their Home before the plugin arrived must
tick it once. Each card has a "Not interested" button. A dismissed title never
returns to that shelf for that user.

Disabling the plugin hides its shelves and keeps their contents, so enabling it
again costs no new fill. Revoking or removing the plugin deletes its shelves,
items and dismissals.

## Try it

Build the guest and sideload it as in
[Test and iterate](test-and-iterate.md). The fixture used by Mydia's own tests,
`test/support/fixtures/plugins/shelf_fixture`, fills a shelf in a few lines.
