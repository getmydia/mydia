# Path-Mapping Suggestion at Failure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Downloads Issues tab and detail drawer from walking whole mounts on every render (#1315) by computing the path-mapping suggestion once, when the import fails, and storing it on the download.

**Architecture:** `MediaImport.Failure` runs a cheaper, bounded `PathMapping.suggest/3` when it records a `path_mapping_mismatch` and writes the result into three new `downloads` columns. A one-shot `PathMappingSuggestionBackfill` worker fills rows that failed before the upgrade. The history builders turn the stored columns into `EnrichedDownload.path_mapping_suggestion`, so the LiveView never touches the filesystem.

**Tech Stack:** Elixir, Ecto (SQLite and PostgreSQL), Oban, Phoenix LiveView.

**Spec:** `design/specs/2026-10-31-path-mapping-suggestion-at-failure-design.md`

## Global Constraints

- Migration columns use `:text`, never `:string` (`test/mydia/repo/migrations/no_varchar_columns_test.exs`). Timestamps use `:utc_datetime`.
- Migration filename uses a real timestamp, checked against every remote branch for duplicates (command in Task 1).
- `PathMapping.suggest` keeps its single-match rule: exactly one candidate returns `{:ok, %{remote_prefix:, local_prefix:}}`, anything else `:none`. A budget-exhausted walk returns `:none`.
- Walk budgets: `@max_scan_dirs 20_000`, `@max_scan_ms 5_000`, total for the call across all roots. Depth limit stays `@max_scan_depth 6`.
- The walk keeps non-`raw` `File` calls (see `MountRoots.reachable_dirs/2`).
- Nothing on the LiveView read path calls `MountRoots` or `PathMapping.suggest`.
- The backfill runs on the `:maintenance` queue, never `:media` or `:imports`.
- Tests never walk real mounts: `config/test.exs` sets `config :mydia, :path_mapping_roots, []`.
- Tests that change Application env are `async: false` and restore it in `on_exit`.
- Fixture names are invented (for example `Fictional.Salt.Meridian.S01E01`), never real titles.
- No em dashes in code comments, docs or commit messages.
- Run every `git commit` as `direnv exec . git commit ...` from the worktree root (the pre-commit hook needs the devenv environment), each commit in its own step, then check it with `git show --stat HEAD` and `git status --porcelain`.

## File Structure

| File | Change | Responsibility |
| --- | --- | --- |
| `priv/repo/migrations/<ts>_add_path_mapping_suggestion_to_downloads.exs` | create | three columns |
| `lib/mydia/downloads/download.ex` | modify | fields, cast, `path_mapping_suggestion/1`, `cleared_import_failure_attrs/0`, `cleared_path_mapping_attrs/0` |
| `lib/mydia/downloads/history.ex` | modify | three builders set `path_mapping_suggestion` from the row |
| `lib/mydia/downloads/structs/enriched_download.ex` | modify | comment only: suggestion now comes from the row |
| `lib/mydia/library/path_mapping.ex` | modify | suffix join, budgeted walk, `suggestion_attrs/2`, `search_roots/0` |
| `config/test.exs` | modify | `:path_mapping_roots` = `[]` |
| `lib/mydia/jobs/media_import/failure.ex` | modify | write suggestion columns with the failure |
| `lib/mydia_web/live/downloads_live/retry.ex`, `lib/mydia_web/live/downloads_live/index.ex` | modify | use `Download.cleared_import_failure_attrs/0`; enrichment only counts |
| `lib/mydia/jobs/path_mapping_suggestion_backfill.ex` | create | one-shot backfill worker |
| `lib/mydia/application.ex` | modify | `enqueue_once/0` at boot |

Deviation from the spec, on purpose: the spec lists `DownloadMonitor.clear_orphan_attrs/1` (`download_monitor.ex:849`) as a third reset site. That function clears only orphan-adoption failures, never a `path_mapping_mismatch`, and those rows always have null suggestion columns (Task 3 clears them for every non-mismatch failure). Folding it into the full reset map would also start resetting `import_retry_count` and `import_reported_path` there, which is a behavior change. It stays as it is. The spec also places the reset helper on the downloads context. It lives on the `Download` schema instead, next to the fields it names, which saves a `defdelegate`.

---

### Task 1: Columns, schema and read-through to `EnrichedDownload`

**Files:**
- Create: `priv/repo/migrations/<ts>_add_path_mapping_suggestion_to_downloads.exs`
- Modify: `lib/mydia/downloads/download.ex` (schema fields near line 68, `changeset/2` cast list near line 171)
- Modify: `lib/mydia/downloads/history.ex` (the three builders that copy `import_reported_path`, near lines 730, 780, 853)
- Modify: `lib/mydia/downloads/structs/enriched_download.ex:77` (comment)
- Test: `test/mydia/downloads/download_path_mapping_test.exs` (create)

**Interfaces:**
- Produces: `Download` fields `path_mapping_remote_prefix :: String.t() | nil`, `path_mapping_local_prefix :: String.t() | nil`, `path_mapping_searched_at :: DateTime.t() | nil`, all castable.
- Produces: `Download.path_mapping_suggestion(download) :: %{remote_prefix: String.t(), local_prefix: String.t()} | nil`
- Produces: `Download.cleared_path_mapping_attrs() :: map()` (the three columns set to nil)
- Produces: `Download.cleared_import_failure_attrs() :: map()` (the full import-failure reset, including the three columns)
- Produces: `EnrichedDownload.path_mapping_suggestion` is now filled by `Downloads.list_downloads_with_status/1` from the stored columns.

- [ ] **Step 1: Pick a migration timestamp and check for collisions**

```bash
date -u +%Y%m%d%H%M%S
git fetch --all --prune
for b in $(git branch -r --format='%(refname:short)' | grep -v HEAD); do
  git ls-tree -r --name-only "$b" -- priv/repo/migrations 2>/dev/null | xargs -r -n1 basename
done | cut -d_ -f1 | sort | uniq -d
```

Use the printed timestamp as `<ts>`. Make sure it is not in the duplicate list and not already present under `priv/repo/migrations`.

- [ ] **Step 2: Write the failing tests**

`test/mydia/downloads/download_path_mapping_test.exs`:

