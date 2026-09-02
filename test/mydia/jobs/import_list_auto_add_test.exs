defmodule Mydia.Jobs.ImportListAutoAddTest do
  @moduledoc """
  Covers `Mydia.Jobs.ImportListAutoAdd`, previously untested.

  Oban is not started in the test environment, so `perform/1` is called
  directly with a hand-built `%Oban.Job{}`, matching the pattern in
  `import_list_sync_test.exs` and `test/mydia/jobs/import_run_job_test.exs`.

  Network isolation follows `test/mydia/jobs/metadata_refresh_test.exs`:
  `Application.put_env(:mydia, :metadata_relay_url, ...)` points the relay
  client at a local Bypass server, so this is `async: false` for the same
  reason that module is (mutating global config). Tests that only exercise
  the already-in-library branch never reach the network at all, since
  `check_duplicate/4`'s tmdb_id/title/year matching short-circuits before
  any metadata fetch.
  """

  use Mydia.DataCase, async: false

  alias Mydia.ImportLists
  alias Mydia.Jobs.ImportListAutoAdd

  import Mydia.MediaFixtures

  defp job(args) do
    %Oban.Job{args: args, attempt: 1, max_attempts: 3}
  end

  defp movie_list(attrs \\ %{}) do
    {:ok, list} =
      %{name: "Test List", type: "tmdb_trending", media_type: "movie", enabled: true}
      |> Map.merge(attrs)
      |> ImportLists.create_import_list()

    list
  end

  defp pending_item(list, attrs) do
    {:ok, item} =
      %{import_list_id: list.id, discovered_at: DateTime.utc_now()}
      |> Map.merge(attrs)
      |> ImportLists.create_import_list_item()

    item
  end

  defp point_relay_at(bypass) do
    previous_url = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      case previous_url do
        nil -> Application.delete_env(:mydia, :metadata_relay_url)
        value -> Application.put_env(:mydia, :metadata_relay_url, value)
      end
    end)
  end

  describe "perform/1" do
    test "returns :ok without error when the import list no longer exists" do
      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => Ecto.UUID.generate()}))
    end

    test "returns :ok and does nothing when there are no pending items" do
      list = movie_list()

      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))
    end

    test "an item already in the library (matched by tmdb_id) is linked in a single write, never hits the network" do
      list = movie_list()

      media_item =
        media_item_fixture(%{type: "movie", title: "Nebula Drift", year: 2022, tmdb_id: 777})

      item = pending_item(list, %{tmdb_id: 777, title: "Nebula Drift", year: 2022})

      # No Bypass/relay override configured at all: if this reached the
      # network it would either fail to connect or hit RelayGuard's escape
      # tracker (see test/test_helper.exs), not silently succeed.
      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "added"
      assert reloaded.media_item_id == media_item.id
      # The wasted intermediate skip write must be gone: mark_item_skipped/2
      # followed immediately by mark_item_added/2 always ended up "added"
      # anyway, so the row is honestly added, not "skipped" with the write
      # thrown away.
      assert reloaded.skip_reason == nil
    end

    test "an item already in the library matched only via the title+year fallback is linked" do
      list = movie_list()

      media_item =
        media_item_fixture(%{type: "movie", title: "Silverback Station", year: 2019})

      # No tmdb_id on the library row (e.g. it came from a filesystem scan),
      # so only the title+year fallback in check_duplicate/4 can find it.
      item = pending_item(list, %{tmdb_id: 9001, title: "Silverback Station", year: 2019})

      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "added"
      assert reloaded.media_item_id == media_item.id
    end

    test "creates a new media item from relay metadata when nothing matches" do
      bypass = Bypass.open()
      point_relay_at(bypass)

      list = movie_list()
      tmdb_id = 424_242

      Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
        body = %{
          "id" => tmdb_id,
          "title" => "Halcyon Fields",
          "release_date" => "2024-03-15",
          "credits" => %{"cast" => [], "crew" => []},
          "external_ids" => %{"imdb_id" => "tt9999999"}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      item = pending_item(list, %{tmdb_id: tmdb_id, title: "Halcyon Fields", year: 2024})

      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))

      reloaded = ImportLists.get_import_list_item!(item.id)
      assert reloaded.status == "added"
      refute is_nil(reloaded.media_item_id)

      media_item = Mydia.Media.get_media_item!(reloaded.media_item_id)
      assert media_item.title == "Halcyon Fields"
    end

    test "marks the item failed when the metadata fetch fails, and keeps processing the rest" do
      bypass = Bypass.open()
      point_relay_at(bypass)

      list = movie_list()

      Bypass.stub(bypass, "GET", "/tmdb/movies/424243", fn conn ->
        Plug.Conn.resp(conn, 404, Jason.encode!(%{"error" => "not found"}))
      end)

      Bypass.stub(bypass, "GET", "/tmdb/movies/424244", fn conn ->
        body = %{
          "id" => 424_244,
          "title" => "Working Item",
          "release_date" => "2024-01-01",
          "credits" => %{"cast" => [], "crew" => []}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      failing = pending_item(list, %{tmdb_id: 424_243, title: "Missing Movie", year: 2024})
      working = pending_item(list, %{tmdb_id: 424_244, title: "Working Item", year: 2024})

      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))

      reloaded_failing = ImportLists.get_import_list_item!(failing.id)
      assert reloaded_failing.status == "failed"

      reloaded_working = ImportLists.get_import_list_item!(working.id)
      assert reloaded_working.status == "added"
    end

    test "only processes pending items, leaving already-added or skipped items alone" do
      list = movie_list()

      already_added_media = media_item_fixture(%{type: "movie", title: "Old News", year: 2020})

      already_added =
        pending_item(list, %{
          tmdb_id: 1,
          title: "Old News",
          year: 2020,
          status: "added",
          media_item_id: already_added_media.id
        })

      already_skipped =
        pending_item(list, %{
          tmdb_id: 2,
          title: "Ignored",
          year: 2021,
          status: "skipped",
          skip_reason: "manual"
        })

      assert :ok = ImportListAutoAdd.perform(job(%{"import_list_id" => list.id}))

      assert ImportLists.get_import_list_item!(already_added.id).status == "added"
      assert ImportLists.get_import_list_item!(already_skipped.id).status == "skipped"
    end
  end
end
