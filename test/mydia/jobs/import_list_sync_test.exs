defmodule Mydia.Jobs.ImportListSyncTest do
  @moduledoc """
  Covers `Mydia.Jobs.ImportListSync`, previously untested.

  Oban is not started in the test environment (`config :mydia, Oban,
  testing: :manual, engine: false, queues: false, plugins: false`), so
  `perform/1` is called directly with a hand-built `%Oban.Job{}` rather than
  through `Oban.Testing`'s `perform_job/2` helper (this project's other job
  tests follow the same pattern, see e.g.
  `test/mydia/jobs/import_run_job_test.exs`).

  `auto_add` is left `false` on every fixture list here deliberately: when
  true, `perform/1` calls `Mydia.Jobs.ImportListAutoAdd.enqueue/1`, which
  calls `Oban.insert/1` directly. With no Oban supervisor running in test,
  that raises `RuntimeError` (see `Oban.Registry.config/1`), so exercising
  that branch would crash the test rather than exercise anything meaningful.
  The auto-add worker itself is covered independently in
  `import_list_auto_add_test.exs`.

  A `tmdb_trending` list (the TMDB provider) is used throughout rather than
  `custom_url`: `Mydia.ImportLists.Provider.CustomURL` fetches from a
  caller-supplied URL and rejects loopback/private addresses by default (an
  SSRF guard, see `import_lists_allow_private_destinations` in
  `test/mydia/import_lists/provider/custom_url_test.exs`), which is exactly
  what Bypass binds to. The TMDB provider instead goes through the
  metadata-relay client, which has no such guard and is the same seam
  `test/mydia/jobs/metadata_refresh_test.exs` already points at Bypass via
  `Application.put_env(:mydia, :metadata_relay_url, ...)`.

  `async: false` for the same reason as that module: overriding
  `:metadata_relay_url` mutates global application config.
  """

  use Mydia.DataCase, async: false

  alias Mydia.ImportLists
  alias Mydia.Jobs.ImportListSync

  defp job(args) do
    %Oban.Job{args: args, attempt: 1, max_attempts: 3}
  end

  defp tmdb_trending_list(bypass, attrs \\ %{}) do
    previous_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)

    {:ok, list} =
      %{
        name: "Trending Movies",
        type: "tmdb_trending",
        media_type: "movie",
        enabled: true
      }
      |> Map.merge(attrs)
      |> ImportLists.create_import_list()

    list
  end

  defp stub_trending(bypass, results) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/trending", fn conn ->
      body = %{
        "page" => 1,
        "total_pages" => 1,
        "total_results" => length(results),
        "results" => results
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_trending_error(bypass, status) do
    Bypass.stub(bypass, "GET", "/tmdb/movies/trending", fn conn ->
      Plug.Conn.resp(conn, status, Jason.encode!(%{"error" => "boom"}))
    end)
  end

  describe "perform/1" do
    test "returns :ok without error when the import list no longer exists" do
      assert :ok = ImportListSync.perform(job(%{"import_list_id" => Ecto.UUID.generate()}))
    end

    test "returns :ok and touches nothing for a disabled list" do
      {:ok, list} =
        ImportLists.create_import_list(%{
          name: "Disabled List",
          type: "tmdb_trending",
          media_type: "movie",
          enabled: false
        })

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      reloaded = ImportLists.get_import_list!(list.id)
      assert reloaded.last_synced_at == nil
      assert reloaded.sync_error == nil
      assert ImportLists.list_import_list_items(reloaded) == []
    end

    test "fetches items, creates them as pending, and marks the sync successful" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)

      stub_trending(bypass, [
        %{"id" => 111, "title" => "Aurora Rising", "release_date" => "2023-05-01"},
        %{"id" => 222, "title" => "Glass Horizon", "release_date" => "2021-11-20"}
      ])

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      reloaded = ImportLists.get_import_list!(list.id)
      assert reloaded.last_synced_at != nil
      assert reloaded.sync_error == nil

      items = ImportLists.list_import_list_items(reloaded)
      assert length(items) == 2
      assert Enum.all?(items, &(&1.status == "pending"))
    end

    test "broadcasts new-item stats on the first sync and updated-item stats on a re-sync" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)

      stub_trending(bypass, [
        %{"id" => 111, "title" => "Aurora Rising", "release_date" => "2023-05-01"},
        %{"id" => 222, "title" => "Glass Horizon", "release_date" => "2021-11-20"}
      ])

      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_lists")

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      assert_receive {:import_list_sync_complete, list_id, {:ok, first_stats}}
      assert list_id == list.id
      assert first_stats.new == 2
      assert first_stats.updated == 0
      assert first_stats.total == 2

      # Same feed, same tmdb_ids: every item now matches an existing row
      # (Bug 2: the old code checked `is_binary(id)`, which is true for
      # both an insert and an update, so it reported every item as new
      # every time).
      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      assert_receive {:import_list_sync_complete, ^list_id, {:ok, second_stats}}
      assert second_stats.new == 0
      assert second_stats.updated == 2
      assert second_stats.total == 2

      # Still only two rows: the second sync updated in place, it didn't
      # duplicate (Bug 4: a select-then-write upsert could otherwise race
      # or double-insert under concurrent syncs).
      assert length(ImportLists.list_import_list_items(list)) == 2
    end

    test "a changed title on re-sync updates the cached display field" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)

      stub_trending(bypass, [
        %{"id" => 111, "title" => "Working Title", "release_date" => "2023-05-01"}
      ])

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      stub_trending(bypass, [
        %{"id" => 111, "title" => "Final Title", "release_date" => "2023-05-01"}
      ])

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      [item] = ImportLists.list_import_list_items(list)
      assert item.title == "Final Title"
    end

    test "records a sync error and applies backoff instead of retrying at the next tick" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)
      stub_trending_error(bypass, 400)

      Phoenix.PubSub.subscribe(Mydia.PubSub, "import_lists")

      assert {:error, _reason} = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      assert_receive {:import_list_sync_complete, list_id, {:error, _reason}}
      assert list_id == list.id

      reloaded = ImportLists.get_import_list!(list.id)
      assert reloaded.last_synced_at == nil
      assert reloaded.sync_error != nil
      assert reloaded.config["consecutive_failures"] == 1

      # The core bug: before the fix, sync_due?/1 stayed true immediately
      # after a failure, so the cron's 15-minute tick would re-enqueue this
      # list every single time forever, ignoring sync_interval entirely.
      refute ImportLists.sync_due?(reloaded)
    end

    test "repeated failures grow the consecutive failure count" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)
      stub_trending_error(bypass, 400)

      assert {:error, _} = ImportListSync.perform(job(%{"import_list_id" => list.id}))
      once = ImportLists.get_import_list!(list.id)
      assert once.config["consecutive_failures"] == 1

      assert {:error, _} = ImportListSync.perform(job(%{"import_list_id" => list.id}))
      twice = ImportLists.get_import_list!(list.id)
      assert twice.config["consecutive_failures"] == 2
    end

    test "a successful sync after prior failures clears the error and resets backoff" do
      bypass = Bypass.open()
      list = tmdb_trending_list(bypass)
      stub_trending_error(bypass, 400)

      assert {:error, _reason} = ImportListSync.perform(job(%{"import_list_id" => list.id}))
      failed = ImportLists.get_import_list!(list.id)
      assert failed.config["consecutive_failures"] == 1

      stub_trending(bypass, [
        %{"id" => 111, "title" => "Aurora Rising", "release_date" => "2023-05-01"}
      ])

      assert :ok = ImportListSync.perform(job(%{"import_list_id" => list.id}))

      recovered = ImportLists.get_import_list!(list.id)
      assert recovered.sync_error == nil
      refute Map.has_key?(recovered.config, "consecutive_failures")
    end
  end
end