```elixir
defmodule Mydia.Downloads.DownloadPathMappingTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Downloads.Download

  defp mismatch(attrs) do
    media_item = media_item_fixture()

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          status: "completed",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: "/downloads/complete/Fictional.Salt.Meridian.S01E01"
        },
        attrs
      )
    )
  end

  test "casts and persists the stored suggestion" do
    searched_at = DateTime.utc_now() |> DateTime.truncate(:second)

    download =
      mismatch(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: searched_at
      })

    reloaded = Downloads.get_download!(download.id)
    assert reloaded.path_mapping_remote_prefix == "/downloads/complete"
    assert reloaded.path_mapping_local_prefix == "/data/torrents/complete"
    assert reloaded.path_mapping_searched_at == searched_at
  end

  describe "path_mapping_suggestion/1" do
    test "builds the map when both prefixes are stored" do
      assert Download.path_mapping_suggestion(%Download{
               path_mapping_remote_prefix: "/r",
               path_mapping_local_prefix: "/l"
             }) == %{remote_prefix: "/r", local_prefix: "/l"}
    end

    test "is nil when either prefix is missing" do
      assert Download.path_mapping_suggestion(%Download{}) == nil

      assert Download.path_mapping_suggestion(%Download{path_mapping_remote_prefix: "/r"}) ==
               nil
    end
  end

  test "cleared_import_failure_attrs/0 also clears the stored suggestion" do
    attrs = Download.cleared_import_failure_attrs()

    assert attrs.import_failure_reason == nil
    assert attrs.import_reported_path == nil
    assert attrs.import_retry_count == 0
    assert attrs.path_mapping_remote_prefix == nil
    assert attrs.path_mapping_local_prefix == nil
    assert attrs.path_mapping_searched_at == nil
  end

  test "list_downloads_with_status carries the stored suggestion onto the row" do
    download =
      mismatch(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete"
      })

    row =
      Downloads.list_downloads_with_status(bounded: true)
      |> Enum.find(&(&1.id == download.id))

    assert row.path_mapping_suggestion == %{
             remote_prefix: "/downloads/complete",
             local_prefix: "/data/torrents/complete"
           }
  end
end
```

- [ ] **Step 3: Run them to see them fail**

Run: `./dev mix test test/mydia/downloads/download_path_mapping_test.exs`
Expected: FAIL (unknown fields / `path_mapping_suggestion/1` undefined).

- [ ] **Step 4: Write the migration**

`priv/repo/migrations/<ts>_add_path_mapping_suggestion_to_downloads.exs`:

```elixir
defmodule Mydia.Repo.Migrations.AddPathMappingSuggestionToDownloads do
  use Ecto.Migration

  # The suggested remote-to-local mapping for a path_mapping_mismatch failure,
  # computed once when the import fails instead of on every Issues-tab render
  # (#1315). path_mapping_searched_at marks that the search ran, match or not,
  # so the backfill never repeats a search that found nothing.
  def change do
    alter table(:downloads) do
      add :path_mapping_remote_prefix, :text
      add :path_mapping_local_prefix, :text
      add :path_mapping_searched_at, :utc_datetime
    end
  end
end
```

- [ ] **Step 5: Add fields, cast and helpers to `Download`**

In `lib/mydia/downloads/download.ex`, after `field :import_reported_path, :string`:

```elixir
    # The suggested remote-to-local mapping for a path_mapping_mismatch,
    # computed once by Mydia.Jobs.MediaImport.Failure (or the backfill) so the
    # Issues tab never walks mounts. Both prefixes are set or both are nil.
    # path_mapping_searched_at is set whenever the search ran, match or not.
    field :path_mapping_remote_prefix, :string
    field :path_mapping_local_prefix, :string
    field :path_mapping_searched_at, :utc_datetime
```

Update the `import_reported_path` comment above it to: `# The client-reported path Mydia could not see. The backfill reads it to compute a path-mapping suggestion for rows that failed before suggestions were stored.`

Add the three types to the `@type t` if the module has one listing `import_reported_path` (`String.t() | nil`, `String.t() | nil`, `DateTime.t() | nil`).

Add `:path_mapping_remote_prefix, :path_mapping_local_prefix, :path_mapping_searched_at` to the `cast/3` list after `:import_reported_path`.

Add public functions before `changeset/2`:

```elixir
  @doc """
  The stored path-mapping suggestion as `%{remote_prefix:, local_prefix:}`, or
  nil when none was found (or the search has not run).
  """
  @spec path_mapping_suggestion(t()) :: %{remote_prefix: String.t(), local_prefix: String.t()} | nil
  def path_mapping_suggestion(%__MODULE__{
        path_mapping_remote_prefix: remote,
        path_mapping_local_prefix: local
      })
      when is_binary(remote) and is_binary(local),
      do: %{remote_prefix: remote, local_prefix: local}

  def path_mapping_suggestion(%__MODULE__{}), do: nil

  @doc "Attrs that drop a stored path-mapping suggestion."
  @spec cleared_path_mapping_attrs() :: map()
  def cleared_path_mapping_attrs do
    %{
      path_mapping_remote_prefix: nil,
      path_mapping_local_prefix: nil,
      path_mapping_searched_at: nil
    }
  end

  @doc """
  Attrs that reset every import-failure field, for re-running an import. Kept
  in one place so a field added later cannot be missed by one of the callers.
  """
  @spec cleared_import_failure_attrs() :: map()
  def cleared_import_failure_attrs do
    Map.merge(
      %{
        import_retry_count: 0,
        import_last_error: nil,
        import_failure_reason: nil,
        import_reported_path: nil,
        import_next_retry_at: nil,
        import_failed_at: nil
      },
      cleared_path_mapping_attrs()
    )
  end
```

If the module has no `@type t`, change the spec types to `%__MODULE__{}`.

- [ ] **Step 6: Fill `path_mapping_suggestion` in the three history builders**

In `lib/mydia/downloads/history.ex`, in each of the three builders that contain `import_reported_path: download.import_reported_path,`, add the line directly below it:

```elixir
      path_mapping_suggestion: Download.path_mapping_suggestion(download),
```

Check that `Download` is aliased in `history.ex` (`grep -n "alias Mydia.Downloads.Download" lib/mydia/downloads/history.ex`). Add the alias if it is missing.

