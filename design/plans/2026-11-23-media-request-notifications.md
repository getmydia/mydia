# Media Request Notifications Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let an admin get ntfy/Discord/custom-webhook notifications when a user creates a media request or one is approved or rejected, with per-instance control over which events each notifier instance sends.

**Architecture:** `Mydia.MediaRequests` records three new events through `Mydia.Events`. They join the plugin event catalog. A new manifest setting type `events` lets a plugin's instances choose which subscribed events they receive; `Mydia.Plugins.invoke_plugin/2` filters instances through a pure `Mydia.Plugins.EventSelection` module before anything is enqueued. The bundled Webhook Notifier declares the field and formats request events.

**Tech Stack:** Elixir/Phoenix LiveView, Ecto, Oban, Rust (wasm32-wasip2 plugin guest), daisyUI.

**Spec:** `design/specs/2026-11-23-media-request-notifications-design.md`

## Global Constraints

- Event types, exactly: `media_request.created`, `media_request.approved`, `media_request.rejected`. Event category: `requests`.
- Notifier manifest version `1.2.0`; its `events` field default is exactly `["media_item.added", "download.completed"]`.
- Fixtures use invented titles and names only (no real films or shows).
- No em dashes in any prose, docs or comments.
- Run Elixir tests with `./dev mix test <path>`; finish with `./dev mix precommit`.
- Commit from the worktree with `direnv exec . git commit -F <msgfile>` (message file in the scratchpad), one commit per step that says so, then `git show --stat HEAD` to verify nothing was left unstaged. Never `--no-verify`.
- No AI or model attribution in commits.

## Refinements to the spec found while planning

These were settled by reading the code; the executor should not re-litigate them.

1. **Grants need no new code.** `reconcile_bundled/3` → `refresh_bundled_state/3` already replaces a bundled plugin's grant with `effective_grants/2` of the shipped manifest, so the widened `events:subscribe` is granted on upgrade. Task 6 adds a test that pins it.
2. **The `events` setting type is single-instance only.** Multi-instance plugins have no plugin-level settings form (`has_settings` is false for them in `AdminPluginsLive.Index`) and configure instances through plugin-defined setup screens, so an `events` field there would have no UI. Manifest validation rejects an `events` field when `multi_instance` is true.
3. **Seeding happens on the plugin config, not the instance.** Single-instance settings live in `PluginConfig.settings`, are mirrored into the default instance by `Instances.merge_default_settings/2`, and the settings modal reads `config.settings`. New installs are seeded where the config row is first created: `seed_bundled/2` and `persist_install/4` in `lib/mydia/plugins.ex`. An upgrade goes through `reconcile_bundled/3`, which does not seed, so an existing notifier keeps the legacy default.
4. **Env/YAML-declared values may be strings.** `DeclaredSettings` does no type coercion, so `EventSelection` accepts a comma-separated string as well as a list.
5. **Test button.** `Plugins.test_invoke/2` builds its payload with `synthetic_event/1`, which hard-codes a media item. A request-shaped clause is added so "Test" on a request event renders a realistic notification.

## Review Focus

- An env-declared `events` value like `"media_request.created, download.completed"` (string, spaces) must select both events. Test in Task 3.
- A saved selection naming an event the manifest no longer subscribes to (or a forged form value) must be ignored, never delivered and never crash. Tests in Tasks 3 and 5.
- A request whose requester row is gone (`requester` not loaded or nil) must still emit its event, with `requester` absent from metadata. Test in Task 2.
- A request with no `year` must render `Title`, not `Title ()`, in both the activity feed and the notifier. Tests in Tasks 1 and 6.
- Unchecking every chip and saving must store `[]` and stop all deliveries for that instance, not fall back to the default. Tests in Tasks 3 and 5.

---

### Task 1: Request event helpers and presentation

**Files:**
- Modify: `lib/mydia/events.ex` (add helpers after `media_item_removed/3`)
- Modify: `lib/mydia/events/presentation.ex` (entries, `detail/1` clauses, `title_for_type/1`)
- Modify: `lib/mydia_web/live/activity_live/index.ex` (`requests` chip, `chip_label/1`, `category_label/1`)
- Test: `test/mydia/events_test.exs`, `test/mydia/events/presentation_test.exs`

