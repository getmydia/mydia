defmodule Mydia.Media.AddTest do
  use Mydia.DataCase, async: false

  import Mydia.SettingsFixtures

  alias Mydia.Media.Add

  defp relay_config(bypass) do
    %{
      type: :metadata_relay,
      base_url: "http://localhost:#{bypass.port}",
      options: %{language: "en-US", include_adult: false}
    }
  end

  defp stub_tmdb_movie(bypass, id, title, poster_path) do
    body = %{
      "id" => id,
      "title" => title,
      "release_date" => "2021-03-04",
      "poster_path" => poster_path,
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

  describe "resolve_attrs/4" do
    test "returns movie attrs carrying the poster path" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Poster Movie", "/poster.jpg")

      assert {:ok, attrs} = Add.resolve_attrs(id, :movie, relay_config(bypass))

      assert attrs.type == "movie"
      assert attrs.title == "Poster Movie"
      assert attrs.tmdb_id == id
      assert attrs.metadata.poster_path == "/poster.jpg"
    end

    test "returns {:error, {:metadata, reason}} when the relay is unreachable" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      Bypass.down(bypass)

      assert {:error, {:metadata, _reason}} = Add.resolve_attrs(id, :movie, relay_config(bypass))
    end
  end

  describe "from_provider/4" do
    test "creates a movie media item with metadata attached" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      stub_tmdb_movie(bypass, id, "Created Movie", "/created.jpg")

      assert {:ok, item} = Add.from_provider(id, :movie, relay_config(bypass))

      assert item.title == "Created Movie"
      assert item.tmdb_id == id
      assert item.metadata.poster_path == "/created.jpg"
    end

    test "creates nothing and reports the metadata error when the relay is down" do
      bypass = Bypass.open()
      id = System.unique_integer([:positive])
      Bypass.down(bypass)

      assert {:error, {:metadata, _reason}} = Add.from_provider(id, :movie, relay_config(bypass))
      refute Mydia.Media.get_media_item_by_tmdb(id)
    end
  end

  describe "cross-provider ids" do
    test "a TVDB-sourced show carries the TMDB id from remoteIds" do
      bypass = Bypass.open()
      tvdb_id = System.unique_integer([:positive])
      tmdb_id = System.unique_integer([:positive])

      body = %{
        "data" => %{
          "id" => tvdb_id,
          "name" => "Cross Referenced",
          "firstAired" => "2011-04-17",
          "seasons" => [],
          "trailers" => [%{"url" => "https://youtube.com/watch?v=z", "language" => "eng"}],
          "remoteIds" => [
            %{"sourceName" => "TheMovieDB.com", "id" => to_string(tmdb_id), "type" => 12}
          ]
        }
      }

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      assert {:ok, attrs} =
               Add.resolve_attrs(tvdb_id, :tv_show, relay_config(bypass), provider: :tvdb)

      assert attrs.tvdb_id == tvdb_id
      assert attrs.tmdb_id == tmdb_id
    end

    test "uses the TMDB external_ids tvdb_id instead of searching by title" do
      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      tvdb_id = System.unique_integer([:positive])
      test_pid = self()

      Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
        body = %{
          "id" => tmdb_id,
          "name" => "Exactly Resolved",
          "first_air_date" => "2011-04-17",
          "credits" => %{"cast" => [], "crew" => []},
          "external_ids" => %{"tvdb_id" => tvdb_id}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.stub(bypass, "GET", "/tvdb/series/#{tvdb_id}/extended", fn conn ->
        body = %{
          "data" => %{
            "id" => tvdb_id,
            "name" => "Exactly Resolved",
            "firstAired" => "2011-04-17",
            "seasons" => [],
            "trailers" => [%{"url" => "https://youtube.com/watch?v=q", "language" => "eng"}],
            "remoteIds" => []
          }
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        send(test_pid, :searched)

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"data" => []}))
      end)

      assert {:ok, attrs} = Add.resolve_attrs(tmdb_id, :tv_show, relay_config(bypass))

      assert attrs.tvdb_id == tvdb_id
      refute_receive :searched
    end

    test "lookup_and_add_tvdb_id does not overwrite an exact external_ids tvdb_id" do
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      exact_tvdb_id = System.unique_integer([:positive])
      fuzzy_tvdb_id = System.unique_integer([:positive])

      Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
        body = %{
          "id" => tmdb_id,
          "name" => "Guarded Show",
          "first_air_date" => "2011-04-17",
          "credits" => %{"cast" => [], "crew" => []},
          "seasons" => [],
          "external_ids" => %{"tvdb_id" => exact_tvdb_id}
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      # The title search must return a DIFFERENT tvdb id than the exact one
      # TMDB cross-references. If `lookup_and_add_tvdb_id/2`'s guard clause is
      # ever removed, this fuzzy result silently overwrites the exact id and
      # the assertion below flips.
      Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
        body = %{
          "data" => [
            %{"tvdb_id" => fuzzy_tvdb_id, "name" => "Guarded Show", "year" => "2011"}
          ]
        }

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      # A configured :tmdb TV library routes through build_tv_show_attrs/6's
      # :tmdb-primary clause, which pipes build_media_item_attrs/3's output
      # through lookup_and_add_tvdb_id/2 -- the only path that reaches the
      # guard clause under test.
      assert {:ok, attrs} = Add.resolve_attrs(tmdb_id, :tv_show, relay_config(bypass))

      assert attrs.tvdb_id == exact_tvdb_id
    end
  end
end