In `lib/mydia/downloads/structs/enriched_download.ex`, change the comment `# Issues-tab path-mapping enrichment (computed in the LiveView; nil otherwise)` to:

```elixir
    # Path-mapping suggestion stored on the download row when the import failed
    # (nil when none was found); the affected count is computed by the Issues tab.
```

- [ ] **Step 7: Migrate and run the tests**

Run: `./dev mix ecto.migrate && ./dev mix test test/mydia/downloads/download_path_mapping_test.exs test/mydia/repo/migrations/no_varchar_columns_test.exs`
Expected: PASS.

- [ ] **Step 8: Commit**

```bash
git add priv/repo/migrations/*_add_path_mapping_suggestion_to_downloads.exs lib/mydia/downloads/download.ex lib/mydia/downloads/history.ex lib/mydia/downloads/structs/enriched_download.ex test/mydia/downloads/download_path_mapping_test.exs
direnv exec . git commit -m "feat(downloads): store the path-mapping suggestion on the download"
```

---

### Task 2: Cheaper, bounded search in `PathMapping`

**Files:**
- Modify: `lib/mydia/library/path_mapping.ex`
- Modify: `config/test.exs`
- Test: `test/mydia/library/path_mapping_suggestion_test.exs`

**Interfaces:**
- Consumes: `Download.cleared_path_mapping_attrs/0` key names from Task 1.
- Produces: `PathMapping.suggest(reported_path, roots \\ nil, opts \\ []) :: {:ok, %{remote_prefix: String.t(), local_prefix: String.t()}} | :none`, opts `:max_scan_dirs`, `:max_scan_ms`.
- Produces: `PathMapping.search_roots() :: [String.t()]` (the `:path_mapping_roots` app env when set, else `MountRoots.detect/0`).
- Produces: `PathMapping.suggestion_attrs(reported_path, roots \\ nil) :: %{path_mapping_remote_prefix:, path_mapping_local_prefix:, path_mapping_searched_at:}`. Never raises. `path_mapping_searched_at` is always set.

Behavior change to note: an existing test, "abstains when the basename matches under two roots (AE3)", has `a/complete/Show.S01E01` and `b/anime/Show.S01E01` for a reported `/downloads/complete/Show.S01E01`. Under the spec's longest-slice rule, `a/complete/Show.S01E01` matches the slice `complete/Show.S01E01` and nothing else does, so the suggestion is now `a/complete`. That is the intended result (a longer matched suffix is stronger evidence). The test is rewritten to keep its purpose (ambiguity at the deciding slice) and a new test pins the new behavior.

- [ ] **Step 1: Write the failing tests**

Replace the AE3 test in `test/mydia/library/path_mapping_suggestion_test.exs` and append the new tests inside the module:

```elixir
  test "abstains when the deciding suffix matches under two roots (AE3)", %{tmp: tmp} do
    root_a = Path.join(tmp, "a")
    root_b = Path.join(tmp, "b")
    File.mkdir_p!(Path.join([root_a, "complete", "Show.S01E01"]))
    File.mkdir_p!(Path.join([root_b, "complete", "Show.S01E01"]))

    assert PathMapping.suggest("/downloads/complete/Show.S01E01", [root_a, root_b]) == :none
  end

  describe "suffix join" do
    test "finds the release by joining a root with the reported path's tail", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join([root, "downloads", "complete", "Fictional.Salt.Meridian.S01E01"]))

      assert PathMapping.suggest(
               "/downloads/complete/Fictional.Salt.Meridian.S01E01",
               [root],
               # Zero walk budget: only the suffix join can produce this match.
               max_scan_dirs: 0
             ) ==
               {:ok,
                %{
                  remote_prefix: "/downloads/complete",
                  local_prefix: Path.join([root, "downloads", "complete"])
                }}
    end

    test "prefers the longest matching tail over a basename-only match", %{tmp: tmp} do
      root_a = Path.join(tmp, "a")
      root_b = Path.join(tmp, "b")
      File.mkdir_p!(Path.join([root_a, "complete", "Show.S01E01"]))
      File.mkdir_p!(Path.join([root_b, "Show.S01E01"]))

      assert {:ok, %{local_prefix: local}} =
               PathMapping.suggest("/downloads/complete/Show.S01E01", [root_a, root_b])

      assert local == Path.join(root_a, "complete")
    end

    test "never joins a tail containing ..", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join(root, "Release"))

      assert PathMapping.suggest("/dl/../Release", [root], max_scan_dirs: 0) == :none
    end
  end

  describe "walk budgets" do
    setup %{tmp: tmp} do
      root = Path.join(tmp, "data")

      for n <- 1..5 do
        File.mkdir_p!(Path.join([root, "d#{n}", "deep"]))
      end

      File.mkdir_p!(Path.join([root, "d5", "deep", "Release"]))
      {:ok, root: root}
    end

    test "finds the release when the budget is large enough", %{root: root} do
      assert {:ok, %{local_prefix: local}} = PathMapping.suggest("/remote/Release", [root])
      assert local == Path.join([root, "d5", "deep"])
    end

    test "returns :none when the directory budget runs out", %{root: root} do
      assert PathMapping.suggest("/remote/Release", [root], max_scan_dirs: 2) == :none
    end

    test "returns :none when the time budget runs out", %{root: root} do
      assert PathMapping.suggest("/remote/Release", [root], max_scan_ms: 0) == :none
    end
  end

  describe "suggestion_attrs/2" do
    test "stores the match and stamps the search", %{tmp: tmp} do
      root = Path.join(tmp, "data")
      File.mkdir_p!(Path.join([root, "complete", "Release"]))

      attrs = PathMapping.suggestion_attrs("/downloads/complete/Release", [root])

      assert attrs.path_mapping_remote_prefix == "/downloads/complete"
      assert attrs.path_mapping_local_prefix == Path.join(root, "complete")
      assert %DateTime{} = attrs.path_mapping_searched_at
    end

    test "stamps the search with null prefixes when nothing matches", %{tmp: tmp} do
      attrs = PathMapping.suggestion_attrs("/downloads/complete/Release", [tmp])

      assert attrs.path_mapping_remote_prefix == nil
      assert attrs.path_mapping_local_prefix == nil
      assert %DateTime{} = attrs.path_mapping_searched_at
    end

    test "uses the configured roots, which the test config empties" do
      assert PathMapping.search_roots() == []
    end
  end
```

