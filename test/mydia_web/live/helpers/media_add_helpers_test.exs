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
      stub_tmdb_season(bypass, id, 1, [1])
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
      "seasons" => [%{"season_number" => 1, "name" => "Season 1"}]
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tmdb_season(bypass, id, season_number, episode_numbers) do
    episodes =
      Enum.map(episode_numbers, fn n ->
        %{
          "season_number" => season_number,
          "episode_number" => n,
          "name" => "Episode #{n}",
          "air_date" => "2019-01-0#{n}"
        }
      end)

    body = %{"season_number" => season_number, "episodes" => episodes}

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}/#{season_number}", fn conn ->
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
end
