defmodule Mydia.Media.FranchiseLibraryTest do
  use Mydia.DataCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Media
  alias Mydia.Media.FranchiseLibrary
  alias Mydia.Metadata.Cache

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  # The movie being added: the relay reports which collection it belongs to.
  defp stub_movie(bypass, tmdb_id, collection_id) do
    on_exit(fn -> Cache.delete("fetch_by_ref:tmdb:#{tmdb_id}:movie:en-US::official") end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{tmdb_id}", fn conn ->
      body =
        %{
          "id" => tmdb_id,
          "title" => "Starfall Protocol #{tmdb_id}",
          "release_date" => "2001-01-01",
          "credits" => %{"cast" => [], "crew" => []}
        }
        |> then(fn b ->
          if collection_id,
            do:
              Map.put(b, "belongs_to_collection", %{"id" => collection_id, "name" => "Starfall"}),
            else: b
        end)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_collection(bypass, collection_id, part_ids) do
    on_exit(fn -> Cache.delete("collection:metadata_relay:#{collection_id}:en-US") end)

    Bypass.stub(bypass, "GET", "/tmdb/collections/#{collection_id}", fn conn ->
      body = %{
        "id" => collection_id,
        "name" => "Starfall",
        "parts" =>
          Enum.map(
            part_ids,
            &%{"id" => &1, "title" => "Part #{&1}", "release_date" => "2001-01-01"}
          )
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  # A franchise whose siblings all carry the pointer locally. The collection is
  # always fetched, so it needs a stub; Bypass fails the test on an unstubbed
  # request.
  defp stub_franchise(bypass, tmdb_id, collection_id) do
    stub_movie(bypass, tmdb_id, collection_id)
    stub_collection(bypass, collection_id, [tmdb_id])
  end

  defp sibling(tmdb_id, collection_id, attrs) do
    metadata =
      %{
        "provider_id" => to_string(tmdb_id),
        "provider" => "metadata_relay",
        "media_type" => "movie",
        "title" => "Starfall Protocol #{tmdb_id}"
      }
      |> then(fn m ->
        if collection_id,
          do: Map.merge(m, %{"collection_id" => collection_id, "collection_name" => "Starfall"}),
          else: m
      end)

    attrs
    |> Enum.into(%{
      type: "movie",
      title: "Starfall Protocol #{tmdb_id}",
      tmdb_id: tmdb_id,
      metadata: metadata
    })
    |> media_item_fixture()
  end

  defp tmdb_id, do: 900_000 + System.unique_integer([:positive])

  test "returns nil when the movie has no collection", %{bypass: bypass, config: config} do
    id = tmdb_id()
    stub_movie(bypass, id, nil)

    assert FranchiseLibrary.library_for(id, config) == nil
  end

  test "returns nil for a nil tmdb id" do
    assert FranchiseLibrary.library_for(nil) == nil
  end

  test "pointerless siblings found only through the parts outvote a pointer-bearing one",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    old_a = tmdb_id()
    old_b = tmdb_id()
    recent = tmdb_id()
    stub_movie(bypass, id, cid)
    stub_collection(bypass, cid, [id, old_a, old_b, recent])
    x = library_path_fixture(%{type: "movies"})
    y = library_path_fixture(%{type: "movies"})
    a = sibling(old_a, nil, %{library_path_id: x.id})
    b = sibling(old_b, nil, %{library_path_id: x.id})
    sibling(recent, cid, %{library_path_id: y.id})

    assert FranchiseLibrary.library_for(id, config) == x.id

    for item <- [a, b] do
      assert Media.get_media_item!(Scope.unrestricted(), item.id).metadata.collection_id == cid
    end
  end

  test "a failed collection fetch votes on the local siblings alone",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_movie(bypass, id, cid)

    Bypass.stub(bypass, "GET", "/tmdb/collections/#{cid}", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    lib = library_path_fixture(%{type: "movies"})
    sibling(tmdb_id(), cid, %{library_path_id: lib.id})

    ExUnit.CaptureLog.capture_log(fn ->
      assert FranchiseLibrary.library_for(id, config) == lib.id
    end)
  end

  test "a raise anywhere in the lookup returns nil" do
    # HTTP.new_request/1 raises on a config without a base URL.
    config = %{type: :metadata_relay, base_url: nil, options: %{language: "en-US"}}

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert FranchiseLibrary.library_for(tmdb_id(), config) == nil
      end)

    assert log =~ "Franchise library lookup raised"
  end

  test "finds siblings through the collection parts and backfills the pointer",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    other = tmdb_id()
    stub_movie(bypass, id, cid)
    stub_collection(bypass, cid, [id, other])
    lib = library_path_fixture(%{type: "movies"})
    owned = sibling(other, nil, %{library_path_id: lib.id})

    assert FranchiseLibrary.library_for(id, config) == lib.id

    reloaded = Media.get_media_item!(Scope.unrestricted(), owned.id)
    assert reloaded.metadata.collection_id == cid
  end

  test "the library holding most siblings wins", %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_franchise(bypass, id, cid)
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    sibling(tmdb_id(), cid, %{library_path_id: a.id})
    sibling(tmdb_id(), cid, %{library_path_id: a.id})
    sibling(tmdb_id(), cid, %{library_path_id: b.id})

    assert FranchiseLibrary.library_for(id, config) == a.id
  end

  test "a tie returns nil", %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_franchise(bypass, id, cid)
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    sibling(tmdb_id(), cid, %{library_path_id: a.id})
    sibling(tmdb_id(), cid, %{library_path_id: b.id})

    assert FranchiseLibrary.library_for(id, config) == nil
  end

  test "a sibling placed only by its files votes for that library",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_franchise(bypass, id, cid)
    lib = library_path_fixture(%{type: "movies"})
    owned = sibling(tmdb_id(), cid, %{})
    media_file_fixture(%{media_item_id: owned.id, library_path_id: lib.id})

    assert FranchiseLibrary.library_for(id, config) == lib.id
  end

  test "a sibling with no files and no explicit library does not vote",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_franchise(bypass, id, cid)
    default = library_path_fixture(%{type: "movies"})
    Mydia.Settings.set_default_library(default, :movies)
    sibling(tmdb_id(), cid, %{})

    assert FranchiseLibrary.library_for(id, config) == nil
  end

  test "a relay error returns nil", %{bypass: bypass, config: config} do
    id = tmdb_id()
    on_exit(fn -> Cache.delete("fetch_by_ref:tmdb:#{id}:movie:en-US::official") end)

    test_pid = self()

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      send(test_pid, :relay_hit)
      Plug.Conn.resp(conn, 500, "boom")
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert FranchiseLibrary.library_for(id, config) == nil
    end)
  end

  test "the relay config is bounded: short timeouts and no retries" do
    options =
      FranchiseLibrary.bounded(%{base_url: "http://x", options: %{language: "en-US"}}).options

    assert options.max_retries == 0
    assert options.timeout == 3_000
    assert options.connect_timeout == 3_000
    assert options.language == "en-US"
  end

  test "a slow relay returns nil at the overall deadline", %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    on_exit(fn -> Cache.delete("fetch_by_ref:tmdb:#{id}:movie:en-US::official") end)

    # Each call is under its own 3s timeout; together they exceed the deadline.
    # Bypass.pass/1 before the sleep: the deadline kills the client mid-request,
    # which makes Cowboy tear the handler down with :shutdown, and Bypass would
    # otherwise re-raise that as a test crash (see indexers_test.exs).
    Bypass.expect(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      Bypass.pass(bypass)
      Process.sleep(2_000)

      body = %{
        "id" => id,
        "title" => "Starfall Protocol #{id}",
        "release_date" => "2001-01-01",
        "belongs_to_collection" => %{"id" => cid, "name" => "Starfall"},
        "credits" => %{"cast" => [], "crew" => []}
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)

    Bypass.expect(bypass, "GET", "/tmdb/collections/#{cid}", fn conn ->
      Bypass.pass(bypass)
      Process.sleep(2_000)

      Plug.Conn.resp(
        conn,
        200,
        Jason.encode!(%{"id" => cid, "name" => "Starfall", "parts" => []})
      )
    end)

    on_exit(fn -> Cache.delete("collection:metadata_relay:#{cid}:en-US") end)

    started = System.monotonic_time(:millisecond)

    ExUnit.CaptureLog.capture_log(fn ->
      assert FranchiseLibrary.library_for(id, config) == nil
    end)

    elapsed = System.monotonic_time(:millisecond) - started
    assert elapsed >= 2_900
    assert elapsed < 3_800
  end

  test "the movie being added never votes", %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_franchise(bypass, id, cid)
    a = library_path_fixture(%{type: "movies"})
    b = library_path_fixture(%{type: "movies"})
    sibling(id, cid, %{library_path_id: a.id})
    sibling(tmdb_id(), cid, %{library_path_id: b.id})

    assert FranchiseLibrary.library_for(id, config) == b.id
  end
end
