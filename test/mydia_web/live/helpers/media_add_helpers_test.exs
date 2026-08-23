defmodule MydiaWeb.Live.Helpers.MediaAddHelpersTest do
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias MydiaWeb.Live.Helpers.MediaAddHelpers
  alias Mydia.Metadata.Structs.MediaMetadata

  describe "build_media_item_attrs/3 provenance stamping" do
    test "stamps metadata_source for TV shows" do
      metadata = %MediaMetadata{
        provider_id: "100",
        provider: :tmdb,
        media_type: :tv_show,
        title: "Stamp Show",
        first_air_date: ~D[2019-01-01]
      }

      attrs = MediaAddHelpers.build_media_item_attrs(metadata, :tv_show, metadata_source: :tmdb)

      assert attrs.metadata_source == :tmdb
      assert attrs.type == "tv_show"
    end

    test "carries a nil metadata_source through for TV shows (conflict case)" do
      metadata = %MediaMetadata{
        provider_id: "100",
        provider: :tmdb,
        media_type: :tv_show,
        title: "Conflict Show",
        first_air_date: ~D[2019-01-01]
      }

      attrs = MediaAddHelpers.build_media_item_attrs(metadata, :tv_show, metadata_source: nil)

      assert Map.has_key?(attrs, :metadata_source)
      assert attrs.metadata_source == nil
    end

    test "never sets metadata_source for movies" do
      metadata = %MediaMetadata{
        provider_id: "100",
        provider: :tmdb,
        media_type: :movie,
        title: "A Movie",
        release_date: ~D[2019-01-01]
      }

      attrs = MediaAddHelpers.build_media_item_attrs(metadata, :movie, metadata_source: :tmdb)

      refute Map.has_key?(attrs, :metadata_source)
      assert attrs.type == "movie"
    end
  end

  describe "build_media_item_attrs/3 inherited settings" do
    defp movie_metadata do
      %MediaMetadata{
        provider_id: "672",
        provider: :tmdb,
        media_type: :movie,
        title: "Chamber of Secrets",
        release_date: ~D[2002-11-13]
      }
    end

    test "defaults to monitored with no quality profile" do
      attrs = MediaAddHelpers.build_media_item_attrs(movie_metadata(), :movie)

      assert attrs.monitored == true
      refute Map.has_key?(attrs, :quality_profile_id)
    end

    test "honours an explicit monitored flag" do
      attrs = MediaAddHelpers.build_media_item_attrs(movie_metadata(), :movie, monitored: false)

      assert attrs.monitored == false
    end

    test "sets the quality profile when one is given" do
      attrs =
        MediaAddHelpers.build_media_item_attrs(movie_metadata(), :movie, quality_profile_id: 42)

      assert attrs.quality_profile_id == 42
    end

    test "omits the quality profile when it is nil" do
      attrs =
        MediaAddHelpers.build_media_item_attrs(movie_metadata(), :movie, quality_profile_id: nil)

      refute Map.has_key?(attrs, :quality_profile_id)
    end
  end

  describe "handle_add_media_to_library/4 derives provider and stamps provenance" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "single TMDB library: stamps :tmdb, keeps tmdb_id, resolves secondary tvdb_id",
         %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      id = System.unique_integer([:positive])
      tvdb_id = System.unique_integer([:positive])

      stub_tmdb_show(bypass, id, "TMDB Lib Show", 2019)
      stub_tvdb_search(bypass, tvdb_id, "TMDB Lib Show", 2019)

      assert {:ok, item, _map} =
               MediaAddHelpers.handle_add_media_to_library(to_string(id), :tv_show, %{}, config)

      assert item.type == "tv_show"
      assert item.metadata_source == :tmdb
      assert item.tmdb_id == id
      assert item.tvdb_id == tvdb_id
    end

    test "single TVDB library: stamps :tvdb with TVDB-sourced ids",
         %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})

      tmdb_id = System.unique_integer([:positive])
      tvdb_id = System.unique_integer([:positive])

      stub_tmdb_show(bypass, tmdb_id, "TVDB Lib Show", 2019)
      stub_tvdb_search(bypass, tvdb_id, "TVDB Lib Show", 2019)
      stub_tvdb_extended(bypass, tvdb_id, "TVDB Lib Show")

      assert {:ok, item, _map} =
               MediaAddHelpers.handle_add_media_to_library(
                 to_string(tmdb_id),
                 :tv_show,
                 %{},
                 config
               )

      assert item.metadata_source == :tvdb
      assert item.tmdb_id == tmdb_id
      assert item.tvdb_id == tvdb_id
    end

    test "no TV libraries: defaults to :tvdb", %{bypass: bypass, config: config} do
      tmdb_id = System.unique_integer([:positive])

      stub_tmdb_show(bypass, tmdb_id, "No Lib Show", 2019)
      # Empty TVDB search → resolve falls back to TMDB content, source still :tvdb
      stub_tvdb_search_empty(bypass)

      assert {:ok, item, _map} =
               MediaAddHelpers.handle_add_media_to_library(
                 to_string(tmdb_id),
                 :tv_show,
                 %{},
                 config
               )

      assert item.metadata_source == :tvdb
      assert item.tmdb_id == tmdb_id
    end

    test "conflicting TV libraries: leaves metadata_source nil",
         %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      tmdb_id = System.unique_integer([:positive])

      stub_tmdb_show(bypass, tmdb_id, "Conflict Lib Show", 2019)
      stub_tvdb_search_empty(bypass)

      assert {:ok, item, _map} =
               MediaAddHelpers.handle_add_media_to_library(
                 to_string(tmdb_id),
                 :tv_show,
                 %{},
                 config
               )

      assert item.metadata_source == nil
      assert item.tmdb_id == tmdb_id
    end

    test "movie: leaves metadata_source nil", %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "movies"})

      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "A Movie", 2019)

      assert {:ok, item, _map} =
               MediaAddHelpers.handle_add_media_to_library(to_string(id), :movie, %{}, config)

      assert item.type == "movie"
      assert item.metadata_source == nil
      assert item.tmdb_id == id
    end
  end

  describe "handle_add_media_to_library/4 already in library" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    # This is the tuple shape DiscoverLive and DashboardLive pattern-match on
    # in their `{:add_media_to_library, ...}` handle_info clauses. A drift
    # here (arity, atom, tuple position) falls through to their `case`
    # clauses undetected by any compiler check.
    test "returns {:already_in_library, item, updated_map} instead of an error",
         %{bypass: bypass, config: config} do
      id = System.unique_integer([:positive])

      existing =
        Mydia.MediaFixtures.media_item_fixture(%{
          type: "movie",
          title: "Already Added",
          tmdb_id: id
        })

      stub_tmdb_movie(bypass, id, "Already Added", 2019)

      assert {:already_in_library, item, updated_map} =
               MediaAddHelpers.handle_add_media_to_library(to_string(id), :movie, %{}, config)

      assert item.id == existing.id
      assert updated_map[id][:in_library] == true
    end
  end

  describe "fetch_detail_metadata/3 reflects the derived source" do
    setup do
      bypass = Bypass.open()

      config = %{
        type: :metadata_relay,
        base_url: "http://localhost:#{bypass.port}",
        options: %{language: "en-US", include_adult: false}
      }

      %{bypass: bypass, config: config}
    end

    test "returns TMDB metadata directly when derived source is :tmdb",
         %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      id = System.unique_integer([:positive])
      stub_tmdb_show(bypass, id, "Preview Show", 2019)

      assert {:ok, metadata} =
               MediaAddHelpers.fetch_detail_metadata(to_string(id), :tv_show, config)

      assert metadata.title == "Preview Show"
    end
  end

  # Stub helpers (relay endpoints)

  defp stub_tmdb_show(bypass, id, name, year) do
    body = %{
      "id" => id,
      "name" => name,
      "first_air_date" => "#{year}-01-01",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "genres" => [],
      # Empty on purpose: these tests assert provenance stamping, not episode
      # import. A non-empty seasons list would drive refresh_episodes_for_tv_show
      # into per-season Bypass calls that the stubs do not cover.
      "seasons" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tmdb_movie(bypass, id, title, year) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "#{year}-01-01",
      "overview" => "x",
      "credits" => %{"cast" => [], "crew" => []},
      "genres" => []
    }

    Bypass.stub(bypass, "GET", "/tmdb/movies/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tvdb_search(bypass, tvdb_id, name, year) do
    body = %{"data" => [%{"tvdb_id" => tvdb_id, "name" => name, "year" => "#{year}"}]}

    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tvdb_search_empty(bypass) do
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
    end)
  end

  defp stub_tvdb_extended(bypass, id, name) do
    body = %{
      "data" => %{
        "id" => id,
        "tvdb_id" => id,
        "name" => name,
        "overview" => "test overview",
        "first_air_date" => "2019-01-01",
        "genres" => [],
        "seasons" => []
      }
    }

    Bypass.stub(bypass, "GET", "/tvdb/series/#{id}/extended", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  describe "library picker assigns" do
    defp socket do
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, library_picker: nil}}
    end

    test "opening reads the candidate libraries at open time" do
      library_path_fixture(%{path: "/media/picker-a", type: "movies"})
      library_path_fixture(%{path: "/media/picker-b", type: "movies"})

      updated =
        MediaAddHelpers.put_library_picker(socket(), %{
          "tmdb_id" => "693134",
          "media_type" => "movie",
          "title" => "Dune: Part Two"
        })

      picker = updated.assigns.library_picker

      assert picker.tmdb_id == "693134"
      assert picker.media_type == :movie
      assert picker.title == "Dune: Part Two"
      assert length(picker.libraries) == 2
    end

    test "a missing title becomes an empty string rather than nil" do
      library_path_fixture(%{path: "/media/picker-c", type: "movies"})
      library_path_fixture(%{path: "/media/picker-d", type: "movies"})

      updated =
        MediaAddHelpers.put_library_picker(socket(), %{
          "tmdb_id" => "1",
          "media_type" => "movie"
        })

      assert updated.assigns.library_picker.title == ""
    end

    test "an unrecognised media type opens nothing" do
      updated =
        MediaAddHelpers.put_library_picker(socket(), %{
          "tmdb_id" => "1",
          "media_type" => "podcast"
        })

      assert updated.assigns.library_picker == nil
    end

    test "clearing closes the dialog" do
      opened = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, library_picker: %{tmdb_id: "1"}}
      }

      assert MediaAddHelpers.clear_library_picker(opened).assigns.library_picker == nil
    end
  end
end
