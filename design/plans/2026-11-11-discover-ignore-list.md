# Discover Ignore List Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let each user ignore Discover titles so the browse grid and regional rows stop showing them, with Undo, a persisted "Show ignored" toggle, and Unignore wherever an ignored title still appears.

**Architecture:** A `discover_ignored_titles` table holds one row per user and title, keyed on `(user_id, media_type, provider, provider_id)`. `Mydia.Accounts` exposes idempotent ignore and unignore functions and a `MapSet` loader. Discover loads the set at mount, filters with one shared predicate in `assign_visible_items/1` and `regional_rows`, and keeps its event handlers in a new `MydiaWeb.DiscoverLive.Ignores` module.

**Tech Stack:** Elixir, Phoenix LiveView 1.2, Ecto (SQLite and PostgreSQL), daisyUI 5, gettext.

**Spec:** `design/specs/2026-11-11-discover-ignore-list-design.md`

## Global Constraints

- Migration columns use `:text`, never `:string`. The filename uses a real timestamp, checked for duplicates across every remote branch (the loop in `AGENTS.md`, Git Guidelines).
- The migration must run unchanged on SQLite and PostgreSQL.
- Ignores are per user. Nothing a user ignores may change what another user sees.
- Ignored titles are hidden only from the category grid and regional rows. Search, the recommendations rail and the person modal still show them.
- Media types are `:movie` and `:tv_show` (strings `"movie"`, `"tv_show"`). Providers are `:tmdb` and `:tvdb`. Refs are `Mydia.Metadata.Ref` tuples, wire format `Ref.to_param/1` (`"tmdb:123"`).
- All new user-facing copy goes through gettext. Tests and fixtures use invented titles only, never real ones.
- `index.ex` must not grow by more than the delegation clauses and assigns; new logic goes in `lib/mydia_web/live/discover_live/ignores.ex`.
- Run tests with `./dev mix test <path>`. Commit with `git commit -F <msgfile>` from a shell with direnv loaded, then check `git show --stat`.

## Review Focus

1. **Item `media_type` missing on a grid item.** The template already falls back to `item.media_type || @media_type`; the ignore key must use the same fallback, or an ignored title would never match and stay visible. Pinned in Task 4 (`ignored_key/2` test).
2. **Ignoring the same TMDB id as a movie must not hide the TV show with that id.** Pinned in Task 1 (key separation) and Task 4 (grid test).
3. **A stale toast timer must not clear a newer toast.** Pinned in Task 5 (`:clear_ignore_toast` with an old ref is a no-op).
4. **Anonymous or `current_user`-less sockets.** There is no ignore UI and every ignore event is a no-op, never a crash. Pinned in Task 5.
5. **Restricted users.** An ignore must not undo a restriction filter, and auto-advance must keep both reasons for dropping titles. Pinned in Task 4 (`filtering?/1` still true when restricted with no ignores).

---

### Task 1: Table, schema and Accounts functions

**Files:**
- Create: `priv/repo/migrations/<real timestamp>_create_discover_ignored_titles.exs`
- Create: `lib/mydia/accounts/ignored_discover_title.ex`
- Modify: `lib/mydia/accounts.ex` (alias list near line 18; new public functions after `delete_user/1`)
- Test: `test/mydia/accounts/ignored_discover_titles_test.exs`

**Interfaces:**
- Produces:
  - `Mydia.Accounts.ignore_discover_title(%User{}, Ref.t(), :movie | :tv_show) :: :ok | {:error, Ecto.Changeset.t()}`
  - `Mydia.Accounts.unignore_discover_title(%User{}, Ref.t(), :movie | :tv_show) :: :ok`
  - `Mydia.Accounts.ignored_discover_keys(%User{}) :: MapSet.t({:movie | :tv_show, Ref.t()})`

