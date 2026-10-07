defmodule Mydia.Media.FixMatchTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures
  import Mydia.MetadataCacheHelpers, only: [unique_provider_id: 0, warm_remote_signals: 3]

  alias Mydia.Accounts.Scope
  alias Mydia.Media.FixMatch
  alias Mydia.Media.RemoteSignals

  setup do
    bypass = Bypass.open()

    config = %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }

    %{bypass: bypass, config: config}
  end

  defp json(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(200, Jason.encode!(body))
  end

  describe "provider_for/1" do
    test "movies always use TMDB" do
      assert FixMatch.provider_for(%Mydia.Media.MediaItem{type: "movie", tvdb_id: 5}) == :tmdb
    end

    test "a show uses the provider that issued its stored id" do
      assert FixMatch.provider_for(%Mydia.Media.MediaItem{type: "tv_show", tvdb_id: 5}) == :tvdb

      assert FixMatch.provider_for(%Mydia.Media.MediaItem{
               type: "tv_show",
               tmdb_id: 5,
               metadata_source: :tmdb
             }) == :tmdb
    end
  end

  describe "search/5" do
    test "searches the item's provider with the operator's own query", c do
      item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001, tmdb_id: 11})

      Bypass.expect_once(c.bypass, "GET", "/tmdb/movies/search", fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)
        assert conn.query_params["query"] == "Velvet Comet"

        json(conn, %{
          "results" => [%{"id" => 12, "title" => "Velvet Comet", "release_date" => "2003-01-01"}]
        })
      end)

      assert {:ok, [result]} =
               FixMatch.search(item, "Velvet Comet", nil, Scope.unrestricted(), c.config)

      assert result.provider_id == "12"
    end

    test "retries without the year when the year filter finds nothing", c do
      item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001, tmdb_id: 13})
      calls = :counters.new(1, [])

      Bypass.expect(c.bypass, "GET", "/tmdb/movies/search", fn conn ->
        :counters.add(calls, 1, 1)
        conn = Plug.Conn.fetch_query_params(conn)

        results =
          if Map.has_key?(conn.query_params, "year"),
            do: [],
            else: [%{"id" => 14, "title" => "Velvet Comet", "release_date" => "2003-01-01"}]

        json(conn, %{"results" => results})
      end)

      assert {:ok, [_]} =
               FixMatch.search(item, "Velvet Comet", 1990, Scope.unrestricted(), c.config)

      assert :counters.get(calls, 1) == 2
    end

    test "drops titles a restricted scope may not see", c do
      [ok, blocked] = for _ <- 1..2, do: unique_provider_id()

      warm_remote_signals({:tmdb, ok}, :movie, %RemoteSignals{
        content_rating: "PG",
        age: 8,
        category: "movie"
      })

      warm_remote_signals({:tmdb, blocked}, :movie, %RemoteSignals{
        content_rating: "R",
        age: 17,
        category: "movie"
      })

      Bypass.stub(c.bypass, "GET", "/tmdb/movies/search", fn conn ->
        json(conn, %{
          "results" => [
            %{"id" => ok, "title" => "Lantern Orchard", "release_date" => "1990-01-01"},
            %{"id" => blocked, "title" => "Lantern Tides", "release_date" => "1991-01-01"}
          ]
        })
      end)

      item = media_item_fixture(%{type: "movie", title: "Wrong Pick", year: 2001, tmdb_id: 15})
      scope = Scope.for_user(restricted_user_fixture(%{max_content_age: 12}))

      assert {:ok, results} = FixMatch.search(item, "Lantern", nil, scope, c.config)
      assert Enum.map(results, & &1.provider_id) == [to_string(ok)]
    end
  end

  describe "adopt/4" do
    defp movie_body(id, title, date) do
      %{
        "id" => id,
        "title" => title,
        "original_title" => title,
        "release_date" => date,
        "imdb_id" => "tt#{id}",
        "credits" => %{"cast" => [], "crew" => []},
        "genres" => []
      }
    end

    defp candidate(id, type),
      do: %Mydia.Metadata.Structs.SearchResult{
        provider_id: to_string(id),
        provider: :metadata_relay,
        media_type: type
      }

    test "a movie takes the new identity and keeps its files and settings", c do
      new_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "movie",
          title: "Wrong Pick",
          year: 2001,
          tmdb_id: System.unique_integer([:positive]),
          monitored: false
        })

      file = media_file_fixture(%{media_item_id: item.id})

      Bypass.expect_once(c.bypass, "GET", "/tmdb/movies/#{new_id}", fn conn ->
        json(conn, movie_body(new_id, "Velvet Comet", "2003-06-01"))
      end)

      assert {:ok, updated} =
               FixMatch.adopt(Scope.unrestricted(), item, candidate(new_id, :movie), c.config)

      assert updated.tmdb_id == new_id
      assert updated.title == "Velvet Comet"
      assert updated.year == 2003
      assert updated.monitored == false
      assert Mydia.Repo.get!(Mydia.Library.MediaFile, file.id).media_item_id == item.id
    end

    test "refuses a title that is already another item in the library", c do
      taken = System.unique_integer([:positive])
      other = media_item_fixture(%{type: "movie", title: "Velvet Comet", tmdb_id: taken})
      item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: taken + 1})

      assert {:error, {:already_in_library, found}} =
               FixMatch.adopt(Scope.unrestricted(), item, candidate(taken, :movie), c.config)

      assert found.id == other.id
      assert Mydia.Repo.reload!(item).title == "Wrong Pick"
    end

    test "a failed fetch leaves the item untouched", c do
      new_id = System.unique_integer([:positive])
      item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: new_id + 1})

      Bypass.expect_once(c.bypass, "GET", "/tmdb/movies/#{new_id}", fn conn ->
        Plug.Conn.resp(conn, 404, "{}")
      end)

      assert {:error, _} =
               FixMatch.adopt(Scope.unrestricted(), item, candidate(new_id, :movie), c.config)

      assert Mydia.Repo.reload!(item).tmdb_id == new_id + 1
    end

    test "a show is rebuilt from the new id on the same provider", c do
      new_id = System.unique_integer([:positive])

      item =
        media_item_fixture(%{
          type: "tv_show",
          title: "Wrong Harbor",
          tmdb_id: new_id + 1,
          metadata_source: :tmdb
        })

      lib = library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})
      ep = episode_fixture(%{media_item_id: item.id, season_number: 1, episode_number: 1})

      file =
        media_file_fixture(%{
          episode_id: ep.id,
          library_path_id: lib.id,
          relative_path: "Velvet Harbor/Season 01/Velvet.Harbor.S01E01.mkv"
        })

      Bypass.expect(c.bypass, "GET", "/tmdb/tv/shows/#{new_id}", fn conn ->
        json(conn, %{
          "id" => new_id,
          "name" => "Velvet Harbor",
          "first_air_date" => "2012-01-01",
          "credits" => %{"cast" => [], "crew" => []},
          "genres" => [],
          "seasons" => [%{"season_number" => 1, "name" => "Season 1"}]
        })
      end)

      Bypass.expect(c.bypass, "GET", "/tmdb/tv/shows/#{new_id}/1", fn conn ->
        json(conn, %{
          "season_number" => 1,
          "episodes" => [
            %{
              "season_number" => 1,
              "episode_number" => 1,
              "name" => "Pilot",
              "air_date" => "2012-01-01"
            }
          ]
        })
      end)

      assert {:ok, updated} =
               FixMatch.adopt(Scope.unrestricted(), item, candidate(new_id, :tv_show), c.config)

      assert updated.tmdb_id == new_id
      assert updated.title == "Velvet Harbor"
      assert is_nil(Mydia.Repo.get(Mydia.Library.MediaFile, file.id))

      assert Mydia.Repo.get_by(Mydia.Library.ImportCandidate,
               library_path_id: lib.id,
               relative_path: file.relative_path
             )
    end
  end
end
