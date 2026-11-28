# Fatal Health Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Show admins a sidebar banner and a home-page card when Mydia has stopped doing core work (built-in client blocked or low on disk, every download client or indexer down, a library root missing).

**Architecture:** A pure `Evaluator` turns per-condition observations plus timestamps into a debounced alert list (10 min to raise, 5 min clear to drop). An `Observations` module reads the already-cached health sources. A GenServer runs both every minute and on built-in status changes, and broadcasts on `"health:alerts"`. The `:load_navigation_data` on_mount hook assigns and live-updates `@health_alerts` for admins; `Layouts.app` and the dashboard render from it.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Phoenix.PubSub, daisyUI 5, gettext.

**Spec:** `design/specs/2026-11-27-fatal-health-alerts-design.md`

## Global Constraints

- Raise after a condition has failed for **10 minutes**; drop after it has been clear for **5 minutes**; a re-failure inside the clear window keeps the original `since`.
- Admins only: `Authorization.has_role?(user, :admin)`. Non-admins get `[]` and no subscription.
- No network calls from the alerts path. Only cached health (`ClientHealth.status_map/0`, `Indexers.Health.status_map/0`, `CardigannSummary.status_map/0`), `BuiltIn.Status.get/0`, and `File.dir?/1` on local library roots.
- `:unknown` and `:disabled` never count as down. Zero enabled clients/indexers is not fatal.
- S3 library roots (`Mydia.Storage.s3?/1`) and `disabled: true` library paths are skipped.
- A raising observation source is treated as clear for that tick and logged at most once per hour per source.
- `Alerts.current/0` returns `[]` when the process is not running (test, startup).
- GenServer started only when `Application.get_env(:mydia, :start_health_monitors, true)`, like `ClientHealth`.
- PubSub topic `"health:alerts"`, message `{:health_alerts, [Alert.t()]}`. Broadcast only when the set of alert keys changes.
- Fix links: `/admin/clients`, `/admin/indexers`, `/admin/library-paths`. Multi-alert sidebar banner links to `/`.
- DOM ids: `sidebar-health-alert`, `home-health-alerts`, `home-health-alert-<n>` per row.
- All UI strings through gettext. No em dashes in copy. Fictional names only in tests.
- Commits via plain `git commit -F <msgfile>` inside the worktree (hooks installed); verify each with `git show --stat`.

## Review Focus

1. **Built-in client disabled** (`BuiltIn.Status` process absent): no alert, no crash. Test in Task 2.
2. **Startup**: built-in is `:connecting` / engine `:starting` for the first minutes after boot; must not alert before 10 min. Covered by Evaluator timing (Task 1) plus "connecting counts as failing" (Task 2).
3. **Built-in is the only client and is blocked**: exactly one alert (`:built_in_blocked`), not two. Test in Task 2.
4. **All clients `:unknown`** (checks not yet run after boot): not fatal. Test in Task 2.
5. **Non-admin user**: sees no banner and is never subscribed. Test in Task 4.

---

## File Structure

- Create `lib/mydia/health/alert.ex`: the `Alert` struct.
- Create `lib/mydia/health/alerts/evaluator.ex`: pure debounce logic.
- Create `lib/mydia/health/alerts/observations.ex`: reads sources and returns `%{key => nil | observation}`.
- Create `lib/mydia/health/alerts.ex`: GenServer and public API.
- Modify `lib/mydia/application.ex`: start it, gated.
- Modify `lib/mydia_web/live/user_auth.ex`: assign, subscribe, hook.
- Modify `lib/mydia_web/components/layouts.ex`: attr and sidebar slot.
- Modify `lib/mydia_web/components/sidebar_components.ex`: `health_alert_banner/1`.
- Modify `lib/mydia_web/live/dashboard_live/health_components.ex` and `index.html.heex`: the home card.
- Tests under `test/mydia/health/alerts/` and `test/mydia_web/live/health_alerts_test.exs`.

---

### Task 1: Alert struct and Evaluator

**Files:**
- Create: `lib/mydia/health/alert.ex`, `lib/mydia/health/alerts/evaluator.ex`
- Test: `test/mydia/health/alerts/evaluator_test.exs`