- [ ] **Step 2: Run them to see them fail**

Run: `./dev mix test test/mydia/library/path_mapping_suggestion_test.exs`
Expected: FAIL (`suggest/3`, `suggestion_attrs/2` and `search_roots/0` undefined; the longest-tail test returns `:none`).

- [ ] **Step 3: Add the test config**

In `config/test.exs`, next to the other `config :mydia, ...` lines near the top:

```elixir
# Mydia.Library.PathMapping searches these roots instead of the machine's real
# mounts, so an import failure in a test never walks /tmp (#1315). Tests that
# need a search pass roots explicitly.
config :mydia, :path_mapping_roots, []
```

- [ ] **Step 4: Rewrite the search in `PathMapping`**

In `lib/mydia/library/path_mapping.ex`:

Add `require Logger` under the aliases. Replace the `@max_scan_depth` block and the whole `suggest` section with:

```elixir
  # Bounds for the basename walk, which only runs when the suffix join finds
  # nothing. Totals for one call across every root. A walk that runs out
  # returns :none: it cannot prove the match it saw is the only one.
  @max_scan_depth 6
  @max_scan_dirs 20_000
  @max_scan_ms 5_000

  @doc """
  Suggests a remote→local prefix mapping for a reported path Mydia couldn't see.

  Tries a suffix join first: each root joined with the reported path's
  trailing segments, longest first (`downloads/complete/X`, `complete/X`,
  `X`). The longest tail that names any directory decides. If it names exactly
  one, that is the match. Otherwise the search falls back to walking each root
  (up to #{@max_scan_depth} levels) for a directory with the reported basename,
  within a budget of #{@max_scan_dirs} directories and #{@max_scan_ms}ms.

  Returns `{:ok, %{remote_prefix, local_prefix}}` only on exactly one match.
  The single-match gate guards against ambiguity, not against a
  confidently-wrong match, so callers must present the suggestion for explicit
  confirmation. Zero or multiple matches, or a walk that ran out of budget,
  return `:none`.

  `roots` defaults to `search_roots/0`; pass an explicit list in tests.
  Options `:max_scan_dirs` and `:max_scan_ms` override the walk budgets.
  """
  @spec suggest(String.t(), [String.t()] | nil, keyword()) :: {:ok, map()} | :none
  def suggest(reported_path, roots \\ nil, opts \\ [])

  def suggest(reported_path, roots, opts) when is_binary(reported_path) do
    roots = roots || search_roots()

    case suffix_match(reported_path, roots) do
      {:ok, local_dir} -> {:ok, mapping(reported_path, local_dir)}
      :none -> walk_match(reported_path, roots, opts)
    end
  end

  def suggest(_reported_path, _roots, _opts), do: :none

  @doc """
  The roots `suggest/3` searches by default: the `:path_mapping_roots` app env
  when set (the test config sets `[]`), otherwise `MountRoots.detect/0`.
  """
  @spec search_roots() :: [String.t()]
  def search_roots do
    Application.get_env(:mydia, :path_mapping_roots) || MountRoots.detect()
  end

  @doc """
  The `Mydia.Downloads.Download` attrs recording a suggestion search for
  `reported_path`: both prefixes on a match, both nil otherwise, and
  `path_mapping_searched_at` set either way.

  Never raises. An import failure must still be recorded when the search
  crashes, so a crash is logged and stored as "searched, nothing found".
  """
  @spec suggestion_attrs(String.t(), [String.t()] | nil) :: map()
  def suggestion_attrs(reported_path, roots \\ nil) do
    reported_path |> suggest(roots) |> searched_attrs()
  rescue
    error ->
      Logger.warning("Path-mapping suggestion search failed",
        reported_path: reported_path,
        error: Exception.message(error)
      )

      searched_attrs(:none)
  end

  defp searched_attrs(result) do
    {remote, local} =
      case result do
        {:ok, %{remote_prefix: remote, local_prefix: local}} -> {remote, local}
        :none -> {nil, nil}
      end

    %{
      path_mapping_remote_prefix: remote,
      path_mapping_local_prefix: local,
      path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  defp mapping(reported_path, local_dir) do
    %{remote_prefix: Path.dirname(reported_path), local_prefix: Path.dirname(local_dir)}
  end

  # The longest tail that names a directory under any root decides: one
  # directory is the match, several are ambiguous and fall through to the walk.
  defp suffix_match(reported_path, roots) do
    reported_path
    |> trailing_slices()
    |> Enum.find_value(:none, fn slice ->
      case roots |> Enum.map(&Path.join(&1, slice)) |> Enum.filter(&File.dir?/1) |> Enum.uniq() do
        [] -> nil
        [local_dir] -> {:ok, local_dir}
        _ambiguous -> :none
      end
    end)
  end

  # "/downloads/complete/X" => ["downloads/complete/X", "complete/X", "X"].
  # A path with a ".." segment gets no slices: joining it could name a
  # directory outside the root.
  defp trailing_slices(path) do
    segments = path |> Path.split() |> Enum.reject(&(&1 == "/"))

    if ".." in segments do
      []
    else
      for n <- length(segments)..1//-1, do: segments |> Enum.take(-n) |> Path.join()
    end
  end

  defp walk_match(reported_path, roots, opts) do
    budget = %{
      dirs_left: Keyword.get(opts, :max_scan_dirs, @max_scan_dirs),
      deadline:
        System.monotonic_time(:millisecond) + Keyword.get(opts, :max_scan_ms, @max_scan_ms)
    }

    name = Path.basename(reported_path)

    result =
      Enum.reduce_while(roots, {[], budget}, fn root, {found, budget} ->
        case find_dirs_named(root, name, @max_scan_depth, budget) do
          {:ok, here, budget} -> {:cont, {found ++ here, budget}}
          :exhausted -> {:halt, :exhausted}
        end
      end)

    case result do
      {found, _budget} ->
        case Enum.uniq(found) do
          [local_dir] -> {:ok, mapping(reported_path, local_dir)}
          _ -> :none
        end

      :exhausted ->
        :none
    end
  end
```