**Interfaces:**
- Produces:
  - `Mydia.Events.media_request_created(%MediaRequest{requester: User.t() | nil}) :: :ok`
  - `Mydia.Events.media_request_approved(%MediaRequest{}, keyword()) :: :ok`, opts `approved_by: User.t() | nil`, `auto: boolean()` (default false)
  - `Mydia.Events.media_request_rejected(%MediaRequest{}, keyword()) :: :ok`, opts `rejected_by: User.t() | nil`
  - `Mydia.Events.Presentation.title_for_type(String.t()) :: String.t()` (entry title, or the humanized fallback for unknown types)

- [ ] **Step 1: Write failing tests**

In `test/mydia/events_test.exs`, a `describe "media request events"` block:

```elixir
test "media_request_created records who asked for what" do
  user = user_fixture(%{username: "quillon", display_name: "Quill Onyx"})
  request = %MediaRequest{id: Ecto.UUID.generate(), title: "The Glass Orchard", year: 2031,
    media_type: "movie", tmdb_id: 900_001, requester_notes: "Director's cut please",
    requester_id: user.id, requester: user}

  assert :ok = Events.media_request_created(request)
  [event] = Events.list_events(type: "media_request.created")
  assert event.category == "requests"
  assert event.actor_type == :user and event.actor_id == user.id
  assert event.resource_type == "media_request" and event.resource_id == request.id
  assert event.metadata == %{"title" => "The Glass Orchard", "year" => 2031,
    "media_type" => "movie", "tmdb_id" => 900_001, "requester" => "Quill Onyx",
    "requester_notes" => "Director's cut please"}
end
```

Plus: `requester` falls back to `username` when `display_name` is nil; `requester` key absent when `request.requester` is nil or `%Ecto.Association.NotLoaded{}`; `media_request_approved(request, approved_by: admin)` sets `actor_id: admin.id`, metadata adds `"approved_by" => <admin name>, "auto" => false`; `media_request_approved(request, auto: true)` has `actor_type: :system`, `actor_id: "auto_approve"`, `"auto" => true`, no `"approved_by"`; `media_request_rejected(request, rejected_by: admin)` adds `"approved_by"` and `"rejection_reason"` from `request.rejection_reason`. Nil-valued metadata keys are omitted (e.g. no `requester_notes`).

In `presentation_test.exs`: `for_event/1` titles are "Requested", "Request approved", "Request rejected"; `detail/1` for created is `"Quill Onyx: The Glass Orchard (2031)"`, and `"The Glass Orchard"` when `year` is nil and requester absent; rejected detail appends ` (reason: <reason>)` when a reason is present; `title_for_type("media_request.created") == "Requested"`.

- [ ] **Step 2: Run to verify failure**

Run: `./dev mix test test/mydia/events_test.exs test/mydia/events/presentation_test.exs`
Expected: FAIL, `UndefinedFunctionError` for `media_request_created/1`.

- [ ] **Step 3: Implement**

Events helpers use `create_event_async/1` like `media_item_added/3`. A private `request_metadata/1` builds the shared keys and a private `person_name/1` returns `display_name || username` for a `%User{}` and nil otherwise; drop nil values with `Map.reject/2`. Presentation entries: created `hero-inbox-arrow-down`/`text-info`, approved `hero-check-circle`/`text-success`, rejected `hero-x-circle`/`text-warning`. Activity chip `%{value: "requests", icon: "hero-inbox-arrow-down", ...}` inserted after `downloads`, `chip_label("requests") -> gettext("Requests")`, `category_label("requests") -> pgettext("event category", "requests")`. Guests never see it because `Visibility.visible_categories/1` filters chips by the guest policy.

- [ ] **Step 4: Run tests to verify pass**

Run: `./dev mix test test/mydia/events_test.exs test/mydia/events/presentation_test.exs test/mydia/events/visibility_test.exs test/mydia_web/live/activity_live`
Expected: PASS. Run `./dev mix gettext.extract --merge` if the gettext catalog check (see `lib/mydia_web/gettext/README.md`) requires it.

- [ ] **Step 5: Commit** `feat(events): media request events and their presentation`

---

### Task 2: Emit request events from MediaRequests

**Files:**
- Modify: `lib/mydia/media_requests.ex` (`create_request/3`, `insert_approval/5`, `reject_request/2`, `auto_approve_matching_requests/2`)
- Test: `test/mydia/media_requests_test.exs`

**Interfaces:**
- Consumes: Task 1 helpers.