**Interfaces:**
- Produces:
  - `%Mydia.Health.Alert{key: term(), title: String.t(), detail: String.t() | nil, since: DateTime.t(), fix_path: String.t()}` (`@enforce_keys [:key, :title, :since, :fix_path]`).
  - `Mydia.Health.Alerts.Evaluator.evaluate(observations :: %{term() => nil | %{title: String.t(), detail: String.t() | nil, fix_path: String.t()}}, state :: map(), now :: DateTime.t()) :: {[Alert.t()], map()}`. `state` starts as `%{}`; per key it stores `%{first_failing_at, last_failing_at, last_observation}`. Alerts are sorted by `since` ascending, then `inspect(key)`.
  - `Evaluator.raise_after_seconds/0` → `600`, `Evaluator.clear_after_seconds/0` → `300`.

- [ ] **Step 1: Write the failing tests** (`async: true`, `t0 = ~U[2026-01-01 00:00:00Z]`, `obs = %{title: "VPN down", detail: "d", fix_path: "/admin/clients"}`, helper `at(min)` = `DateTime.add(t0, min * 60)`)

  - `"does not raise before 10 minutes"`: evaluate `%{vpn: obs}` at 0 and 9 min → `[]` both times.
  - `"raises at 10 minutes with since = first failure"`: at 0, then 10 → one alert, `key: :vpn`, `since: t0`, `title: "VPN down"`.
  - `"a clear shorter than 5 minutes keeps the outage"`: failing 0..10 (alert), `%{vpn: nil}` at 12 → still one alert (`since: t0`); failing again at 14 → alert `since: t0`.
  - `"flapping before the threshold still accumulates"`: fail 0, clear 3, fail 6, clear 8, fail 10 → one alert with `since: t0`.
  - `"clears after 5 minutes clear"`: fail 0..10, clear at 11, evaluate clear at 16 → `[]`, and state has no `:vpn` key.
  - `"a fresh failure after a full clear restarts the clock"`: after the clear above, fail at 17 → `[]`; at 27 → alert `since: at(17)`.
  - `"keys are independent and sorted by since"`: `:a` from 0, `:b` from 2; at 12 → `[:a, :b]` keys in that order.
  - `"uses the latest observation text"`: fail with title "A" at 0, title "B" at 10 → alert title "B".
  - `"a key absent from observations counts as clear"`: fail `%{vpn: obs}` 0..10 (alert), then evaluate `%{}` at 11 and 16 → `[]` at 16.

- [ ] **Step 2: Run to verify failure**

  Run: `./dev mix test test/mydia/health/alerts/evaluator_test.exs`
  Expected: FAIL, `Mydia.Health.Alerts.Evaluator` undefined.

- [ ] **Step 3: Implement `Alert` and `Evaluator.evaluate/3`**

  Per key: a non-nil observation sets `last_failing_at = now`, sets `first_failing_at` if absent, stores the observation. A nil observation drops the key once `now - last_failing_at >= 300s`, else keeps it. A key is alerted when `now - first_failing_at >= 600s` and it has an entry; the alert uses `last_observation`. (So during a short clear the alert stays, per spec.)

- [ ] **Step 4: Run to verify pass** (same command, expected: all pass)

- [ ] **Step 5: Commit** `feat(health): debounce fatal conditions into alerts`

---

### Task 2: Observations

**Files:**
- Create: `lib/mydia/health/alerts/observations.ex`
- Test: `test/mydia/health/alerts/observations_test.exs` (`use Mydia.DataCase`)

**Interfaces:**
- Consumes: observation map shape from Task 1.
- Produces: `Mydia.Health.Alerts.Observations.gather(sources \\ default_sources()) :: %{term() => nil | observation}`, where `sources` is a keyword list of zero-arity funs so tests inject data:
  - `built_in_status: (-> %BuiltIn.Status{} | nil)`: default reads `BuiltIn.Status.get/0` if `Process.whereis(BuiltIn.Status)`, else `nil`.
  - `client_status: (-> map())`: default `ClientHealth.status_map/0`.
  - `indexer_status: (-> map())`: default `Map.merge(Indexers.Health.status_map(), CardigannSummary.status_map())`.
  - `library_paths: (-> [LibraryPath.t()])`: default `Settings.list_library_paths()`.
  - `dir?: (String.t() -> boolean())`: default `&File.dir?/1`.
