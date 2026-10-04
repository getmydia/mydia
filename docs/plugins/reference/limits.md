# Limits

Every number a plugin author or operator can hit, with its default and where it
comes from. Operator-tunable values name their configuration key. They live in
the `plugins:` block of the YAML config, described in the
[configuration reference](../../using/reference/configuration.md). The
configuration reference documents `setup_timeout_ms`, `store_max_keys` and
`store_max_bytes`. The other keys in the tables below are read from the same
block.

## Runtime

| Limit | Default | Configuration key | Notes |
|-------|---------|-------------------|-------|
| Timeout, `on-event` and `check-health` | 5000 ms | `plugins.invocation_timeout_ms` | Wall clock. The call is killed when it expires. |
| Timeout, `on-schedule` | 60000 ms | `plugins.schedule_timeout_ms` | Checkpoint progress to the store as you go. |
| Timeout, `setup` | 30000 ms | `plugins.setup_timeout_ms` | One setup step. |
| Timeout, `on-http` and `fill-shelf` | 120000 ms | `plugins.page_timeout_ms` | A page call ends with 504, a failed fill is recorded as an error. |
| Schedule interval | 5 minutes minimum | none | The manifest's `schedule` may not ask for less. |
| Pool size | 4 | `plugins.pool_size` | Guests running at once, per plugin. |
| Page slots | `pool_size - 1`, at least 1 | none | Concurrent page calls per plugin, so one worker stays free for events and schedules. |
| Page slot wait | 2000 ms | none | After that the page answers 503 with `Retry-After: 2`. |
| Memory | 64 MiB (67,108,864 bytes) | `plugins.memory_limit_bytes` | Enforced when the guest is instantiated: a guest whose minimum memory exceeds it is refused. It does not stop a guest from growing past it at runtime. |
| CPU | none | none | There is no fuel metering for components. The wall-clock timeout is the only guard. |

Each call runs in a fresh component instance, so a guest never keeps memory
between calls.

<!-- source: lib/mydia/config/schema.ex:271-298; lib/mydia/plugins/host.ex:22-47,353-391,985-996,139; lib/mydia_web/controllers/plugin_page_controller.ex:28 -->

## Storage

The `state:kv` store is per plugin instance.

| Limit | Value | Configuration key | Notes |
|-------|-------|-------------------|-------|
| Keys per instance | 1,000,000 | `plugins.store_max_keys` | |
| Bytes per instance | 268,435,456 (256 MiB) | `plugins.store_max_bytes` | Sum of key and value bytes over every row. |
| Value size | 64 KiB | none | Fixed. |
| Key size | 512 bytes | none | Fixed. An empty key is rejected. |
| `kv-set-many` batch | 500 entries | none | All or nothing. |
| `kv-list` page | 200 entries | none | In key order, with an opaque cursor. |

A write past a quota returns `denied`. A batch over 500 entries returns
`invalid-request`.

The host sweeps keys under `link/<link-id>/` and the older spelling
`conn/<link-id>/` when that account link is deleted. Every other key is opaque
to the host.

<!-- source: lib/mydia/plugins/kv.ex:7-25,44-47,161-166,189-210; lib/mydia/config/schema.ex:283-286 -->

## Network

| Limit | Event, schedule and setup calls | Page and shelf calls |
|-------|---------------------------------|----------------------|
| `http-request` response size | 1 MiB (1,048,576 bytes) | 4 MiB (4,194,304 bytes) |
| `http-request` timeout | 5 s | `plugins.page_http_timeout_ms`, default 90000 ms |

An outbound request is allowed only to a host in `net:http`. See
[capabilities](capabilities.md#nethttp).

<!-- source: lib/mydia/plugins/net/gate.ex:57-58,333; lib/mydia/plugins/host_functions.ex:448-452,720-733; lib/mydia/config/schema.ex:289-292 -->

## Data reads

| Limit | Value | Notes |
|-------|-------|-------|
| `data-list` page size | 200 | A larger or missing `limit` is clamped to 200. Cursors are opaque and last only for one run. |
| `watch_history` page size | 50 maximum, 20 default | No cursor. Page-only namespace. |
| `propose-accounts` | 500 accounts per call | A longer list is refused. |
| `propose-accounts` account `name` | 200 characters | Longer names are clipped. |
| `search` `limit` | 25 maximum, 10 default | A larger value is clamped to 25. A missing or non-positive value is 10. |
| `search`, catalog results | 3 provider pages | Paging stops after three pages even if `limit` is not reached. |
| `set-link-token` token | 1 to 4096 bytes | An empty or longer token is refused, as is one with control characters. |
| `report-sync-run` `message` | 500 characters | Longer messages are clipped. |

<!-- source: lib/mydia/plugins/host_functions.ex:82,1034-1035,1489,1526; native/mydia_plugin_sdk/wit/plugin.wit:125-129; lib/mydia/plugins/page_reads.ex:37-41,239-256,287-288; lib/mydia/plugins/host_functions.ex:1509 (name clip), 1550 (token size), 1231 (message clip) -->

## Packages

| Limit | Value | Notes |
|-------|-------|-------|
| Package download | 32 MiB (33,554,432 bytes) | The `.wasm` fetched from an index or remote source. |

<!-- source: lib/mydia/plugins/index.ex:66,257 -->

## Pages

| Limit | Value | Notes |
|-------|-------|-------|
| Request body | 1 MiB | Over the limit answers 413. Bodies must be UTF-8 text, otherwise 415. |
| Forwarded request headers | `content-type`, `accept`, `accept-language` | |
| Response headers kept | `content-type` only | The host sets the security headers. |
| Invalid response | 502 | |
| Timeout | 504 | `plugins.page_timeout_ms`. |
| No free page slot | 503 with `Retry-After: 2` | See [Runtime](#runtime). |

The security headers and the rest of the page contract are in
[Serve a page](../how-to/pages.md#what-the-host-sets).

<!-- source: lib/mydia_web/controllers/plugin_page_controller.ex:24-28,92-100,137 -->

## Shelves

| Limit | Value | Notes |
|-------|-------|-------|
| Shelves per plugin | 4 | Keys are unique within the plugin. |
| Shelf key | 1 to 32 characters, `a-z`, `0-9`, `_`, starting with a letter | |
| Shelf title | 1 to 40 characters | |
| `ttl_seconds` | 3,600 to 2,592,000 (1 hour to 30 days) | |
| `placement` and `scope` | `home` and `user` | The only values accepted. |
| `limit` handed to `fill-shelf` | 24 | The rail shows 12. |
| Candidates resolved per fill | 48 | Four times the 12 shown, taken in the order returned. |
| Candidate resolution | 6 at once, 10 s each | A title that takes longer is dropped. |
| Titles that must survive | 3 | Fewer keeps the previous list and counts the fill as done. |
| `reason` | 140 characters | Collapsed to one line, then clipped. |
| Stored last error | 500 characters | |
| Refresh after an event | At least 1 hour after the last fill | An event marks the shelf stale; it never forces a fill sooner. |
| Backoff after a failed fill | 1 hour, then 6 hours, then the TTL | Never longer than the shelf's TTL. |
| Fill queue | 2 fills at once | Fills for different users run independently. |
| Fill timeout | 120 s | `plugins.page_timeout_ms`. |

<!-- source: lib/mydia/plugins/manifest.ex:199-208,768-852; lib/mydia/plugins/shelves.ex:39-45,208,256,320-333; lib/mydia/plugins/shelves/verifier.ex:27-35,57,84,98; config/config.exs:281; lib/mydia/plugins/host.ex:995 -->
