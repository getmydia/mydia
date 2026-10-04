# Events

Events a plugin can subscribe to by listing them under `events:subscribe` in
the `capabilities` of its [manifest](manifest.md). The
[`events:subscribe`](capabilities.md#eventssubscribe) capability is what grants
the subscription. A subscription may only name events from the catalog below;
any other name is rejected when the manifest is parsed.

## Event envelope

The host hands `on-event` a typed `event` record:

| Field | Type | Notes |
|-------|------|-------|
| `event` | `string` | The event name, such as `media_item.added`. |
| `category` | `option<string>` | `media`, `downloads` or `playback`. |
| `severity` | `option<string>` | `info` or `error` when the event sets one. |
| `actor-type` | `option<string>` | `user`, `system` or `job`. |
| `actor-id` | `option<string>` | The user id, or the name of the job or system actor. |
| `resource-type` | `option<string>` | What the event concerns: `media_item`, `episode` or `download`. |
| `resource-id` | `option<string>` | The id of that resource. |
| `metadata-json` | `string` | A JSON object string with two keys, `metadata` and `config`. |

`metadata-json` decodes to `{"metadata": {...}, "config": {...}}`. The
per-event fields in the tables below live under `metadata`. `config` is the
operator's settings for the instance receiving the call. Both are `{}` when
empty.

<!-- source: native/mydia_plugin_sdk/wit/plugin.wit:58-70; lib/mydia/plugins.ex:319-330; lib/mydia/plugins/host.ex:635-647; lib/mydia/plugins/dispatcher.ex -->

## Delivery rules

- The host delivers an event to every enabled instance of each plugin that
  subscribed to it.
- Events are delivered after they are recorded, off the request that caused
  them. A slow or failing plugin never delays other plugins or the action.
- The dispatcher never delivers an event back to the plugin that caused it. An
  event whose `origin` is `plugin:<slug>` or `plugin:<slug>:<instance-id>` is
  withheld from every instance of `<slug>`, so write-backs do not echo.
- Every `playback.*` event carries an `origin` in `metadata`: `player` for a
  real client, `sync:<provider>` for a media-server or Trakt import, or
  `plugin:<slug>[:<instance-id>]` for a plugin write-back.
- An event named in a shelf's `refresh_on` also marks that shelf stale for the
  user the event belongs to. See [Fill a shelf](../how-to/shelves.md).

<!-- source: lib/mydia/plugins/dispatcher.ex:40-95 -->

## Event catalog

| Event | Fires when | Payload | Since |
|---|---|---|---|
| [`media_item.added`](#media_itemadded) | A movie or show is added to the library. | `title`, `media_type`, `year`, `tmdb_id` | 0.12.0 |
| [`media_item.updated`](#media_itemupdated) | A library item's data changes, for example a metadata refresh. | `title`, `media_type`, `reason`, optional `changes` | 0.12.0 |
| [`media_item.removed`](#media_itemremoved) | A library item is removed. | `title`, `media_type` | 0.12.0 |
| [`media_file.imported`](#media_fileimported) | A media file is imported for an item. | `file_path`, `resolution`, `codec`, `size`, `media_title`, `media_type` | 0.12.0 |
| [`download.completed`](#downloadcompleted) | A download finishes. | `title`, `download_client`, `download_id`, optional media context | 0.12.0 |
| [`download.failed`](#downloadfailed) | A download fails. | `title`, `download_client`, `download_id`, `error_message`, optional media context and failure classification | 0.12.0 |
| [`playback.started`](#playbackstarted) | A user starts a streaming session. | `media_item_id` or `episode_id`, `origin` | 0.12.0 |
| [`playback.progressed`](#playbackprogressed) | A progress write crosses a 5% completion bucket. | Playback fields | 0.12.0 |
| [`playback.paused`](#playbackpaused) | Reserved. Nothing emits it yet. | Playback fields | 0.12.0 |
| [`playback.finished`](#playbackfinished) | An item goes from unwatched to watched. | Playback fields | 0.12.0 |
| [`playback.unwatched`](#playbackunwatched) | A user's progress for an item is deleted. | Playback fields | 0.13.2 |

"Since" is the first Mydia release whose manifest catalog accepts the event.
"Playback fields" are listed under [Playback events](#playback-events).

<!-- source: lib/mydia/plugins/manifest.ex:155-167; first-release column from git history of that list (commits debce4d8e, b2c963ff6, 7af8f7c1c) -->

### media_item.added

Recorded with category `media`, resource type `media_item`.

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | The item's title. |
| `media_type` | string | `movie` or `tv_show`. |
| `year` | integer or null | Release year. |
| `tmdb_id` | integer or null | TMDB id. |

<!-- source: lib/mydia/events.ex:387-402 -->

### media_item.updated

Recorded with category `media`, resource type `media_item`.

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | The item's title. |
| `media_type` | string | `movie` or `tv_show`. |
| `reason` | string | Why it changed, such as `Metadata refreshed`. Free text. |
| `changes` | object | Present only when the caller recorded what changed. Keys are field names; each value is an `{old, new}` object, or a list of `{field, old, new}` objects. |

<!-- source: lib/mydia/events.ex:422-441 -->

### media_item.removed

Recorded with category `media`, resource type `media_item`.

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | The item's title. |
| `media_type` | string | `movie` or `tv_show`. |

<!-- source: lib/mydia/events.ex:489-503 -->

### media_file.imported

Recorded with category `media`, resource type `media_item`, resource id the
item the file belongs to.

| Field | Type | Notes |
|-------|------|-------|
| `file_path` | string | The file's base name only, never the directory. `unknown` when the file has no relative path. |
| `resolution` | string or null | For example `1080p`. |
| `codec` | string or null | Video codec. |
| `size` | integer or null | Size in bytes. |
| `media_title` | string | Title of the item the file belongs to. |
| `media_type` | string | `movie` or `tv_show`. |

<!-- source: lib/mydia/events.ex:546-565 -->

### download.completed

Recorded with category `downloads`, severity `info`, actor `system` named
`download_monitor`. The resource is the media item when the download is linked
to one (type `media_item`), otherwise the download itself (type `download`).

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | The release title. |
| `download_client` | string | The client that ran the download. |
| `download_id` | string | The download's id. |
| `media_item_id` | string | Only when the download is linked to an item. |
| `media_title` | string | Only when linked. |
| `media_type` | string | Only when linked. |

<!-- source: lib/mydia/events.ex:969-998,1414-1422 -->

### download.failed

Recorded like `download.completed`, with severity `error`.

| Field | Type | Notes |
|-------|------|-------|
| `title` | string | The release title. |
| `download_client` | string | The client that ran the download. |
| `download_id` | string | The download's id. |
| `error_message` | string | Why it failed. |
| `media_item_id`, `media_title`, `media_type` | string | Only when the download is linked to an item. |
| `failure_category`, `failure_detail` | string | Only when the download client reported a reason. |

<!-- source: lib/mydia/events.ex:1013-1044,1414-1442 -->

## Playback events

All five `playback.*` events share one envelope. Category is `playback`, actor
type is `user` and `actor-id` is the user's id. The resource is a movie
(`media_item`, with `media_item_id` in `metadata`) or an episode (`episode`,
with `episode_id` in `metadata`).

The events other than `playback.started` carry these `metadata` fields, copied
from the user's progress row:

| Field | Type | Notes |
|-------|------|-------|
| `media_item_id` or `episode_id` | string | Which one is present follows the resource type. |
| `position_seconds` | integer or null | Resume position. |
| `duration_seconds` | integer or null | Runtime when known. |
| `completion_percentage` | number or null | 0 to 100. |
| `watched` | boolean | The row's watched flag. |
| `origin` | string | See [Delivery rules](#delivery-rules). |

<!-- source: lib/mydia/events.ex:1918-1937; lib/mydia/playback.ex:694-702 -->

### playback.started

Fires when a user starts a streaming session. `metadata` holds only the id and
`origin` (always `player`), none of the progress fields.

<!-- source: lib/mydia/streaming.ex:153-168; lib/mydia_web/schema/resolvers/streaming_resolver.ex:448 -->

### playback.progressed

Sampled. A progress write emits this only when its completion percentage moves
into a different 5% bucket, so a burst of position updates yields one event. A
write that also crosses to watched emits `playback.finished` instead.

<!-- source: lib/mydia/playback.ex:15-19,659-692 -->

### playback.paused

In the catalog so a manifest can name it, but the host never emits it today.
There is no player pause signal.

<!-- source: lib/mydia/plugins/manifest.ex:164; no emitter found under lib/ (events.ex only validates the action name at :1898) -->

### playback.finished

Fires on the unwatched-to-watched edge only: the 90% auto-mark, an explicit
mark-watched, or a sync write. Re-marking an already-watched item emits
nothing.

<!-- source: lib/mydia/playback.ex:205-221,659-692 -->

### playback.unwatched

Fires when a user's progress row for an item is deleted, which is what marking
an item unwatched does. The event is recorded after the row is gone and
carries the deleted row's fields, so `watched` is typically `true` and
`position_seconds` is the position that was cleared. `origin` is `player`
unless the caller passes one: a plugin's `set-watch-state`, a plugin page's
`mark-watched-state` and a media-server sync pass their own tag, so a plugin
does not receive its own unwatch back.

Hiding a title from Continue Watching does not emit it. Marking a whole season
unwatched emits one event per episode that had progress.

<!-- source: lib/mydia/playback.ex:300-325 (emission at 316), 340-370, 470-500; callers: lib/mydia/plugins/host_functions.ex:1342, lib/mydia/plugins/page_writes.ex:490, lib/mydia/watch_sync/engine.ex:252,281 -->