- [ ] **Step 1: Write failing tests**

A `describe "events"` block reusing the existing `create_user/1`, `create_request/1`, `stub_tmdb_movie/4`, `relay_config/1` helpers in that file:

- `create_request/3` success → exactly one `media_request.created` event whose `resource_id` is the request id and `metadata["requester"]` is the user's name.
- `create_request/3` returning `{:error, :duplicate_request}` → zero events.
- `approve_request/4` success → one `media_request.approved`, `actor_id == admin.id`, `metadata["approved_by"]` is the admin's name, `metadata["auto"] == false`.
- Approval linked to an existing item (mirror the existing "links the request to an existing media item" test) → one `media_request.approved` for the request, plus one `"auto" => true` event for each sibling pending request auto-approved.
- Approval whose metadata fetch fails (Bypass returns 500) → zero `media_request.approved` events.
- `reject_request/2` success → one `media_request.rejected` with `metadata["rejection_reason"]`; invalid attrs (missing reason) → zero.
- `auto_approve_matching_requests/2` approving two requests → two `media_request.approved` events with `actor_type: :system`.
- `cancel_request/2` → zero request events.
- A request whose requester was deleted (delete the user row after insert, reload the request) and is then rejected → event still recorded, no `"requester"` key.

Count with `Events.list_events(type: t) |> length()`.

- [ ] **Step 2: Run to verify failure**

Run: `./dev mix test test/mydia/media_requests_test.exs`
Expected: new tests FAIL (zero events found).

- [ ] **Step 3: Implement**

Emit only on success and outside the transactions: in `create_request/3` after the preload; in the `{:ok, {updated_request, ...}}` branch of `insert_approval/5`; in the `{:ok, updated_request}` branch of `reject_request/2`; and after `auto_approve_matching_requests/2`'s transaction returns `{:ok, approved_list}`, one `media_request_approved(r, auto: true)` per request. Preload `[:requester, :approved_by]` on the updated request before emitting (`Repo.preload/2`, one query per call is fine; the auto-approve list preloads in one call). `approved_by` for an explicit approval/rejection comes from the preloaded `approved_by` association.

- [ ] **Step 4: Run tests to verify pass**

Run: `./dev mix test test/mydia/media_requests_test.exs test/mydia/media_requests test/mydia_web/live/request` (and any `*request*` LiveView/GraphQL tests found with `ls test/mydia_web/**/*request*`)
Expected: PASS.

- [ ] **Step 5: Commit** `feat(requests): record events when requests are created, approved or rejected`

---

### Task 3: Manifest `events` setting type and EventSelection

**Files:**
- Modify: `lib/mydia/plugins/manifest.ex` (`@event_catalog`, `@setting_types`, `validate_setting_field/1`, schema-level checks, new `event_selection_field/1`)
- Modify: `lib/mydia/plugins/plugin.ex` (new field `event_selection`)
- Create: `lib/mydia/plugins/event_selection.ex`
- Test: `test/mydia/plugins/manifest_test.exs`, create `test/mydia/plugins/event_selection_test.exs`