(The spec sketches `ignore_discover_title(user, %SearchResult{})`. Every caller has only the event's `ref` and `media_type` params, so the plan takes `(user, ref, media_type)` instead, matching `add_to_library`.)

- [ ] **Step 1: Write the failing tests** in `test/mydia/accounts/ignored_discover_titles_test.exs` (`use Mydia.DataCase, async: true`, users from `Mydia.AccountsFixtures.user_fixture/1`):
  - `"ignoring twice keeps one row"`: two `ignore_discover_title(user, {:tmdb, 101}, :movie)` calls both return `:ok`; `Repo.aggregate(IgnoredDiscoverTitle, :count) == 1`.
  - `"unignoring a title that is not ignored is a no-op"`: `unignore_discover_title(user, {:tmdb, 999}, :movie) == :ok`.
  - `"movie and tv_show with the same id are separate keys"`: ignore `{:tmdb, 202}` as `:movie`; `ignored_discover_keys(user) == MapSet.new([{:movie, {:tmdb, 202}}])`, so `{:tv_show, {:tmdb, 202}}` is not a member.
  - `"one user's ignores are invisible to another"`: user A ignores; `ignored_discover_keys(user_b) == MapSet.new()`.
  - `"deleting the user removes their ignores"`: ignore, `Accounts.delete_user(user)`, count is 0.
  - `"tvdb refs round-trip"`: ignore `{:tvdb, 303}` as `:tv_show`; key set contains `{:tv_show, {:tvdb, 303}}`.
  - `"an invalid media type is rejected"`: `IgnoredDiscoverTitle.changeset(%IgnoredDiscoverTitle{}, %{media_type: "episode", provider: "tmdb", provider_id: 1})` is invalid on `:media_type`; likewise `provider: "imdb"` is invalid on `:provider`.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia/accounts/ignored_discover_titles_test.exs`
Expected: compile error, `Mydia.Accounts.IgnoredDiscoverTitle` is not available.

- [ ] **Step 3: Write the migration.** Table `discover_ignored_titles`, `primary_key: false`, with `add :id, :binary_id, primary_key: true`; `user_id` `references(:users, type: :binary_id, on_delete: :delete_all), null: false`; `media_type :text null: false`; `provider :text null: false`; `provider_id :integer null: false`; `timestamps(type: :utc_datetime, updated_at: false)`. Add `create unique_index(:discover_ignored_titles, [:user_id, :media_type, :provider, :provider_id])`. Pick a real timestamp and run the duplicate check from `AGENTS.md`.

- [ ] **Step 4: Write `Mydia.Accounts.IgnoredDiscoverTitle`.** Binary id primary key, `belongs_to :user, User, type: :binary_id`, fields `media_type`, `provider` (both `:string`), `provider_id :integer`, `timestamps(type: :utc_datetime, updated_at: false)`. `changeset/2` casts the three fields (not `user_id`), requires them, uses `validate_inclusion(:media_type, ~w(movie tv_show))`, `validate_inclusion(:provider, ~w(tmdb tvdb))`, `validate_number(:provider_id, greater_than: 0)`, and adds the `unique_constraint` for the index.

- [ ] **Step 5: Implement the three `Mydia.Accounts` functions.** Insert with `Repo.insert(changeset, on_conflict: :nothing, conflict_target: [:user_id, :media_type, :provider, :provider_id])` and map `{:ok, _}` to `:ok`. Delete with `Repo.delete_all` on the full key. Build keys with `{String.to_existing_atom(media_type), {String.to_existing_atom(provider), provider_id}}` (safe: both values went through the inclusion allowlist). Each function gets a `@doc` noting that it is idempotent.

- [ ] **Step 6: Run the tests on both adapters**

Run: `./dev mix test test/mydia/accounts/ignored_discover_titles_test.exs` and `DATABASE_TYPE=postgres ./dev mix test test/mydia/accounts/ignored_discover_titles_test.exs`
Expected: all pass. Also run `./dev mix test test/mydia/repo/migrations/no_varchar_columns_test.exs` and expect a pass.

- [ ] **Step 7: Commit** with the message `feat(accounts): store per-user Discover ignores (#1379)`.

---

### Task 2: `discover_show_ignored` preference

**Files:**
- Modify: `lib/mydia/accounts/user_preference.ex` (`@defaults` at line ~26, accessor after `discover_hide_owned/1`, `validate_preferences/1` at line ~281)
- Test: `test/mydia/accounts/user_preference_test.exs`

**Interfaces:**
- Produces: `UserPreference.discover_show_ignored(%UserPreference{}) :: boolean()`

- [ ] **Step 1: Write the failing tests** in a new `describe "discover_show_ignored"` block:
  - The default is false: `UserPreference.discover_show_ignored(%UserPreference{preferences: %{}}) == false`.
  - A stored true reads back true.
  - `UserPreference.changeset(pref, %{"preferences" => %{"discover_show_ignored" => "yes"}})` is invalid.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia/accounts/user_preference_test.exs`
Expected: `UndefinedFunctionError` for `discover_show_ignored/1`.

- [ ] **Step 3: Add the preference.** Add `"discover_show_ignored" => false` to `@defaults`, an accessor shaped like `discover_hide_owned/1`, and `validate_preference_value("discover_show_ignored", [true, false])` next to the hide-owned line.

- [ ] **Step 4: Run the tests and expect a pass.**

- [ ] **Step 5: Commit** with the message `feat(accounts): add the discover_show_ignored preference (#1379)`.

---

### Task 3: Card and detail modal controls

**Files:**
- Modify: `lib/mydia_web/components/discover_components.ex` (`trending_card/1` attrs and markup, from line ~74)
- Modify: `lib/mydia_web/live/components/trending_detail_modal.ex` (action row near lines 220-245; `update/2` defaults near line 375)
- Test: `test/mydia_web/components/discover_components_test.exs`, `test/mydia_web/live/components/trending_detail_modal_actions_test.exs`

**Interfaces:**
- Produces:
  - `trending_card/1` attrs `ignore_event :string, default: nil`, `unignore_event :string, default: nil`, `ignored :boolean, default: false`.
  - `TrendingDetailModal` assigns `ignore_event` and `unignore_event` (both default `nil`) and `ignored` (default `false`).
  - DOM ids `discover-ignore-<ref param>`, `discover-unignore-<ref param>`, `detail-ignore`, `detail-unignore`. Every control sends `phx-value-ref` (`Ref.to_param/1`) and `phx-value-media_type` (`"movie"`/`"tv_show"`).

- [ ] **Step 1: Write the failing component tests** (`render_component/2`, with a `%SearchResult{}` built with `provider: :tmdb` and an invented title):
  - `"no ignore button without ignore_event"`: rendering with defaults contains no `[id^=discover-ignore-]`, so the Dashboard is unchanged.
  - `"an unowned card with ignore_event renders the ignore button"`: `#discover-ignore-tmdb:<id>` exists with `aria-label="Ignore"`, `phx-click="ignore_title"`, `phx-value-ref="tmdb:<id>"`, `phx-value-media_type="movie"`.
  - `"an owned card renders no ignore button"`: with `in_library: true`, there is no `#discover-ignore-…`.
  - `"an ignored card shows the badge and Unignore in place of Add"`: with `ignored: true` and `unignore_event: "unignore_title"`, the card has the text `Ignored`, `#discover-unignore-tmdb:<id>`, and no Add action.
  - Modal: with `ignore_event: "ignore_title"` and an unowned item, `#detail-ignore` exists; with `ignored: true` and `unignore_event`, `#detail-unignore` exists; with neither, neither id exists.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia_web/components/discover_components_test.exs test/mydia_web/live/components/trending_detail_modal_actions_test.exs`
Expected: the new assertions fail.

- [ ] **Step 3: Implement the card controls.**
  - The ignore button is a `btn btn-circle btn-sm` with `<.icon name="hero-eye-slash" class="w-4 h-4" />`, absolute at `top-2 right-2 z-10`, rendered only when `@ignore_event && !@item.in_library && !@ignored`.
  - Its classes are `md:opacity-0 md:group-hover:opacity-100 md:focus-visible:opacity-100 transition-opacity`, so it is always visible on touch widths and hover or focus revealed from `md` up.
  - When `@ignored`, the poster wrapper gets `opacity-50 grayscale`, an `Ignored` badge (`badge badge-neutral badge-sm`) replaces the rating badge in the top left, and `trending_card_action` is replaced by an Unignore `btn btn-xs` when `@unignore_event` is set.

- [ ] **Step 4: Implement the modal button.** A `btn btn-outline` with `hero-eye-slash`, labelled `gettext("Ignore")` or `gettext("Unignore")`, placed after the Add `join` in the `true ->` branch and only for non-library items. It renders only when the matching event assign is non-nil.

- [ ] **Step 5: Run the tests and expect a pass.** Also run `./dev mix test test/mydia_web/components test/mydia_web/live/components` to confirm the other `trending_card` callers are unaffected.

- [ ] **Step 6: Commit** with the message `feat(web): ignore controls on Discover cards and the detail modal (#1379)`.

---

### Task 4: Filtering in the grid and regional rows

**Files:**
- Create: `lib/mydia_web/live/discover_live/ignores.ex`
- Modify: `lib/mydia_web/live/discover_live/index.ex` (mount around line 72; `assign_visible_items/1` at ~1143; `filtering?/1` at ~1187)
- Modify: `lib/mydia_web/live/discover_live/regional_components.ex` (the `hide_owned` attr and the reject at line 44)
- Modify: `lib/mydia_web/live/discover_live/index.html.heex` (the `regional_rows` call at ~274, the grid `trending_card` at ~342)
- Test: `test/mydia_web/live/discover_live/ignore_test.exs`

**Interfaces:**
- Consumes: `Accounts.ignored_discover_keys/1` (Task 1), `UserPreference.discover_show_ignored/1` (Task 2), the card attrs (Task 3).
- Produces, in `MydiaWeb.DiscoverLive.Ignores`:
  - `assign_initial(socket) :: socket`, which sets `:ignored_keys` (an empty `MapSet` with no user), `:show_ignored` and `:ignore_toast` (nil).
  - `ignored_key(item, fallback_media_type) :: {:movie | :tv_show, Ref.t()}`, using `item.media_type || fallback_media_type` and `Ref.from_search_result/1`.
  - `ignored?(assigns, item) :: boolean()`.
  - `hidden?(assigns, item) :: boolean()`, true when `(assigns.hide_owned and item.in_library)` or `(not assigns.show_ignored and ignored?(assigns, item))`. This is the single predicate the grid and the rows share.
  - `hiding_ignored?(assigns) :: boolean()`, meaning `not show_ignored and MapSet.size(ignored_keys) > 0`.

- [ ] **Step 1: Write the failing LiveView tests** in `ignore_test.exs`, using the `hide_owned_test.exs` setup (`warm_genre_cache`, `warm_trending_cache`, `create_admin_user`, `log_in_user`, `unique_provider_id`) and titles like "Paper Comet" and "Velvet Quarry":
  - `"an ignored title is hidden from the grid on mount"`: `Accounts.ignore_discover_title(user, {:tmdb, id}, :movie)` before `live/2`; the grid has no `h3` with that title, and the other title is still there.
  - `"a tv_show ignore does not hide the movie with the same id"`: ignore `{:tmdb, id}` as `:tv_show`; the movie grid still shows it.
  - `"show ignored on renders ignored titles dimmed with Unignore"`: set the preference true; the title is present and `#discover-unignore-tmdb:<id>` exists.
  - `"regional rows drop ignored titles"`: following `regional_rows_test.exs`'s setup, the ignored title is absent from `#discover-row-<param>`.
  - `"ignoring a whole page auto-advances"`: copy the Bypass two-page setup from `hide_owned_test.exs`'s auto-advance test; with every page-1 title ignored, page 2's title appears.
  - `"hiding_ignored? is false with no ignores or with show_ignored on"`: `Ignores.hiding_ignored?(%{ignored_keys: MapSet.new(), show_ignored: false}) == false` and `Ignores.hiding_ignored?(%{ignored_keys: MapSet.new([k]), show_ignored: true}) == false`. Reviewers check that `filtering?/1` keeps its `Scope.restricted?` term, so restricted users still auto-advance.
  - `"ignored_key falls back to the page media type"`: `Ignores.ignored_key(%SearchResult{media_type: nil, provider: :tmdb, provider_id: 5, …}, :movie) == {:movie, {:tmdb, 5}}`. Build the struct with its enforced keys and pass `media_type: nil` only if the struct allows it; otherwise use `Map.put(result, :media_type, nil)`.

- [ ] **Step 2: Run to verify they fail**

Run: `./dev mix test test/mydia_web/live/discover_live/ignore_test.exs`
Expected: the ignored title is still in the grid, and `Ignores` is undefined.

- [ ] **Step 3: Implement `Ignores`** with the five functions above.

- [ ] **Step 4: Wire `index.ex`.**
  - Pipe `Ignores.assign_initial()` after `assign_hide_owned()` in mount.
  - `assign_visible_items/1` rejects with `&Ignores.hidden?(socket.assigns, &1)`, except in search mode, which only applies the hide-owned rule as today.
  - `filtering?/1` becomes `hide_owned or Ignores.hiding_ignored?(assigns) or Scope.restricted?(...)`.

- [ ] **Step 5: Wire the templates.**
  - `regional_rows` replaces `hide_owned` with `hidden? :any` (a 1-arity function) and rejects with it; `index.html.heex` passes `hidden?={&Ignores.hidden?(assigns, &1)}`.
  - The grid's `trending_card` gets `ignore_event="ignore_title"`, `unignore_event="unignore_title"` and `ignored={Ignores.ignored?(assigns, item)}`, and so do the regional rows' cards.
  - When there is no current user, pass `ignore_event={nil}`.

- [ ] **Step 6: Run the tests and expect a pass.** Also run `./dev mix test test/mydia_web/live/discover_live` and expect the existing Discover suite to stay green.

- [ ] **Step 7: Commit** with the message `feat(web): hide ignored titles from Discover browsing (#1379)`.

---

### Task 5: Ignore, Unignore, Undo toast and the Show ignored toggle

**Files:**
- Modify: `lib/mydia_web/live/discover_live/ignores.ex`
- Modify: `lib/mydia_web/live/discover_live/index.ex` (delegating `handle_event`/`handle_info` clauses beside `toggle_hide_owned`; make `persist_preference/3` callable from `Ignores` by passing it in, or move it to `Ignores` unchanged if nothing else needs it; the modal's `ignore_event`/`unignore_event`/`ignored` assigns)
- Modify: `lib/mydia_web/live/discover_live/index.html.heex` (the toggle after `#discover-hide-owned`; a toast container)
- Test: `test/mydia_web/live/discover_live/ignore_test.exs`

**Interfaces:**
- Consumes: everything from Tasks 1 to 4.
- Produces, in `Ignores`:
  - `handle_event("ignore_title" | "unignore_title" | "toggle_show_ignored", params, socket) :: {:noreply, socket}`
  - `handle_info({:clear_ignore_toast, {media_type, ref}}, socket) :: socket`
  - `ignore_toast`: `nil | %{key: {media_type, ref}, title: String.t()}`.

- [ ] **Step 1: Write the failing tests** (in the same file):
  - `"clicking ignore hides the card and shows the toast"`: click `#discover-ignore-tmdb:<id>`; the title is gone from `#discover-grid`, `#discover-ignore-toast` contains it, and `Accounts.ignored_discover_keys(user)` contains the key.
  - `"Undo restores the card"`: click `#discover-ignore-toast-undo`; the title is back, the toast is gone, and the key set is empty.
  - `"the ignore survives a remount"`: ignore, then `live/2` again; the title is absent.
  - `"the toggle appears only with ignores and persists"`: with no ignores `#discover-show-ignored` is absent; after an ignore it is present with the label `Show ignored (1)`; clicking it sets `UserPreference.discover_show_ignored/1` true; after a remount it is `[checked]` and the ignored title renders with `#discover-unignore-…`.
  - `"Unignore from the dimmed card restores it"`: with the toggle on, click `#discover-unignore-…`; the key set is empty.
  - `"a forged ref changes nothing"`: `render_click(view, "ignore_title", %{"ref" => "imdb:tt1", "media_type" => "movie"})` and `%{"ref" => "tmdb:1", "media_type" => "episode"}` leave the key set empty, and the view is still alive.
  - `"a stale toast timer does not clear a newer toast"`: ignore A, then B; `send(view.pid, {:clear_ignore_toast, key_a})`; the toast still names B.
  - `"Ignore from the detail modal closes it and hides the card"`: open details as the existing modal tests do, click `#detail-ignore`; the modal is closed (`refute has_element?(view, "#discover-detail-modal [open]")`, matching how `index_test.exs` checks it) and the card is gone.
  - `"search shows an ignored title with Unignore"`: use `warm_movie_search_cache/3`, ignore the result first, search; the title is present with `#discover-unignore-…`.
  - `"no user, no ignores and no-op events"`: with a bare `%Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, current_user: nil}}`, `Ignores.assign_initial/1` sets `ignored_keys` to `MapSet.new()`, and `Ignores.handle_event("ignore_title", %{"ref" => "tmdb:1", "media_type" => "movie"}, socket)` returns `{:noreply, socket}` with `ignored_keys` unchanged. (`/discover` requires login, so this is a unit-level guard.)

- [ ] **Step 2: Run to verify they fail.**

- [ ] **Step 3: Implement the handlers in `Ignores`.**
  - Parse with `Ref.parse/1` and a private `parse_media_type/1` matching `index.ex`'s `parse_event_media_type/1`. On `:error`, or when there is no user, return the socket unchanged.
  - On ignore: call the context, update `ignored_keys`, set the toast with the item's title (found in `assigns.items`, the regional rows, or `selected_item`; fall back to `gettext("title")`), and `Process.send_after(self(), {:clear_ignore_toast, key}, 8_000)`. Close the modal with `DetailModal.close/1` when `selected_item` matches the key. The caller in `index.ex` then pipes `assign_visible_items()` and `maybe_auto_advance(0, @page_size)`.
  - On a failed write: `put_flash(socket, :error, gettext("Could not ignore that title"))` and leave the assigns as they were.
  - Unignore mirrors ignore and clears the toast if it names this key.
  - `toggle_show_ignored` follows `toggle_hide_owned`, including its error flash.
  - `{:clear_ignore_toast, key}` clears only when `ignore_toast.key == key`.

- [ ] **Step 4: Add the markup.**
  - The toggle is a `<label>` holding `<input id="discover-show-ignored" type="checkbox" class="toggle toggle-sm toggle-primary" phx-click="toggle_show_ignored" checked={@show_ignored}>` and `gettext("Show ignored (%{count})", count: MapSet.size(@ignored_keys))`. It renders when the size is > 0 and `@media_type != :person`.
  - The toast is `<div id="discover-ignore-toast" class="toast toast-center toast-bottom z-40">` holding an `alert` with `gettext("Ignored %{title}", title: …)` and `<button id="discover-ignore-toast-undo" class="btn btn-sm btn-ghost" phx-click="unignore_title" phx-value-ref=… phx-value-media_type=…>{gettext("Undo")}</button>`.
  - Pass the modal `ignore_event`, `unignore_event` and `ignored`.

- [ ] **Step 5: Run the tests and expect a pass.** Then run `./dev mix test test/mydia_web/live/discover_live` and expect it to stay green.

- [ ] **Step 6: Regenerate gettext.** Run `./dev mix gettext.extract --merge` and commit the catalog changes with the feature.

- [ ] **Step 7: Commit** with the message `feat(web): ignore, undo and show-ignored on Discover (#1379)`.

---

### Task 6: Verify in the browser and finish

- [ ] **Step 1:** Run `./dev mix precommit` (split as `test/README.md` advises if it exceeds the Bash timeout). Expect a clean run.
- [ ] **Step 2:** Run `./dev up -d` and log in as `admin`. On `/discover`, check at desktop width and at 390px:
  - The eye-slash shows on hover on desktop and always on the phone.
  - Ignoring shows the toast and Undo works.
  - The toggle count updates.
  - Dimmed cards render with the toggle on.
  - The modal's Ignore button works.

  Fix anything visual in Task 3's files and commit.
- [ ] **Step 3:** Run `git diff --stat origin/master...`. Expect only the files named in this plan plus the gettext catalogs.