- Keys returned (always present, `nil` when clear): `:built_in_blocked`, `:built_in_low_disk`, `:all_download_clients_down`, `:all_indexers_down`, plus `{:library_root_missing, id}` only for failing roots (an absent key reads as clear to the Evaluator).
- Copy: `lib/mydia` has no gettext, so observation `title`s are English fallbacks and the web layer translates titles by key (Task 4). `detail` for `:built_in_blocked` is `BuiltIn.Status.describe(reason)`; for low disk, "Free space is <free>, below the <reserve> reserve. Downloads are paused."; for a missing root, "<path> does not exist or is not a folder."

- [ ] **Step 1: Write the failing tests** with injected sources (build a base keyword list where everything is clear, override per test):

  - `"all clear yields no failing keys"`: every value `nil`.
  - `"built-in VPN down is blocked with the Status description"`: `%Status{vpn: {:down, :vpn_down}}` → `:built_in_blocked` has `detail == Status.describe(:vpn_down)`, `fix_path: "/admin/clients"`. (Pick whatever reason atom `Status.describe/1` has a clause for; check the file.)
  - `"built-in connecting counts as blocked"`: `%Status{vpn: :connecting}` → failing.
  - `"built-in not running is clear"`: `built_in_status: fn -> nil end` → both built-in keys `nil`.
  - `"low disk"`: `%Status{engine: :running, disk: {:low, %{free: "1 GB", reserve: "5 GB"}}}` → `:built_in_low_disk` failing, detail mentions `"1 GB"`.
  - `"all clients unhealthy is fatal"`: two `%{status: :unhealthy}` → failing.
  - `"one healthy client is not fatal"`; `"unknown clients are not fatal"` (`[:unhealthy, :unknown]` → nil); `"no enabled clients is not fatal"` (`%{}` and all-`:disabled` → nil).
  - `"built-in as the only client is reported once"`: built-in blocked and `client_status` holds a single unhealthy entry → `:built_in_blocked` failing, `:all_download_clients_down` nil. Determine "only client" as: exactly one non-disabled entry in `client_status`. With two unhealthy entries both alerts fire.
  - `"all indexers unhealthy is fatal"` including a `"cardigann:x"` key.
  - `"missing local root"`: a path `%LibraryPath{id: "lp1", path: "/nonexistent-root", disabled: false}` with `dir?: fn _ -> false end` → key `{:library_root_missing, "lp1"}` with detail containing the path, `fix_path: "/admin/library-paths"`.
  - `"s3 and disabled roots are skipped"`: `"s3://backend/prefix"` and `disabled: true` paths with `dir?` returning false → no `:library_root_missing` keys.
  - `"a raising source is treated as clear"`: `client_status: fn -> raise "boom" end` → `:all_download_clients_down` nil, other keys still computed. Use `ExUnit.CaptureLog`.

- [ ] **Step 2: Run to verify failure**

  Run: `./dev mix test test/mydia/health/alerts/observations_test.exs`
  Expected: FAIL, module undefined.

- [ ] **Step 3: Implement `gather/1`**

  Wrap each source call in `rescue`/`catch :exit`, logging via a once-per-hour throttle keyed by source name (`:persistent_term` timestamp is fine). `fail?` on a status map: entries with `status in [:healthy, :unhealthy, :unknown]` after rejecting `:disabled`, non-empty, all `:unhealthy` (accept both `%{status: s}` and bare atoms, as `Rollup.from_status_map/1` does).

- [ ] **Step 4: Run to verify pass**

- [ ] **Step 5: Commit** `feat(health): observe fatal conditions from cached health`

---

### Task 3: Alerts GenServer

**Files:**
- Create: `lib/mydia/health/alerts.ex`
- Modify: `lib/mydia/application.ex` (add a gated `health_alerts_children/0` next to `client_health_children/0`, appended after it in the children list so `ClientHealth` and `BuiltIn` start first)
- Test: `test/mydia/health/alerts_test.exs`

