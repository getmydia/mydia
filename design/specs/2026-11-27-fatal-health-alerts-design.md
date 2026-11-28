# Fatal health alerts: sidebar and home banners

## Why

On galactica the built-in torrent client's VPN tunnel flapped between down and
connecting for a long stretch. Mydia logged `VPN down, torrents stopped` every
minute or two and grabs failed, yet nothing in the UI said so outside the
Download Clients admin page. The home dashboard showed it as one unhealthy
client out of two, which reads as a minor blip. The operator found out weeks
late.

Goal: when Mydia has stopped doing its core work (downloading, searching,
importing into the library), an admin sees it on every page within minutes,
and the notice goes away by itself once the cause is fixed.

## Scope

In:

- Five fatal conditions (below), each evaluated from data Mydia already
  caches, plus one new cheap filesystem check.
- A 10-minute grace period before an alert shows, and a 5-minute clear period
  before it goes away, so restarts stay quiet and a flapping outage reads as
  one continuous outage.
- A compact banner in the sidebar on every page, and a detailed card on the
  home dashboard.
- Admins only.

Out:

- Notifications outside the UI (email, push, webhooks).
- Persisted alert history. After a restart the grace clock starts again.
- Dismissing alerts. The banner tracks reality; it clears when the problem
  does.
- Partial degradation (one indexer of five down, one client of three down).
  The existing dashboard health widget already covers that.
- Library roots on S3 storage. Only local paths are checked.

## Conditions

| Key | Fatal when | Source | Fix link |
| --- | --- | --- | --- |
| `:built_in_blocked` | `BuiltIn.Status.blocking_reason/1` is non-nil (VPN down or stuck connecting, settings rejected, apply timeout, engine crashed or stopped, preflight failure such as missing `NET_ADMIN`/TUN) | `Mydia.Downloads.BuiltIn.Status` | `/admin/clients` |
| `:built_in_low_disk` | `Status.disk` is `{:low, _}` (`SpaceGuard` paused downloads) | `BuiltIn.Status` | `/admin/clients` |
| `:all_download_clients_down` | at least one enabled download client, and every one is `:unhealthy` | `ClientHealth.status_map/0` (ETS cache) | `/admin/clients` |
| `:all_indexers_down` | at least one enabled indexer or Cardigann tracker, and every one is `:unhealthy` | `Indexers.Health.status_map/0` merged with `CardigannSummary.status_map/0`, as the dashboard does | `/admin/indexers` |
| `{:library_root_missing, id}` | an enabled, local library path whose root directory does not exist or is not a directory | `Settings` library paths + `File.dir?/1` | `/admin/library-paths` |

Rules:

- `:unknown` and `:disabled` entries never count as down. A rollup that is
  `:checking` is not fatal.
- When the built-in client is not enabled, `BuiltIn.Status` may not be
  running. The evaluator then treats both built-in conditions as clear; it
  never crashes on a missing process.
- `:all_download_clients_down` is suppressed while `:built_in_blocked` is
  raised and the built-in client is the only enabled client. The specific
  alert already says why; two banners for one cause is noise.
- One alert per missing library root, so the detail can name the path.
- A root check that does not answer within 5 seconds (a hung network mount)
  is reported as "not responding" under the same key. Each check runs in its
  own process, and a still-blocked check is reused rather than started again,
  so a hung mount never stalls the watcher or piles up blocked processes.
- The "every download client is down" alert is suppressed only when the one
  enabled client is the built-in client itself, matched by its runtime id.

Each alert carries a human-readable title and detail. The built-in detail
reuses `Status.describe/1`, so the wording matches the Download Clients page
("The VPN tunnel is down. Torrents are stopped until it returns.").

## Architecture

### `Mydia.Health.Alert` (struct)

`key`, `title`, `detail`, `since` (`DateTime`, when the condition was first
observed in this run), `fix_path` (a verified route).

### `Mydia.Health.Alerts.Evaluator` (pure)

