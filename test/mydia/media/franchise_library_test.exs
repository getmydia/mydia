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

  test "a local sibling with a pointer decides without fetching the collection",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_movie(bypass, id, cid)
    lib = library_path_fixture(%{type: "movies"})
    sibling(tmdb_id(), cid, %{library_path_id: lib.id})

    # No collection stub: a request to it would fail the test via Bypass.
    assert FranchiseLibrary.library_for(id, config) == lib.id
  end

  test "falls back to the collection parts and backfills the pointer",
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
    stub_movie(bypass, id, cid)
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
    stub_movie(bypass, id, cid)
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
    stub_movie(bypass, id, cid)
    lib = library_path_fixture(%{type: "movies"})
    owned = sibling(tmdb_id(), cid, %{})
    media_file_fixture(%{media_item_id: owned.id, library_path_id: lib.id})

    assert FranchiseLibrary.library_for(id, config) == lib.id
  end

  test "a sibling with no files and no explicit library does not vote",
       %{bypass: bypass, config: config} do
    cid = System.unique_integer([:positive])
    id = tmdb_id()
    stub_movie(bypass, id, cid)
    default = library_path_fixture(%{type: "movies"})
    Mydia.Settings.set_default_library(default, :movies)
    sibling(tmdb_id(), cid, %{})

    assert FranchiseLibrary.library_for(id, config) == nil
  end

  test "a relay error returns nil", %{bypass: bypass, config: config} do
    id = tmdb_id()
    on_exit(fn -> Cache.delete("fetch_by_ref:tmdb:#{id}:movie:en-US::official") end)

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      Plug.Conn.resp(conn, 500, "boom")
    end)

    ExUnit.CaptureLog.capture_log(fn ->
      assert FranchiseLibrary.library_for(id, config) == nil
    end)
  end
end