**Interfaces:**
- Consumes: `Evaluator.evaluate/3`, `Observations.gather/1`, `BuiltIn.Status.topic/0`.
- Produces:
  - `Mydia.Health.Alerts.start_link(opts)`; opts `:name` (default `__MODULE__`), `:gather` (`(-> observations)`, default `&Observations.gather/0`), `:now` (`(-> DateTime.t())`, default `&DateTime.utc_now/0`), `:interval_ms` (default `60_000`), `:topic` (default `"health:alerts"`).
  - `Alerts.current(server \\ __MODULE__) :: [Alert.t()]`, `[]` if not running (`catch :exit`).
  - `Alerts.subscribe() :: :ok` on `"health:alerts"`; `Alerts.topic/0`.
  - `Alerts.refresh(server \\ __MODULE__) :: :ok` (sync re-evaluate; used by tests).
  - Broadcast `{:health_alerts, alerts}` when the sorted key list differs from the previous one.
  - On `{:built_in_status, _}` from `BuiltIn.Status.topic()`, re-evaluate.

- [ ] **Step 1: Write the failing tests** (`async: true`, unique `:name` and `:topic` per test, `gather` and `now` backed by an `Agent` the test mutates):

  - `"current is empty when not running"`: `Alerts.current(:no_such_server) == []`.
  - `"raises after the threshold and broadcasts once"`: subscribe to the test topic; gather returns failing `:vpn`; now = t0 → `refresh` → `current == []`, no message; now = t0+10 min → `refresh` → one alert, `assert_receive {:health_alerts, [%Alert{key: :vpn}]}`; `refresh` again at +11 → `refute_receive {:health_alerts, _}`.
  - `"broadcasts the empty list when cleared"`: continue to clear for 5 min → `assert_receive {:health_alerts, []}`.
  - `"re-evaluates on built-in status broadcast"`: start with `interval_ms: :timer.hours(1)`, failing since t0, now at +10; `Phoenix.PubSub.broadcast(Mydia.PubSub, BuiltIn.Status.topic(), {:built_in_status, %BuiltIn.Status{}})` → `assert_receive {:health_alerts, [_]}`. (Subscribe to the real built-in topic only from a test that is `async: false`, or make the built-in topic an opt `:built_in_topic` and pass a unique one; prefer the opt.)

- [ ] **Step 2: Run to verify failure**

  Run: `./dev mix test test/mydia/health/alerts_test.exs`

- [ ] **Step 3: Implement the GenServer and application wiring**

  `init` subscribes to the built-in topic and `send(self(), :tick)`; `:tick` evaluates then `Process.send_after(self(), :tick, interval_ms)`.

- [ ] **Step 4: Run to verify pass**, then `./dev mix compile --warnings-as-errors`.

- [ ] **Step 5: Commit** `feat(health): run fatal alerts on a timer and broadcast changes`

---

### Task 4: Sidebar banner via the navigation hook

**Files:**
- Modify: `lib/mydia_web/live/user_auth.ex` (`on_mount(:load_navigation_data, ...)`)
- Modify: `lib/mydia_web/components/layouts.ex` (attr `:health_alerts, :list, default: []`; render between `#sidebar-brand` and `<nav>`)
- Modify: `lib/mydia_web/components/sidebar_components.ex` (`health_alert_banner/1`)
- Create: `lib/mydia_web/health_alert_text.ex` (`MydiaWeb.HealthAlertText`)
- Test: `test/mydia_web/live/health_alerts_test.exs`

**Interfaces:**
- Consumes: `Alerts.current/0`, `Alerts.subscribe/0`, `%Alert{}`.
- Produces:
  - `@health_alerts` assign on every LiveView using `:load_navigation_data` (all 42 templates spread `{assigns}` into `Layouts.app`, so no per-page edits).
  - `MydiaWeb.HealthAlertText.title(Alert.t()) :: String.t()` (gettext per key: `:built_in_blocked` → "Downloads stopped: the built-in client is blocked", `:built_in_low_disk` → "Downloads paused: low disk space", `:all_download_clients_down` → "Every download client is unreachable", `:all_indexers_down` → "Every indexer is failing", `{:library_root_missing, _}` → "A library folder is missing"); `duration(Alert.t(), DateTime.t()) :: String.t()` ("for 12m", "for 3h", "for 2d").
  - `health_alert_banner(assigns)`: attrs `alerts :: list` (required), `now :: DateTime.t()` (default `DateTime.utc_now()`). Renders nothing for `[]`.

