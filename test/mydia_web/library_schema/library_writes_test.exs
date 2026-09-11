defmodule MydiaWeb.LibrarySchema.LibraryWritesTest do
  # async: false: the relay URL is global application env.
  use MydiaWeb.ConnCase, async: false
  use Oban.Testing, repo: Mydia.Repo

  alias Mydia.LibraryApi.Principal
  alias Mydia.Media

  # A TV add logs when its episode refresh finds nothing; keep that out of the
  # test output.
  @moduletag :capture_log

  @admin %Principal{role: "admin", source: :env}

  setup do
    engine = if Mydia.DB.postgres?(), do: Oban.Engines.Basic, else: Oban.Engines.Lite
    start_supervised!({Oban, repo: Mydia.Repo, engine: engine, testing: :manual})

    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")
    on_exit(fn -> Application.put_env(:mydia, :metadata_relay_url, previous) end)

    %{bypass: bypass}
  end

  defp run(document, variables) do
    Absinthe.run(document, MydiaWeb.LibrarySchema,
      variables: variables,
      context: %{principal: @admin}
    )
  end

  # Same bodies test/mydia/media/add_test.exs stubs, so the relay answers the way
  # Add already expects.
  defp stub_tmdb_movie(bypass, id, title) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "2021-03-04",
      "poster_path" => "/poster.jpg",
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

  defp stub_tvdb_series(bypass, tvdb_id, title) do
    body = %{
      "data" => %{
        "id" => tvdb_id,
        "name" => title,
        "firstAired" => "2011-04-17",
        "seasons" => [],
        "remoteIds" => []
      }
    }

    Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  @add_movie """
  mutation Add($input: AddMovieInput!) {
    addMovie(input: $input) {
      mediaItem { id title tmdbId monitored type }
      userErrors { field code message }
    }
  }
  """

  describe "addMovie" do
    test "adds the movie and returns it", %{bypass: bypass} do
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Harbor Lights")

      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => id}})

      assert payload["userErrors"] == []

      assert %{
               "title" => "Harbor Lights",
               "tmdbId" => ^id,
               "monitored" => true,
               "type" => "MOVIE"
             } =
               payload["mediaItem"]

      assert Media.find_by_external_ids(%{tmdb: id}, type: "movie")
      refute_enqueued(worker: Mydia.Jobs.MovieSearch)
    end

    test "searchNow queues the automatic search the Add button queues", %{bypass: bypass} do
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Harbor Lights")

      assert {:ok, %{data: %{"addMovie" => %{"mediaItem" => %{"id" => item_id}}}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => id, "searchNow" => true}})

      assert_enqueued(
        worker: Mydia.Jobs.MovieSearch,
        args: %{"mode" => "specific", "media_item_id" => item_id}
      )
    end

    test "monitored: false is passed through", %{bypass: bypass} do
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Harbor Lights")

      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => id, "monitored" => false}})

      assert payload["mediaItem"]["monitored"] == false
    end

    test "a title already in the library is ALREADY_IN_LIBRARY with the existing item",
         %{bypass: bypass} do
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Harbor Lights")
      existing = insert(:media_item, tmdb_id: id, title: "Harbor Lights")

      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => id}})

      assert payload["mediaItem"]["id"] == existing.id
      assert [%{"code" => "ALREADY_IN_LIBRARY"}] = payload["userErrors"]
    end

    test "an unreachable relay is METADATA_UNAVAILABLE", %{bypass: bypass} do
      Bypass.down(bypass)

      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => 42}})

      assert payload["mediaItem"] == nil
      assert [%{"code" => "METADATA_UNAVAILABLE"}] = payload["userErrors"]
    end

    test "a malformed qualityProfileId is refused before the relay is asked" do
      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{"input" => %{"tmdbId" => 42, "qualityProfileId" => "nope"}})

      assert [%{"code" => "INVALID_INPUT", "field" => ["input", "qualityProfileId"]}] =
               payload["userErrors"]
    end

    test "a qualityProfileId that names no profile is INVALID_INPUT on that argument",
         %{bypass: bypass} do
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Harbor Lights")

      assert {:ok, %{data: %{"addMovie" => payload}}} =
               run(@add_movie, %{
                 "input" => %{"tmdbId" => id, "qualityProfileId" => Ecto.UUID.generate()}
               })

      assert payload["mediaItem"] == nil

      assert Enum.any?(
               payload["userErrors"],
               &(&1["code"] == "INVALID_INPUT" and &1["field"] == ["input", "qualityProfileId"])
             )
    end
  end

  @add_show """
  mutation Add($input: AddTvShowInput!) {
    addTvShow(input: $input) {
      mediaItem { id title tvdbId type }
      userErrors { field code }
    }
  }
  """

  describe "addTvShow" do
    test "adds a show by its TVDB id", %{bypass: bypass} do
      tvdb_id = System.unique_integer([:positive])
      stub_tvdb_series(bypass, tvdb_id, "Quiet Harbor")

      assert {:ok, %{data: %{"addTvShow" => payload}}} =
               run(@add_show, %{"input" => %{"tvdbId" => tvdb_id, "seasonMonitoring" => "NONE"}})

      assert payload["userErrors"] == []

      assert %{"title" => "Quiet Harbor", "tvdbId" => ^tvdb_id, "type" => "TV_SHOW"} =
               payload["mediaItem"]
    end

    test "neither id is INVALID_INPUT on input" do
      assert {:ok, %{data: %{"addTvShow" => payload}}} = run(@add_show, %{"input" => %{}})

      assert payload["mediaItem"] == nil
      assert [%{"code" => "INVALID_INPUT", "field" => ["input"]}] = payload["userErrors"]
    end
  end

  @remove """
  mutation Remove($input: RemoveMediaItemInput!) {
    removeMediaItem(input: $input) {
      removedId
      userErrors { field code }
    }
  }
  """

  describe "removeMediaItem" do
    test "removes the item and returns its id" do
      item = insert(:media_item)

      assert {:ok, %{data: %{"removeMediaItem" => payload}}} =
               run(@remove, %{"input" => %{"id" => item.id}})

      assert payload == %{"removedId" => item.id, "userErrors" => []}
      assert Media.list_media_items(ids: [item.id]) == []
    end

    test "an id that names nothing is NOT_FOUND on input.id" do
      assert {:ok, %{data: %{"removeMediaItem" => payload}}} =
               run(@remove, %{"input" => %{"id" => Ecto.UUID.generate()}})

      assert payload["removedId"] == nil
      assert [%{"code" => "NOT_FOUND", "field" => ["input", "id"]}] = payload["userErrors"]
    end
  end
end