`evaluate(observations, tracker_state, now) :: {[Alert.t()], tracker_state}`

- `observations` is a map of condition key to `nil` (clear) or
  `%{title, detail, fix_path}` (failing right now).
- `tracker_state` holds, per key, `first_failing_at` and `last_failing_at`.
- An alert is raised when the condition has been failing, without a clear
  stretch of 5 minutes or more, since at least 10 minutes ago. `since` is
  `first_failing_at`.
- A condition that clears starts the 5-minute clear window. If it fails again
  inside that window, `first_failing_at` is kept, so flapping stays one
  outage. Once it has been clear for 5 minutes, its entry is dropped.
- Both durations are module attributes; tests pass `now` explicitly.

This is the unit that carries the timing logic, and it is tested without
processes or the database.

### `Mydia.Health.Alerts` (GenServer)

- Every 60 seconds it gathers observations (`Observations.gather/0`: the cached
  sources above plus `File.dir?/1` on local roots, no network calls), runs the
  evaluator, and stores the resulting alert list.
- It also subscribes to `BuiltIn.Status.topic/0` and re-evaluates on
  `{:built_in_status, _}`, so a built-in alert can appear exactly at the
  10-minute mark rather than up to a minute later. Re-evaluation is cheap.
- When the alert list changes (an alert appears, clears, or its text
  changes), it broadcasts `{:health_alerts, alerts}` on topic
  `"health:alerts"`. Gathers run one at a time in an unlinked task.
- Public API: `current/0` (reads `:persistent_term`, never the process, so a
  slow gather cannot delay a page mount), `subscribe/0`.
- Each admin LiveView ticks a `health_alerts_now` clock every minute so the
  "for 3h" durations stay current.
- Started in `Mydia.Application`, gated in test like `ClientHealth`. Tests
  drive `Evaluator` directly and start the GenServer under `start_supervised`
  with injected observation functions where needed.

### Web

- `MydiaWeb.Live.UserAuth.on_mount(:load_navigation_data, ...)`: for admins,
  assign `:health_alerts` from `Alerts.current/0` and, when connected,
  subscribe and attach a `handle_info` hook that updates the assign on
  `{:health_alerts, alerts}`. Everyone else gets `[]` and no subscription.
- `Layouts.app` gets an `attr :health_alerts, :list, default: []`.
- New `health_alert_banner` function component in `sidebar_components.ex`,
  rendered between the brand block and the nav:
  - one alert: `alert alert-error` with an icon, the title, the duration
    ("for 3h"), linking to `fix_path`. DOM id `sidebar-health-alert`.
  - several: "N problems need attention", linking to `/`.
  - On mobile the sidebar is a drawer, so the home card is what mobile users
    see first; the banner is still in the drawer.
- Home dashboard (`DashboardLive.Index`, `/`): a `home-health-alerts` card at the top,
  above existing widgets, listing every alert with title, detail, duration and
  a "Fix" button to `fix_path`. Hidden when the list is empty. It reads the
  same `@health_alerts` assign, so it updates live.
- All strings through gettext.

## Error handling

- Each observation source is wrapped: a raise or exit in one source is logged
  (at most once per hour per source) and that condition is treated as clear
  for this tick. A broken health check must never invent a fatal banner or
  crash the layout.
- `Alerts.current/0` returns `[]` if the process is not running, so the
  layout renders normally in test and during startup.

## Testing

- `Evaluator`: raise after 10 minutes and not before; stay raised across a
  short clear; clear after 5 minutes clear; `since` survives flapping; several
  keys independent.
- Observations: built-in blocked vs. not running; low disk; all-clients-down
  with mixed `:unknown`; built-in-only suppression; all-indexers-down
  including Cardigann; missing vs. present local library root; S3 roots
  skipped; a raising source treated as clear.
- LiveView: an admin sees `#sidebar-health-alert` and `#home-health-alerts`
  when alerts exist, and sees them update on broadcast; a non-admin sees
  neither; no alerts renders neither.