**Interfaces:**
- Produces:
  - `Manifest.event_selection_field([map()]) :: %{key: String.t(), default: [String.t()] | nil} | nil`
  - `%Plugin{event_selection: %{key: String.t(), default: [String.t()] | nil} | nil}` (default nil), filled by `Plugin.from_manifest/2` from `manifest.settings_schema`
  - `EventSelection.selected(Plugin.t(), map()) :: [String.t()]` (settings map → events the instance receives, always a subset of `plugin.events`)
  - `EventSelection.wants?(Plugin.t(), map(), String.t()) :: boolean()`
  - `EventSelection.seed(map(), map()) :: map()` (manifest map, settings → settings with the field's key set to the full `events:subscribe` list when the manifest declares an `events` field and the key is absent; otherwise unchanged)

- [ ] **Step 1: Write failing tests**

`manifest_test.exs`: the three request types parse in `events:subscribe`; an `events` field parses; `"default"` containing an event outside `events:subscribe` → `{:error, %Error{type: :invalid_manifest}}`; two `events` fields → error; `events` field with `"multi_instance": true` → error; `default` that is not a list of strings → error.

`event_selection_test.exs`, with `plugin = %Plugin{events: ["a.x", "b.y", "c.z"], event_selection: %{key: "events", default: ["a.x"]}}` (use real catalog names in the file; letters here for brevity):
- saved list `["b.y"]` → `["b.y"]`
- key absent → `["a.x"]`
- key absent and `default: nil` → all three
- `[]` → `[]`
- `"b.y, c.z"` (string) → `["b.y", "c.z"]`
- `["b.y", "not.subscribed"]` → `["b.y"]`
- `event_selection: nil` → all three regardless of settings
- `wants?/3` agrees with `selected/2`
- `seed/2` adds the full list only when the key is absent, leaves `[]` and existing lists alone, and is a no-op for a manifest without an `events` field.

- [ ] **Step 2: Run to verify failure**

Run: `./dev mix test test/mydia/plugins/manifest_test.exs test/mydia/plugins/event_selection_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

`@setting_types ~w(string url secret enum text events)`. Field-level: `events` with a non-list or non-string `default` fails. Schema-level checks need `events:subscribe` and `multi_instance`, so run them from `parse/1` after both are known (add a `validate_event_selection(schema, events, multi_instance)` to the existing `with`). `selected/2` is `plugin.events` intersected with the parsed value, preserving `plugin.events` order.

- [ ] **Step 4: Run tests to verify pass**

Run: `./dev mix test test/mydia/plugins/manifest_test.exs test/mydia/plugins/event_selection_test.exs test/mydia/plugins/page_manifest_test.exs test/mydia/plugins/extra_manifests_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit** `feat(plugins): events setting type for per-instance event selection`

---

### Task 4: Filter dispatch, seed new configs, request-shaped test event

**Files:**
- Modify: `lib/mydia/plugins.ex` (`invoke_plugin/2`, `seed_bundled/2`, `persist_install/4`, `synthetic_event/1`)
- Test: `test/mydia/plugins_test.exs`

**Interfaces:**
- Consumes: `EventSelection.wants?/3`, `EventSelection.seed/2` (Task 3).

- [ ] **Step 1: Write failing tests**

- `invoke_plugin/2` with an inline plugin descriptor whose `event_selection` is set and two enabled instances (one with `"events" => ["media_request.created"]`, one with no key): a `media_request.created` event reaches only the first; a `media_item.added` event reaches only the second. Observe via an instance-scoped Host stub the existing `plugins_test.exs` setup uses, or by asserting on `{:ok, results}` length if the existing tests count results.
- An instance with `"events" => []` receives nothing and `invoke_plugin/2` returns `{:ok, []}`.
- `persist_install/4` seeding: installing a catalog entry whose manifest declares an `events` field stores `"events"` as the full subscribed list; reinstalling over an existing row with `"events" => ["a"]` leaves it as `["a"]`. (Bundled seeding is tested in Task 6, once the notifier declares the field.)
- `test_invoke(slug, "media_request.created")` builds a payload with `"resource_type" => "media_request"`, `"category" => "requests"` and metadata containing `"requester"`. Assert on `synthetic_event/1` through `build_payload/1` by making `synthetic_event/1` public as `@doc false`, or capture the Host call the same way existing `test_invoke` tests do.

- [ ] **Step 2: Run to verify failure**

Run: `./dev mix test test/mydia/plugins_test.exs`
Expected: new tests FAIL.

- [ ] **Step 3: Implement**

In `invoke_plugin/2`, filter `Instances.list_enabled(plugin.slug)` with `EventSelection.wants?(plugin, instance.settings || %{}, Map.get(event, :type))`. `seed_bundled/2`: `settings = EventSelection.seed(manifest_map, bundled_settings(raw))` (compute `manifest_map` first). `persist_install/4`: add `settings: EventSelection.seed(manifest_map, %{})` only when the row is new; `upsert_plugin_config/1` updates existing rows, so read `Settings.get_plugin_config_by_slug/1` first and leave an existing row's settings untouched. `synthetic_event("media_request." <> _ = type)`: category `"requests"`, resource_type `"media_request"`, metadata `"title" => "Test Movie", "year" => 2026, "media_type" => "movie", "requester" => "Test User", "requester_notes" => "Sent from the Test button", "approved_by" => "Admin", "rejection_reason" => "Test rejection", "test" => true`.

- [ ] **Step 4: Run tests to verify pass**

Run: `./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/dispatcher_test.exs test/mydia/plugins/notifier_integration_test.exs test/mydia/plugins/notifier`
Expected: PASS.

- [ ] **Step 5: Commit** `feat(plugins): deliver events only to instances that selected them`

---

### Task 5: Settings modal chips

**Files:**
- Modify: `lib/mydia_web/live/admin_plugins_live/index.ex` (`settings_state/1`, `build_settings/2`)
- Modify: `lib/mydia_web/components/plugin_setup_components.ex` (new `settings_field/1` clause)
- Test: `test/mydia_web/live/admin_plugins_live_test.exs` (inside `describe "operator settings + host disclosure (U3, U4)"`)

**Interfaces:**
- Consumes: `EventSelection.selected/2`, `Presentation.title_for_type/1`, `Plugin.event_selection`.
- Produces: an `events` field map carrying `"options" => [{label, value}]` built by `settings_state/1`, so `settings_field/1` needs no plugin context.

- [ ] **Step 1: Write failing tests**

Using a plugin config whose manifest declares an `events` field (reuse the file's manifest-fixture helper; add the field to a copy):
- The modal renders one checkbox per subscribed event: `has_element?(view, "#plugin-settings-form input[type=checkbox][name='events[]'][value='media_request.created']")`.
- With no saved key, exactly the default events are checked.
- Submitting with only `media_request.created` checked stores `["media_request.created"]` in `Settings.get_plugin_config_by_slug(slug).settings["events"]` and in the default instance's settings.
- Submitting with none checked stores `[]`.
- Submitting a forged `events: ["media_request.created", "system.bogus"]` stores `["media_request.created"]`.

- [ ] **Step 2: Run to verify failure**

Run: `./dev mix test test/mydia_web/live/admin_plugins_live_test.exs`
Expected: new tests FAIL.

- [ ] **Step 3: Implement**

`settings_state/1`: for an `events` field, the form value is `EventSelection.selected(plugin_descriptor, current)` (build the descriptor with `Plugin.from_manifest/2` from the parsed stored manifest) and the field gets `"options"` as `{Presentation.title_for_type(t), t}` for each subscribed event. `settings_field/1` `events` clause: a label, a hidden `<input type="hidden" name="events[]" value="">`, and a `<div class="filter">` of `<input type="checkbox" class="btn btn-sm" name={"#{key}[]"} value={v} aria-label={label} checked={v in selected}>` per option, with `id={"setting-#{key}-#{v}"}` (replace `.` with `-`). `build_settings/2`: for an `events` field, take the list, drop `""` and values not in the subscribed list, and store the result (an empty list included).

- [ ] **Step 4: Run tests to verify pass**

Run: `./dev mix test test/mydia_web/live/admin_plugins_live_test.exs test/mydia_web/live/admin_plugins_live test/mydia_web/live/plugin_setup_live`
Expected: PASS.

- [ ] **Step 5: Commit** `feat(admin): choose a plugin's events from its settings modal`

---

### Task 6: Notifier manifest and request formatting

**Files:**
- Modify: `priv/plugins/webhook_notifier.json`
- Modify: `plugins/webhook_notifier/src/lib.rs` (`describe/1`, `process/1`, new `request_text/2`, tests)
- Test: `test/mydia/plugins_test.exs` (bundled reconciliation), `test/mydia/plugins/bundled_manifest_roundtrip_test.exs`, Rust `#[cfg(test)] mod tests`

**Interfaces:**
- Consumes: event metadata keys from Task 1 (`title`, `year`, `requester`, `requester_notes`, `approved_by`, `auto`, `rejection_reason`).
- Produces (Rust): `fn request_text(event_type: &str, metadata: Option<&JsonValue>) -> Option<(String, String)>` returning `(title, body)` for `media_request.*` and `None` otherwise.

- [ ] **Step 1: Write failing tests**

Rust:
- `request_text("media_request.created", ...)` with title "The Glass Orchard", year 2031, requester "Quill Onyx", notes "Director's cut please" → `("The Glass Orchard (2031)", "Quill Onyx requested The Glass Orchard (2031)\n\nDirector's cut please")`.
- Without year → title `"The Glass Orchard"`; without notes → body is the first line only.
- approved → `"Approved The Glass Orchard (2031) for Quill Onyx"`; with `auto: true` → `"Auto-approved ..."`; with no requester → `"Approved The Glass Orchard (2031)"`.
- rejected with reason "Not available in our region" → `"Rejected The Glass Orchard (2031) for Quill Onyx\n\nNot available in our region"`.
- `describe("media_request.created") == "Requested"`, approved "Request approved", rejected "Request rejected".
- `process` with target `ntfy` on a created event yields a request whose `title` header is `The Glass Orchard (2031)` and body starts with `Quill Onyx requested`; with target `custom`, `{{requester}}` in `body_template` renders `Quill Onyx`. Reuse the existing tests' way of intercepting `http_call` if one exists; otherwise test `ntfy_request`/`custom_request` builders directly.

Elixir (`plugins_test.exs`, `describe "ensure_bundled/0 manifest reconciliation"`): a pre-existing bundled `webhook-notifier` row with the 1.1.0 manifest, a grant of `events:subscribe: ["media_item.added", "download.completed"]` and settings `%{"delivery" => "durable", "target" => "ntfy", "webhook_url" => "https://ntfy.example.test/topic"}` → after `ensure_bundled/0`: version `"1.2.0"`, granted `events:subscribe` includes all three request types, `Plugins.needs_reapproval?("webhook-notifier") == false`, and `settings` has no `"events"` key (legacy default applies). A fresh DB → seeded settings `"events"` equals all five subscribed events.

- [ ] **Step 2: Run to verify failure**

Run: `devenv shell -- bash -c 'cd plugins/webhook_notifier && cargo test'` and `./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/bundled_manifest_roundtrip_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement**

Manifest: version `1.2.0`; `events:subscribe` `["media_item.added", "download.completed", "media_request.created", "media_request.approved", "media_request.rejected"]`; first `settings_schema` entry `{"key": "events", "type": "events", "label": "Notify on", "default": ["media_item.added", "download.completed"]}`; description adds "or when someone requests a title"; `body_template` label lists `{{requester}}`, `{{requester_notes}}`, `{{rejection_reason}}`. Guest: in `process/1`, when `request_text` returns `Some((title, body))`, use them for the ntfy title/body and the Discord content/embed in place of `title`/`verb`/`overview`; skip `read_media` (it already returns None for non-`media_item`). The custom target already flattens metadata, so it needs no change beyond `describe/1`.

- [ ] **Step 4: Run tests to verify pass**

Run: `devenv shell -- bash -c 'cd plugins/webhook_notifier && cargo test'`, `devenv shell -- scripts/check-plugins.sh`, `./dev mix compile` (rebuilds the wasm), then `./dev mix test test/mydia/plugins_test.exs test/mydia/plugins/bundled_manifest_roundtrip_test.exs test/mydia/plugins/notifier_integration_test.exs test/mydia/plugins/notifier`
Expected: PASS, clippy clean.

- [ ] **Step 5: Commit** `feat(notifier): notify on media requests, choose events per instance`

---

### Task 7: Docs

**Files:**
- Modify: `docs/plugins/reference/events.md` (catalog table rows and a `### media_request.created|approved|rejected` section each, matching the `media_item.added` section's shape; "since" version is the next minor after the current `mix.exs` version)
- Modify: `docs/plugins/reference/manifest.md` (the `events` setting type: options come from `events:subscribe`, optional `default` subset, single-instance only, at most one per manifest, unsaved instances use `default`, new installs start with every subscribed event)
- Modify: `docs/plugins/how-to/notifications.md` (a section on choosing events per instance and a short ntfy walkthrough for request notifications)

- [ ] **Step 1: Write the docs** (no em dashes; invented titles in examples)
- [ ] **Step 2: Verify** `grep -n "—" docs/plugins/reference/events.md docs/plugins/reference/manifest.md docs/plugins/how-to/notifications.md` prints nothing new, and the docs site build still passes if the repo has a docs check (`ls docs/` for its config; skip if none).
- [ ] **Step 3: Commit** `docs(plugins): request events and the events setting type`

---

### Task 8: Final verification

- [ ] **Step 1:** `./dev mix precommit` (in chunks per `test/README.md` if it outruns the Bash timeout). Expected: no failures, no warnings.
- [ ] **Step 2:** `git diff --stat origin/master...HEAD` lists only files named in this plan plus the spec and plan.
- [ ] **Step 3:** Manually: `./dev up -d`, log in as `admin`, open Admin → Plugins → Webhook Notifier → Settings, confirm the chips show "Added to library" and "Download completed" checked, check "Requested", save, use the Test button with `media_request.created` against a local ntfy topic or a request bin, and confirm the message reads "Test User requested Test Movie (2026)".