Replace the old `find_dirs_named/3` with:

```elixir
  defp find_dirs_named(_dir, _name, depth, budget) when depth < 0, do: {:ok, [], budget}

  defp find_dirs_named(dir, name, depth, budget) do
    cond do
      budget.dirs_left <= 0 ->
        :exhausted

      System.monotonic_time(:millisecond) >= budget.deadline ->
        :exhausted

      true ->
        budget = %{budget | dirs_left: budget.dirs_left - 1}

        case File.ls(dir) do
          {:ok, entries} -> scan_entries(entries, dir, name, depth, budget, [])
          _ -> {:ok, [], budget}
        end
    end
  end

  defp scan_entries([], _dir, _name, _depth, budget, found), do: {:ok, found, budget}

  defp scan_entries([entry | rest], dir, name, depth, budget, found) do
    full = Path.join(dir, entry)

    if File.dir?(full) do
      here = if entry == name, do: [full], else: []

      case find_dirs_named(full, name, depth - 1, budget) do
        {:ok, below, budget} -> scan_entries(rest, dir, name, depth, budget, found ++ here ++ below)
        :exhausted -> :exhausted
      end
    else
      scan_entries(rest, dir, name, depth, budget, found)
    end
  end
```

- [ ] **Step 5: Run the tests**

Run: `./dev mix test test/mydia/library/path_mapping_suggestion_test.exs test/mydia/library/mount_roots_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia/library/path_mapping.ex config/test.exs test/mydia/library/path_mapping_suggestion_test.exs
direnv exec . git commit -m "feat(library): bound the path-mapping search and try a suffix join first"
```

---

### Task 3: Store the suggestion when the import fails; clear it on retry

**Files:**
- Modify: `lib/mydia/jobs/media_import/failure.ex` (`handle_import_failure/4`, around lines 66-87)
- Modify: `lib/mydia_web/live/downloads_live/retry.ex` (`requeue_import/1`)
- Modify: `lib/mydia_web/live/downloads_live/index.ex` (`retry_mismatches_under_prefix/1`, around line 1576)
- Test: `test/mydia/jobs/media_import_test.exs` (the mismatch test near line 793), `test/mydia/jobs/media_import/failure_path_mapping_test.exs` (create), `test/mydia_web/live/downloads_live/retry_test.exs`, `test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`

**Interfaces:**
- Consumes: `PathMapping.suggestion_attrs/2`, `Download.cleared_path_mapping_attrs/0`, `Download.cleared_import_failure_attrs/0`.
- Produces: after `handle_import_failure/4` with `{:path_mapping_mismatch, path}`, the row has `path_mapping_searched_at` set; with any other reason, the three columns are nil.

- [ ] **Step 1: Write the failing tests**

`test/mydia/jobs/media_import/failure_path_mapping_test.exs`:

```elixir
defmodule Mydia.Jobs.MediaImport.FailurePathMappingTest do
  use Mydia.DataCase, async: true

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Jobs.MediaImport.Failure

  defp download(attrs \\ %{}) do
    media_item = media_item_fixture()
    download_fixture(Map.merge(%{media_item_id: media_item.id, status: "completed"}, attrs))
  end

  test "a mismatch failure stamps the search with the failure" do
    d = download()

    :ok =
      Failure.handle_import_failure(
        d,
        {:path_mapping_mismatch, "/downloads/complete/Fictional.Salt.Meridian.S01E01"},
        1,
        terminal?: true
      )

    updated = Downloads.get_download!(d.id)
    assert updated.import_failure_reason == "path_mapping_mismatch"
    # The test config searches no roots, so nothing matches, but the search ran.
    assert %DateTime{} = updated.path_mapping_searched_at
    assert updated.path_mapping_remote_prefix == nil
    assert updated.path_mapping_local_prefix == nil
  end

  test "any other failure clears a suggestion left over from an earlier one" do
    d =
      download(%{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    :ok = Failure.handle_import_failure(d, :no_files, 1)

    updated = Downloads.get_download!(d.id)
    assert updated.import_failure_reason == "no_files"
    assert updated.path_mapping_remote_prefix == nil
    assert updated.path_mapping_local_prefix == nil
    assert updated.path_mapping_searched_at == nil
  end
end
```

Check that `:no_files` is a valid `reason` for `format_import_error/2` (it is, line 168).

In `test/mydia/jobs/media_import_test.exs`, after `assert updated.import_reported_path == "/no/such/path/exists"` (near line 802) add:

```elixir
      assert %DateTime{} = updated.path_mapping_searched_at
```

In `test/mydia_web/live/downloads_live/retry_test.exs`, find the existing `requeue_import` test (`grep -n "requeue_import" test/mydia_web/live/downloads_live/retry_test.exs`). Add these attrs to the fixture it builds:

```elixir
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
```

and after its existing assertions on the reloaded row:

```elixir
      assert reloaded.path_mapping_remote_prefix == nil
      assert reloaded.path_mapping_local_prefix == nil
      assert reloaded.path_mapping_searched_at == nil
```

Use whatever variable name the test already binds for the reloaded download. If there is no such test, add one in the file's style that builds a failed download with those attrs, calls `MydiaWeb.DownloadsLive.Retry.requeue_import(download)`, reloads with `Mydia.Downloads.get_download!/1` and asserts the three columns plus `import_failure_reason` are nil (the test module needs the isolated Oban `start_supervised!` setup used in `path_mapping_issue_test.exs`).

In `test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`, in "applying a mapping persists it and re-runs every affected mismatch", give `a` a stored suggestion and assert it is cleared:

```elixir
      a =
        mismatch_download("/downloads/complete/A", %{
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
```

and after `assert is_nil(Downloads.get_download!(a.id).import_failed_at)`:

```elixir
      assert is_nil(Downloads.get_download!(a.id).path_mapping_remote_prefix)
```

- [ ] **Step 2: Run them to see them fail**

Run: `./dev mix test test/mydia/jobs/media_import/failure_path_mapping_test.exs test/mydia/jobs/media_import_test.exs test/mydia_web/live/downloads_live/retry_test.exs test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`
Expected: FAIL on the new assertions.

- [ ] **Step 3: Write the suggestion in `Failure`**