- [ ] **Step 1: Write the failing tests** (`MydiaWeb.ConnCase`; `alert = %Alert{key: :built_in_blocked, title: "x", detail: "The VPN tunnel is down.", since: DateTime.add(DateTime.utc_now(), -3, :hour), fix_path: "/admin/clients"}`)

  - `"admin sees the sidebar banner after a broadcast"`: admin conn, `live(conn, ~p"/")`, `refute has_element?(view, "#sidebar-health-alert")`; `Phoenix.PubSub.broadcast(Mydia.PubSub, Alerts.topic(), {:health_alerts, [alert]})`; `assert has_element?(view, "#sidebar-health-alert a[href='/admin/clients']")` and text includes "for 3h".
  - `"several alerts link home with a count"`: two alerts → `#sidebar-health-alert a[href='/']` with "2".
  - `"an empty broadcast removes the banner"`.
  - `"non-admin never sees it"`: `user_fixture(%{role: "user"})`, broadcast → `refute has_element?(view, "#sidebar-health-alert")`.
  - `HealthAlertText` unit tests for `duration/2` at 59s ("for 1m" minimum), 12 min, 3 h, 49 h.

- [ ] **Step 2: Run to verify failure**

  Run: `./dev mix test test/mydia_web/live/health_alerts_test.exs`

- [ ] **Step 3: Implement**

  In `on_mount`: `admin? = Authorization.has_role?(socket.assigns[:current_user], :admin)`; assign `:health_alerts` to `if admin?, do: Alerts.current(), else: []`; when `admin? and connected?(socket)`, `Alerts.subscribe()` and `attach_hook(:health_alerts_hook, :handle_info, ...)` that halts on `{:health_alerts, alerts}` with the new assign and continues otherwise. The banner renders inside `Layouts.app/1` itself, so the `{assigns}` spread is all the wiring pages need. Banner: daisyUI `alert alert-error` inside a `px-2 pt-3` wrapper, `hero-exclamation-triangle` icon, title + duration, whole block a `<.link navigate>`.

- [ ] **Step 4: Run to verify pass**, plus `./dev mix gettext.extract --merge` if the repo's gettext README requires it (read `lib/mydia_web/gettext/README.md` first).

- [ ] **Step 5: Commit** `feat(web): show fatal health alerts in the sidebar`

---

### Task 5: Home dashboard card

**Files:**
- Modify: `lib/mydia_web/live/dashboard_live/health_components.ex` (add `fatal_alerts_card/1`)
- Modify: `lib/mydia_web/live/dashboard_live/index.html.heex` (render it right after the header block, before widgets)
- Test: extend `test/mydia_web/live/health_alerts_test.exs`

**Interfaces:**
- Consumes: `@health_alerts`, `HealthAlertText.title/1`, `duration/2`.
- Produces: `fatal_alerts_card(assigns)` with attr `alerts :: list` (required); renders `#home-health-alerts` only when non-empty; each row `#home-health-alert-<index>` shows title, `detail` (when present), duration, and a `btn btn-sm` "Fix" link to `fix_path`.

- [ ] **Step 1: Write the failing tests**

  - `"admin home shows every alert with its detail and fix link"`: broadcast two alerts → `#home-health-alerts`, `#home-health-alert-0` contains "The VPN tunnel is down.", `#home-health-alert-1 a[href='/admin/library-paths']`.
  - `"home card hidden without alerts"`.
  - `"non-admin home shows no card"`.

- [ ] **Step 2: Run to verify failure** (same file)

- [ ] **Step 3: Implement** with daisyUI `card` + `border-error`, `alert-error` header line, list rows.

- [ ] **Step 4: Run to verify pass**, then the dashboard suite: `./dev mix test test/mydia_web/live/dashboard_live`

- [ ] **Step 5: Commit** `feat(web): list fatal health alerts on the home dashboard`

---

### Task 6: Verify in the real app and finish

- [ ] **Step 1:** `./dev mix precommit` (run in chunks if it exceeds the Bash timeout; see memory note on precommit timing). Expected: clean.
- [ ] **Step 2:** `./dev up -d`, log in as admin (`admin`/`adminadmin`). In Admin, Library Paths add a local path pointing at a folder you then delete (`mkdir` it, add it, `rmdir` it). Wait 10 minutes. Expected: `#sidebar-health-alert` on every page reading "A library folder is missing", and `#home-health-alerts` on `/` naming the path. Screenshot desktop and a 390px-wide mobile viewport. Recreate the folder; within ~6 minutes both disappear. Remove the test library path.
- [ ] **Step 3:** `git show --stat` on each commit; confirm only planned files changed versus `origin/master`.
