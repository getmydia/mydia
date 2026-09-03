defmodule MydiaWeb.Live.Helpers.MediaAddHelpersTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
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
               MediaAddHelpers.handle_add_media_to_library({:tmdb, id}, :tv_show, %{}, config)

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
                 {:tmdb, tmdb_id},
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
                 {:tmdb, tmdb_id},
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
                 {:tmdb, tmdb_id},
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
               MediaAddHelpers.handle_add_media_to_library({:tmdb, id}, :movie, %{}, config)

      assert item.type == "movie"
      assert item.metadata_source == nil
      assert item.tmdb_id == id
    end

    # TMDB and TVDB number their catalogs independently, so a TVDB add's own
    # numeric id can collide with an unrelated TMDB title's id.
    # `update_library_status_map/2` used to write that bare id into the
    # untagged (TMDB) key space, which `enrich_with_library_status/2` reads
    # before the tagged `{:tvdb, id}` key -- a TMDB result sharing that
    # integer would then render as already in the library.
    test "TVDB add does not leak its id into the untagged (TMDB) key space",
         %{bypass: bypass, config: config} do
      tvdb_id = System.unique_integer([:positive])
      stub_tvdb_extended(bypass, tvdb_id, "TVDB Only Show")

      assert {:ok, item, updated_map} =
               MediaAddHelpers.handle_add_media_to_library(
                 {:tvdb, tvdb_id},
                 :tv_show,
                 %{},
                 config
               )

      assert item.tvdb_id == tvdb_id
      assert item.tmdb_id == nil
      assert updated_map[{:tvdb, tvdb_id}][:in_library] == true
      refute Map.has_key?(updated_map, tvdb_id)
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
               MediaAddHelpers.handle_add_media_to_library({:tmdb, id}, :movie, %{}, config)

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
               MediaAddHelpers.fetch_detail_metadata({:tmdb, id}, :tv_show, config)

      assert metadata.title == "Preview Show"
    end

    # A Discover TV search result is TVDB-sourced: `Relay.search/3` routes
    # `:tv_show` to `/tvdb/search`, so the ref the preview is opened with tags
    # a TVDB series id. Asking TMDB for it is a 404, which left every TV search
    # result's preview panel blank. Same root cause as the add failing with
    # "Media not found: <tvdb id>".
    test "a tvdb ref fetches from TVDB", %{bypass: bypass, config: config} do
      library_path_fixture(%{type: "series", tv_metadata_source: :tvdb})

      id = System.unique_integer([:positive])
      stub_tvdb_extended(bypass, id, "Harbour Lights")

      Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{id}", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(404, Jason.encode!(%{"error" => "not found"}))
      end)

      assert {:ok, metadata} =
               MediaAddHelpers.fetch_detail_metadata({:tvdb, id}, :tv_show, config)

      assert metadata.title == "Harbour Lights"
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

  describe "library_path_opts/2" do
    test "returns no options when no library was chosen" do
      assert {:ok, []} = MediaAddHelpers.library_path_opts(nil, :movie)
    end

    test "returns no options for a blank string" do
      # "" is truthy in Elixir. Without an explicit clause it reaches the
      # changeset as library_path_id: "" and fails the foreign key, instead of
      # falling back to normal target resolution.
      assert {:ok, []} = MediaAddHelpers.library_path_opts("", :movie)
    end

    test "keeps an id that is a candidate for this media type" do
      library = library_path_fixture(%{path: "/media/opts-a", type: "movies"})

      assert {:ok, opts} = MediaAddHelpers.library_path_opts(to_string(library.id), :movie)
      assert Keyword.fetch!(opts, :library_path_id) == to_string(library.id)
    end

    test "rejects a library belonging to the other media type" do
      series = library_path_fixture(%{path: "/media/opts-series", type: "series"})

      assert {:error, :unknown_library} =
               MediaAddHelpers.library_path_opts(to_string(series.id), :movie)
    end

    test "rejects an unmonitored library" do
      unmonitored =
        library_path_fixture(%{path: "/media/opts-off", type: "movies", monitored: false})

      assert {:error, :unknown_library} =
               MediaAddHelpers.library_path_opts(to_string(unmonitored.id), :movie)
    end

    test "rejects an id matching no library at all" do
      # library_path_id is client input. Without the candidate check a crafted
      # event can name any row in the table.
      assert {:error, :unknown_library} =
               MediaAddHelpers.library_path_opts(Ecto.UUID.generate(), :movie)
    end

    test "rejects a map value instead of silently treating it as no choice" do
      # #458: a crafted event sending a non-binary library_path_id must not be
      # swallowed by the catch-all as "no library was selected".
      assert {:error, :unknown_library} =
               MediaAddHelpers.library_path_opts(%{"id" => "1"}, :movie)
    end

    test "rejects a list value instead of silently treating it as no choice" do
      assert {:error, :unknown_library} = MediaAddHelpers.library_path_opts(["1"], :movie)
    end

    test "rejects an integer value instead of silently treating it as no choice" do
      assert {:error, :unknown_library} = MediaAddHelpers.library_path_opts(1, :movie)
    end
  end

  describe "preview_for/3" do
    test "reads title, year, poster and overview off a SearchResult" do
      item = %Mydia.Metadata.Structs.SearchResult{
        provider_id: "551",
        provider: :tmdb,
        media_type: :movie,
        title: "The Kestrel Protocol",
        year: 2021,
        poster_path: "/kestrel.jpg",
        overview: "A courier loses the package."
      }

      assert MediaAddHelpers.preview_for([[item]], {:tmdb, 551}, nil) == %{
               title: "The Kestrel Protocol",
               year: 2021,
               poster_path: "/kestrel.jpg",
               overview: "A courier loses the package."
             }
    end

    test "matches a FranchiseEntry on tmdb_id and leaves overview nil" do
      entry = %Mydia.Media.FranchiseEntry{
        tmdb_id: 902,
        title: "Harbour Lights",
        year: 1998,
        poster_path: "/harbour.jpg"
      }

      assert MediaAddHelpers.preview_for([[entry]], {:tmdb, 902}, nil) == %{
               title: "Harbour Lights",
               year: 1998,
               poster_path: "/harbour.jpg",
               overview: nil
             }
    end

    test "falls back to the name key on a plain enriched map" do
      item = %{provider_id: 77, name: "Glass Meridian", year: 2015, poster_path: nil}

      assert MediaAddHelpers.preview_for([[item]], {:tmdb, 77}, nil).title == "Glass Meridian"
    end

    test "searches every list in order" do
      grid = [%{provider_id: 1, title: "First"}]
      rail = [%{provider_id: 2, title: "Second"}]

      assert MediaAddHelpers.preview_for([grid, rail], {:tmdb, 2}, nil).title == "Second"
    end

    test "falls back to the caret's title when nothing matches" do
      assert MediaAddHelpers.preview_for([[], []], {:tmdb, 404}, "Only The Title") == %{
               title: "Only The Title",
               year: nil,
               poster_path: nil,
               overview: nil
             }
    end

    test "falls back to an empty title when nothing matches and no title was sent" do
      assert MediaAddHelpers.preview_for([[]], {:tmdb, 404}, nil).title == ""
    end
  end

  describe "add_opts_from_config/3" do
    setup do
      library = library_path_fixture(%{type: :movies, monitored: true})
      %{library: library}
    end

    test "returns add opts for a valid library", %{library: library} do
      params = %{
        "library_path_id" => to_string(library.id),
        "quality_profile_id" => "",
        "monitored" => "true",
        "search_on_add" => "false"
      }

      assert {:ok, opts} = MediaAddHelpers.add_opts_from_config(params, :movie, nil)
      assert opts[:library_path_id] == to_string(library.id)
      assert opts[:monitored] == true
      assert opts[:search_on_add] == false
    end

    test "rejects a library that is not a candidate for the media type", %{library: library} do
      params = %{"library_path_id" => to_string(library.id), "monitored" => "true"}

      assert {:error, :unknown_library} =
               MediaAddHelpers.add_opts_from_config(params, :tv_show, nil)
    end

    test "rejects a forged library id" do
      params = %{"library_path_id" => "not-a-real-id", "monitored" => "true"}

      assert {:error, :unknown_library} =
               MediaAddHelpers.add_opts_from_config(params, :movie, nil)
    end

    test "treats a blank library id as no choice and still resolves defaults" do
      params = %{"library_path_id" => "", "monitored" => "false", "search_on_add" => "false"}

      assert {:ok, opts} = MediaAddHelpers.add_opts_from_config(params, :movie, nil)
      assert opts[:monitored] == false
    end

    test "carries season_monitoring through for TV" do
      params = %{
        "library_path_id" => "",
        "monitored" => "true",
        "season_monitoring" => "first",
        "search_on_add" => "true"
      }

      assert {:ok, opts} = MediaAddHelpers.add_opts_from_config(params, :tv_show, nil)
      assert opts[:season_monitoring] == "first"
      assert opts[:search_on_add] == true
    end
  end

  describe "resolve_add_defaults/3" do
    test "returns the resolved struct with the submitted values folded in" do
      library = library_path_fixture(%{type: "movies"})
      profile = quality_profile_fixture()

      params = %{
        "library_path_id" => library.id,
        "quality_profile_id" => profile.id,
        "monitored" => "false",
        "search_on_add" => "true"
      }

      assert {:ok, defaults} = MediaAddHelpers.resolve_add_defaults(params, :movie, nil)

      assert defaults.library_path_id == library.id
      assert defaults.quality_profile_id == profile.id
      assert defaults.monitored == false
      assert defaults.search_on_add == true
    end

    test "rejects a library that is not a candidate for the media type" do
      assert {:error, :unknown_library} =
               MediaAddHelpers.resolve_add_defaults(
                 %{"library_path_id" => Ecto.UUID.generate()},
                 :movie,
                 nil
               )
    end
  end

  describe "put_add_config/4 library freshness" do
    # candidate_libraries/1 is called from inside put_add_config/4 itself, at
    # OPEN time, rather than being threaded in from an earlier assign a host
    # captured at mount. `stale_snapshot` below stands in for that earlier
    # assign: it is taken before the library that matters to each test exists
    # (or before it is unmonitored), so if put_add_config/4 ever regressed to
    # trusting a value computed earlier instead of recomputing it, the
    # assertions on `updated` would see the stale list and fail.
    defp open_socket do
      %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    end

    defp open_kestrel_config(socket) do
      MediaAddHelpers.put_add_config(
        socket,
        %{"ref" => "tmdb:551", "media_type" => "movie", "title" => "The Kestrel Protocol"},
        nil,
        []
      )
    end

    test "a library added after an earlier snapshot still appears as a candidate" do
      library_path_fixture(%{type: :movies, monitored: true})

      stale_snapshot = MediaAddHelpers.candidate_libraries(:movie)

      late_library =
        library_path_fixture(%{type: :movies, monitored: true, path: "/media/added-late"})

      updated = open_kestrel_config(open_socket())
      library_ids = Enum.map(updated.assigns.add_config.libraries, & &1.id)

      refute late_library.id in Enum.map(stale_snapshot, & &1.id)
      assert late_library.id in library_ids
    end

    test "a library unmonitored after an earlier snapshot is dropped as a candidate" do
      library =
        library_path_fixture(%{type: :movies, monitored: true, path: "/media/soon-unmonitored"})

      stale_snapshot = MediaAddHelpers.candidate_libraries(:movie)
      assert library.id in Enum.map(stale_snapshot, & &1.id)

      {:ok, _library} = Mydia.Settings.update_library_path(library, %{monitored: false})

      updated = open_kestrel_config(open_socket())
      library_ids = Enum.map(updated.assigns.add_config.libraries, & &1.id)

      refute library.id in library_ids
    end
  end

  describe "resolve_add_config_submit/2" do
    setup do
      library = library_path_fixture(%{type: :movies, monitored: true})
      %{library: library, user: user_fixture()}
    end

    defp submit_socket(user, add_config) do
      %Phoenix.LiveView.Socket{
        assigns: %{
          __changed__: %{},
          flash: %{},
          current_user: user,
          add_config: add_config
        }
      }
    end

    defp movie_config, do: %{ref: {:tmdb, 551}, media_type: :movie}

    test "returns opts and closes the dialog on the happy path", %{
      library: library,
      user: user
    } do
      params = %{
        "library_path_id" => to_string(library.id),
        "monitored" => "true",
        "search_on_add" => "false"
      }

      assert {:ok, {:tmdb, 551}, :movie, opts, socket} =
               MediaAddHelpers.resolve_add_config_submit(
                 submit_socket(user, movie_config()),
                 params
               )

      assert opts[:library_path_id] == to_string(library.id)
      assert socket.assigns.add_config == nil
    end

    test "halts and leaves the dialog open when the user may not create media" do
      readonly = user_fixture(%{role: "readonly"})

      assert {:halt, socket} =
               MediaAddHelpers.resolve_add_config_submit(
                 submit_socket(readonly, movie_config()),
                 %{"library_path_id" => "", "monitored" => "true"}
               )

      # Left open on purpose: authorize_create_media/1 has already flashed the
      # reason and a correction should be one click away, not a re-open.
      assert socket.assigns.add_config == movie_config()
      assert socket.assigns.flash["error"] =~ "permission"
    end

    test "halts when no dialog is open", %{user: user} do
      assert {:halt, socket} =
               MediaAddHelpers.resolve_add_config_submit(
                 submit_socket(user, nil),
                 %{"library_path_id" => "", "monitored" => "true"}
               )

      assert socket.assigns.add_config == nil
      assert socket.assigns.flash == %{}
    end

    test "halts, closes the dialog and flashes on a library the type does not allow", %{
      library: library,
      user: user
    } do
      params = %{"library_path_id" => to_string(library.id), "monitored" => "true"}

      assert {:halt, socket} =
               MediaAddHelpers.resolve_add_config_submit(
                 submit_socket(user, %{ref: {:tmdb, 551}, media_type: :tv_show}),
                 params
               )

      assert socket.assigns.add_config == nil
      assert socket.assigns.flash["error"] =~ "no longer available"
    end
  end

  describe "queue_add/3" do
    defp queue_socket(in_flight) do
      %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, adding_item_ids: MapSet.new(in_flight)}
      }
    end

    test "sends the message and marks the id in flight" do
      socket = MediaAddHelpers.queue_add(queue_socket([]), "551", {:add, "551"})

      assert_received {:add, "551"}
      assert MapSet.member?(socket.assigns.adding_item_ids, "551")
    end

    test "sends nothing for an id already in flight" do
      socket = MediaAddHelpers.queue_add(queue_socket(["551"]), "551", {:add, "551"})

      refute_received {:add, "551"}
      assert MapSet.to_list(socket.assigns.adding_item_ids) == ["551"]
    end
  end
end