In `lib/mydia/jobs/media_import/failure.ex` add aliases:

```elixir
  alias Mydia.Downloads.Download
  alias Mydia.Library.PathMapping
```

In `handle_import_failure/4`, pipe the attrs map into a merge:

```elixir
    attrs =
      %{
        import_retry_count: attempt,
        import_last_error: error_message,
        import_failure_reason: failure_reason_tag(reason),
        import_reported_path: failure_reported_path(reason),
        import_next_retry_at: next_retry_at,
        import_failed_at: import_failed_at
      }
      |> Map.merge(path_mapping_attrs(reason))
```

Add next to `failure_reported_path/1`:

```elixir
  # A mount mismatch searches for the directory Mydia can see once, here in the
  # background job, so the Issues tab only reads the result (#1315). Any other
  # failure drops a suggestion an earlier mismatch left behind.
  defp path_mapping_attrs({:path_mapping_mismatch, path}) when is_binary(path),
    do: PathMapping.suggestion_attrs(path)

  defp path_mapping_attrs(_reason), do: Download.cleared_path_mapping_attrs()
```

- [ ] **Step 4: Use the shared reset map at both retry sites**

In `lib/mydia_web/live/downloads_live/retry.ex`, replace the literal map in `requeue_import/1`:

```elixir
    case Downloads.update_download(download, Mydia.Downloads.Download.cleared_import_failure_attrs()) do
```

In `lib/mydia_web/live/downloads_live/index.ex`, `retry_mismatches_under_prefix/1`, replace the literal map the same way:

```elixir
      case Downloads.update_download(download, Mydia.Downloads.Download.cleared_import_failure_attrs()) do
```

Leave `DownloadMonitor.clear_orphan_attrs/1` unchanged (see the deviation note at the top of this plan).

- [ ] **Step 5: Run the tests**

Run: `./dev mix test test/mydia/jobs/media_import/failure_path_mapping_test.exs test/mydia/jobs/media_import_test.exs test/mydia_web/live/downloads_live/retry_test.exs test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia/jobs/media_import/failure.ex lib/mydia_web/live/downloads_live/retry.ex lib/mydia_web/live/downloads_live/index.ex test/mydia/jobs/media_import/failure_path_mapping_test.exs test/mydia/jobs/media_import_test.exs test/mydia_web/live/downloads_live/retry_test.exs test/mydia_web/live/downloads_live/path_mapping_issue_test.exs
direnv exec . git commit -m "feat(import): compute the path-mapping suggestion when the import fails"
```

---

### Task 4: Issues tab and drawer read the stored suggestion

**Files:**
- Modify: `lib/mydia_web/live/downloads_live/index.ex` (`assign_drawer/2` near line 1436, `enrich_issue_path_mappings/1` near line 1507, `enrich_path_mapping_suggestions/1` near line 1610)
- Test: `test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`

**Interfaces:**
- Consumes: `EnrichedDownload.path_mapping_suggestion` filled by Task 1.
- Produces: `enrich_path_mapping_counts/1` (private), which only sets `path_mapping_affected_count`.

- [ ] **Step 1: Write the failing tests**

Add a describe block to `test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`:

```elixir
  describe "stored suggestion" do
    setup %{conn: conn} do
      %{conn: log_in_user(conn, admin_user_fixture())}
    end

    test "the Issues tab offers the stored mapping with its affected count", %{conn: conn} do
      stored = %{
        path_mapping_remote_prefix: "/downloads/complete",
        path_mapping_local_prefix: "/data/torrents/complete",
        path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      download = mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E01", stored)
      mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E02", stored)

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      assert has_element?(
               view,
               "#apply-mapping-#{download.id}[phx-value-local_prefix='/data/torrents/complete']"
             )
    end

    test "a mismatch with no stored suggestion offers a plain retry", %{conn: conn} do
      download = mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E03")

      {:ok, view, _html} = live(conn, ~p"/downloads")
      render_patch(view, ~p"/downloads?tab=issues")

      assert has_element?(view, "#retry-import-#{download.id}")
      refute has_element?(view, "#apply-mapping-#{download.id}")
    end

    test "the drawer shows the stored mapping", %{conn: conn} do
      download =
        mismatch_download("/downloads/complete/Fictional.Salt.Meridian.S01E04", %{
          path_mapping_remote_prefix: "/downloads/complete",
          path_mapping_local_prefix: "/data/torrents/complete",
          path_mapping_searched_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      {:ok, view, _html} = live(conn, ~p"/downloads?tab=issues&download=#{download.id}")

      assert has_element?(view, "#drawer-path-mapping", "/data/torrents/complete")
    end
  end
```

Check the drawer's container id before relying on it: `grep -n "drawer-path-mapping\|drawer-apply-mapping" lib/mydia_web/live/downloads_live/detail_drawer.ex`. If the apply button carries the id `drawer-apply-mapping-#{id}`, assert on that instead of the text.

- [ ] **Step 2: Run them to see them fail**

Run: `./dev mix test test/mydia_web/live/downloads_live/path_mapping_issue_test.exs`
Expected: the stored-suggestion tests FAIL. The enrichment overwrites `path_mapping_suggestion` with the result of a fresh search, which is nil because the test config searches no roots.

- [ ] **Step 3: Replace the enrichment**

In `lib/mydia_web/live/downloads_live/index.ex`, replace the whole `enrich_path_mapping_suggestions/1` function and its comment with:

```elixir
  # The suggestion itself is computed when the import fails
  # (Mydia.Jobs.MediaImport.Failure) and arrives on the row, so rendering never
  # touches the filesystem (#1315). This only counts how many downloads a
  # one-click apply would re-run, once per remote prefix.
  defp enrich_path_mapping_counts(downloads) do
    {enriched, _counts} =
      Enum.map_reduce(downloads, %{}, fn
        %{path_mapping_suggestion: %{remote_prefix: prefix}} = d, counts ->
          {count, counts} =
            Map.get_and_update(counts, prefix, fn
              nil ->
                count = prefix |> Downloads.list_path_mapping_mismatches_under_prefix() |> length()
                {count, count}

              count ->
                {count, count}
            end)

          {%{d | path_mapping_affected_count: count}, counts}

        d, counts ->
          {d, counts}
      end)

    enriched
  end
```

Rename both call sites from `enrich_path_mapping_suggestions()` to `enrich_path_mapping_counts()` (in `assign_drawer/2` and `enrich_issue_path_mappings/1`). Change the comment above `enrich_issue_path_mappings/1` from `# The mapping suggestion is a query, so it runs only for the rows on screen.` to `# The affected count is a query, so it runs only for the rows on screen.`

- [ ] **Step 4: Confirm nothing on the read path searches**

Run: `grep -rn "MountRoots\|PathMapping.suggest" lib/mydia_web`
Expected: no output.

- [ ] **Step 5: Run the Downloads LiveView tests**

Run: `./dev mix test test/mydia_web/live/downloads_live`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia_web/live/downloads_live/index.ex test/mydia_web/live/downloads_live/path_mapping_issue_test.exs
direnv exec . git commit -m "fix(downloads): read the stored path-mapping suggestion instead of walking mounts (#1315)"
```

---

### Task 5: Backfill for downloads that failed before the upgrade

**Files:**
- Create: `lib/mydia/jobs/path_mapping_suggestion_backfill.ex`
- Modify: `lib/mydia/application.ex` (next to `Mydia.Jobs.HdrBackfill.enqueue_once()`, near line 87)
- Test: `test/mydia/jobs/path_mapping_suggestion_backfill_test.exs` (create)

**Interfaces:**
- Consumes: `PathMapping.search_roots/0`, `PathMapping.suggestion_attrs/2`.
- Produces: `Mydia.Jobs.PathMappingSuggestionBackfill.enqueue_once() :: :ok`, `pending_ids(limit) :: [binary()]`, Oban worker on `:maintenance`.

- [ ] **Step 1: Write the failing tests**

`test/mydia/jobs/path_mapping_suggestion_backfill_test.exs`:

```elixir
defmodule Mydia.Jobs.PathMappingSuggestionBackfillTest do
  # Changes the :path_mapping_roots app env and drives an isolated Oban
  # instance, so it runs serially.
  use Mydia.DataCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  import Mydia.DownloadsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Downloads
  alias Mydia.Jobs.PathMappingSuggestionBackfill

  setup do
    start_supervised!(
      {Oban, repo: Mydia.Repo, engine: Mydia.AdapterHelpers.oban_engine(), testing: :manual}
    )

    tmp = Path.join(System.tmp_dir!(), "pmsb_#{System.unique_integer([:positive])}")
    root = Path.join(tmp, "data")
    File.mkdir_p!(Path.join([root, "complete", "Fictional.Salt.Meridian.S01E01"]))

    previous = Application.get_env(:mydia, :path_mapping_roots)
    Application.put_env(:mydia, :path_mapping_roots, [root])

    on_exit(fn ->
      Application.put_env(:mydia, :path_mapping_roots, previous)
      File.rm_rf(tmp)
    end)

    {:ok, root: root}
  end

  defp mismatch(reported_path, attrs \\ %{}) do
    media_item = media_item_fixture()

    download_fixture(
      Map.merge(
        %{
          media_item_id: media_item.id,
          status: "completed",
          import_failed_at: DateTime.utc_now() |> DateTime.truncate(:second),
          import_failure_reason: "path_mapping_mismatch",
          import_reported_path: reported_path
        },
        attrs
      )
    )
  end

  test "fills a suggestion for an unsearched mismatch", %{root: root} do
    d = mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    updated = Downloads.get_download!(d.id)
    assert updated.path_mapping_remote_prefix == "/downloads/complete"
    assert updated.path_mapping_local_prefix == Path.join(root, "complete")
    assert %DateTime{} = updated.path_mapping_searched_at
  end

  test "stamps a mismatch with no match so it is never searched again" do
    d = mismatch("/downloads/complete/Fictional.Copper.Lantern.S02E03")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    updated = Downloads.get_download!(d.id)
    assert updated.path_mapping_remote_prefix == nil
    assert %DateTime{} = updated.path_mapping_searched_at
    assert PathMappingSuggestionBackfill.pending_ids(10) == []
  end

  test "skips rows already searched and rows that are not mismatches" do
    searched_at = ~U[2026-01-01 00:00:00Z]

    searched =
      mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01", %{
        path_mapping_searched_at: searched_at
      })

    other =
      mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01", %{
        import_failure_reason: "no_files"
      })

    assert PathMappingSuggestionBackfill.pending_ids(10) == []
    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})

    assert Downloads.get_download!(searched.id).path_mapping_searched_at == searched_at
    assert Downloads.get_download!(other.id).path_mapping_searched_at == nil
  end

  test "reschedules itself while a batch did work, and stops when drained" do
    mismatch("/downloads/complete/Fictional.Salt.Meridian.S01E01")

    assert :ok = perform_job(PathMappingSuggestionBackfill, %{})
    assert_enqueued(worker: PathMappingSuggestionBackfill)

    Oban.drain_queue(queue: :maintenance)
    assert PathMappingSuggestionBackfill.pending_ids(10) == []
  end

  test "enqueue_once/0 does not stack a second job" do
    assert :ok = PathMappingSuggestionBackfill.enqueue_once()
    assert :ok = PathMappingSuggestionBackfill.enqueue_once()

    assert [_one] = all_enqueued(worker: PathMappingSuggestionBackfill)
  end
end
```

If `Oban.drain_queue/1` complains about the manual testing mode, replace those two lines with a second `perform_job(PathMappingSuggestionBackfill, %{})` followed by `refute_enqueued`-free assertions on `pending_ids(10) == []`. `test/mydia/jobs/hdr_backfill_test.exs` shows the pattern this repo uses.

- [ ] **Step 2: Run them to see them fail**

Run: `./dev mix test test/mydia/jobs/path_mapping_suggestion_backfill_test.exs`
Expected: FAIL (`PathMappingSuggestionBackfill` undefined).

- [ ] **Step 3: Write the worker**

`lib/mydia/jobs/path_mapping_suggestion_backfill.ex`:

```elixir
defmodule Mydia.Jobs.PathMappingSuggestionBackfill do
  @moduledoc """
  One-shot worker that computes the stored path-mapping suggestion for
  downloads that failed with `path_mapping_mismatch` before suggestions were
  stored (#1315). New failures get theirs from `Mydia.Jobs.MediaImport.Failure`.

  Selection is by row state, so the worker is idempotent: it takes mismatch
  rows whose `path_mapping_searched_at` is nil, and every outcome stamps it,
  including a search that found nothing.

  Runs on `:maintenance` so a slow mount search can never delay an import.
  The uniqueness setup and the self-reschedule follow `Mydia.Jobs.HdrBackfill`;
  its comments explain both.
  """

  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [
      period: 300,
      fields: [:worker],
      states: [:suspended, :available, :scheduled, :executing, :retryable]
    ]

  import Ecto.Query

  require Logger

  alias Mydia.Downloads
  alias Mydia.Downloads.Download
  alias Mydia.Library.PathMapping
  alias Mydia.Repo

  @default_batch_size 25

  # See Mydia.Jobs.HdrBackfill: the reschedule must drop :executing or it
  # matches this job's own row and is silently never inserted.
  @reschedule_unique_states [:suspended, :available, :scheduled, :retryable]

  @doc """
  Enqueues the backfill. Called once at boot. Never raises, for the reason
  given on `Mydia.Jobs.HdrBackfill.enqueue_once/0`.
  """
  @spec enqueue_once() :: :ok
  def enqueue_once do
    %{} |> new() |> Oban.insert()
    :ok
  rescue
    error ->
      Logger.warning("Path-mapping suggestion backfill: failed to enqueue on boot",
        error: inspect(error)
      )

      :ok
  end

  @doc "Ids of mismatch downloads never searched for a suggestion, capped at `limit`."
  @spec pending_ids(pos_integer()) :: [binary()]
  def pending_ids(limit) do
    Download
    |> where([d], d.import_failure_reason == "path_mapping_mismatch")
    |> where([d], not is_nil(d.import_failed_at))
    |> where([d], not is_nil(d.import_reported_path))
    |> where([d], is_nil(d.path_mapping_searched_at))
    |> order_by([d], asc: d.id)
    |> limit(^limit)
    |> select([d], d.id)
    |> Repo.all()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case pending_ids(@default_batch_size) do
      [] ->
        Logger.info("Path-mapping suggestion backfill complete, no rows pending")
        :ok

      ids ->
        # Mount detection probes every candidate mount, so do it once per batch.
        roots = PathMapping.search_roots()
        Enum.each(ids, &backfill_one(&1, roots))

        # Every row in the batch was stamped, so the next batch is new rows.
        %{} |> new(schedule_in: 5, unique: [states: @reschedule_unique_states]) |> Oban.insert()
        :ok
    end
  end

  defp backfill_one(id, roots) do
    case Repo.get(Download, id) do
      %Download{import_reported_path: path} = download when is_binary(path) ->
        Downloads.update_download(download, PathMapping.suggestion_attrs(path, roots))

      _gone ->
        :ok
    end
  end
end
```

`backfill_one/2` ignores an `{:error, changeset}` from `update_download/2`. That leaves the row pending, which would loop. If the existing code has any reason a mismatch row could fail validation (`validate_required([:title])` only), log it and stamp the row with `Repo.update_all` on `path_mapping_searched_at` instead. With the current changeset this cannot happen, so keep the simple version.

- [ ] **Step 4: Enqueue at boot**

In `lib/mydia/application.ex`, directly after `Mydia.Jobs.HdrBackfill.enqueue_once()`:

```elixir
        # One-shot: stored path-mapping suggestions for downloads that failed
        # with a mount mismatch before suggestions were stored (#1315).
        # Idempotent by row state; enqueue_once/0 never raises.
        Mydia.Jobs.PathMappingSuggestionBackfill.enqueue_once()
```

- [ ] **Step 5: Run the tests**

Run: `./dev mix test test/mydia/jobs/path_mapping_suggestion_backfill_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/mydia/jobs/path_mapping_suggestion_backfill.ex lib/mydia/application.ex test/mydia/jobs/path_mapping_suggestion_backfill_test.exs
direnv exec . git commit -m "feat(import): backfill path-mapping suggestions for earlier failures"
```

---

### Task 6: Full verification and PR

**Files:** none new.

- [ ] **Step 1: Run every test that touches the changed modules**

Run: `./dev mix test test/mydia/library test/mydia/jobs/media_import_test.exs test/mydia/jobs/media_import test/mydia/jobs/path_mapping_suggestion_backfill_test.exs test/mydia/downloads test/mydia_web/live/downloads_live test/mydia_web/live/admin_path_mappings_live test/mydia/repo`
Expected: PASS.

- [ ] **Step 2: Check the mobile sweep seed still makes sense**

`test/support/mobile_layout_seed.ex` points library paths at a missing directory to dodge the walk (#1313). Leave that in place: it is still a valid seed. Run: `./dev mix test test/mydia_web/mobile_layout_seed_test.exs`
Expected: PASS.

- [ ] **Step 3: Run precommit**

Run: `./dev mix precommit`. It can outrun the 600s Bash cap. If it does, run `./dev mix compile --warnings-as-errors`, `./dev mix format --check-formatted` and `./dev mix credo --strict` separately, then the test suite in chunks.
Expected: clean. Fix anything it reports in the files above and commit the fix as its own step.

- [ ] **Step 4: Check history and co-changes**

Run: `git log --oneline origin/master..HEAD` (expect the spec, plan and five feature commits) and `git diff --stat origin/master...HEAD` (expect only the files in the File Structure table plus the tests, spec and plan). If Repowise is available, run `get_risk` with `changed_files` set to `git diff --name-only origin/master...` and account for any `missing_cochanges`.

- [ ] **Step 5: Push and open the PR**

```bash
git push -u origin HEAD:fix/path-mapping-suggestion-at-failure
gh pr create --repo getmydia/mydia --base master --head fix/path-mapping-suggestion-at-failure \
  --title "Compute path-mapping suggestions when the import fails" \
  --body "Fixes #1315. ..."
```

The PR body explains the problem (the walk ran inside the LiveView on every reload), the fix (computed once in the background, stored, read at render), the backfill for existing rows, and the AE3 test change. Leave auto-merge off. Watch CI and CodeRabbit until green, then merge by hand with a merge commit (never squash).
