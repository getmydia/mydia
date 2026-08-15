defmodule Mydia.Media.AddTest do
  use Mydia.DataCase, async: false

  import ExUnit.CaptureLog
  import Mydia.SettingsFixtures

  alias Mydia.Media.Add
  alias Mydia.Media.MediaItem

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

  defp stub_tmdb_tv_show(bypass, tmdb_id, title, external_tvdb_id) do
    body = %{
      "id" => tmdb_id,
      "name" => title,
      "first_air_date" => "2011-04-17",
      "credits" => %{"cast" => [], "crew" => []},
      "seasons" => [],
      "external_ids" => %{"tvdb_id" => external_tvdb_id}
    }

    Bypass.stub(bypass, "GET", "/tmdb/tv/shows/#{tmdb_id}", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(body))
    end)
  end

  defp stub_tvdb_search(bypass, results) do
    Bypass.stub(bypass, "GET", "/tvdb/search", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{"data" => results}))
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

    test "reports an existing row instead of violating the tvdb_id index" do
      tvdb_id = System.unique_integer([:positive])
      tmdb_id = System.unique_integer([:positive])

      existing =
        Mydia.MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          title: "Already Here",
          tvdb_id: tvdb_id
        })

      attrs = %{
        type: "tv_show",
        title: "Already Here",
        tvdb_id: tvdb_id,
        tmdb_id: tmdb_id,
        monitored: true
      }

      assert {:error, {:already_in_library, found}} = Add.from_attrs(attrs)

      assert found.id == existing.id
      assert found.tmdb_id == tmdb_id
    end

    # imdb_id carries no unique index, so an imdb collision can never be the
    # constraint error the pre-flight exists to pre-empt. TVDB's remoteIds hand
    # split and spin-off series a shared imdb id, so consulting it would refuse
    # a legitimate add and let backfill_ids/2 stamp the wrong provider id on the
    # incumbent.
    test "a shared imdb_id alone does not count as already in the library" do
      shared_imdb_id = "tt#{System.unique_integer([:positive])}"

      Mydia.MediaFixtures.media_item_fixture(%{
        type: "tv_show",
        title: "Original Series",
        tvdb_id: System.unique_integer([:positive]),
        imdb_id: shared_imdb_id
      })

      attrs = %{
        type: "tv_show",
        title: "The Spin-Off",
        tvdb_id: System.unique_integer([:positive]),
        imdb_id: shared_imdb_id,
        monitored: true
      }

      before_count = Repo.aggregate(MediaItem, :count)

      assert {:ok, added} = Add.from_attrs(attrs, nil, skip_episode_refresh: true)

      assert added.imdb_id == shared_imdb_id
      assert Repo.aggregate(MediaItem, :count) == before_count + 1
    end

    # The motivating bug, from the :tmdb-derived side. A scan matched this show
    # on TVDB, so the row holds a tvdb_id and no tmdb_id; Discover keys on the
    # tmdb_id, sees nothing, and offers Add. ExternalIds then refuses to write
    # the taken tvdb_id, which leaves the attrs looking free of any collision.
    test "reports the existing tvdb owner when the title search finds nothing" do
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      taken_tvdb_id = System.unique_integer([:positive])

      existing =
        Mydia.MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          title: "Scanned From Tvdb",
          tvdb_id: taken_tvdb_id
        })

      stub_tmdb_tv_show(bypass, tmdb_id, "Scanned From Tvdb", taken_tvdb_id)
      stub_tvdb_search(bypass, [])

      before_count = Repo.aggregate(MediaItem, :count)

      {attrs, log} =
        with_log(fn ->
          assert {:ok, attrs} = Add.resolve_attrs(tmdb_id, :tv_show, relay_config(bypass))
          attrs
        end)

      assert log =~ "is already owned by another media item"
      # Dropped by ExternalIds, and the title search had nothing to put in its
      # place, so nothing in the attrs themselves points at the incumbent.
      assert is_nil(attrs.tvdb_id)
      assert attrs.metadata.external_ids.tvdb == taken_tvdb_id

      assert {:error, {:already_in_library, found}} = Add.from_attrs(attrs, relay_config(bypass))

      assert found.id == existing.id
      assert found.tmdb_id == tmdb_id
      assert Repo.aggregate(MediaItem, :count) == before_count
    end

    # Same collision, but the title search does return a hit. The free id it
    # finds fills the slot ExternalIds left empty, so the attrs carry a tvdb_id
    # that matches nothing -- the taken id survives only in external_ids.
    test "reports the existing tvdb owner when the title search finds another show" do
      library_path_fixture(%{type: "series", tv_metadata_source: :tmdb})

      bypass = Bypass.open()
      tmdb_id = System.unique_integer([:positive])
      taken_tvdb_id = System.unique_integer([:positive])
      fuzzy_tvdb_id = System.unique_integer([:positive])

      existing =
        Mydia.MediaFixtures.media_item_fixture(%{
          type: "tv_show",
          title: "Scanned From Tvdb",
          tvdb_id: taken_tvdb_id
        })

      stub_tmdb_tv_show(bypass, tmdb_id, "Scanned From Tvdb", taken_tvdb_id)

      stub_tvdb_search(bypass, [
        %{"tvdb_id" => fuzzy_tvdb_id, "name" => "Scanned From Tvdb", "year" => "2011"}
      ])

      before_count = Repo.aggregate(MediaItem, :count)

      {attrs, log} =
        with_log(fn ->
          assert {:ok, attrs} = Add.resolve_attrs(tmdb_id, :tv_show, relay_config(bypass))
          attrs
        end)

      assert log =~ "is already owned by another media item"
      assert attrs.tvdb_id == fuzzy_tvdb_id
      assert attrs.metadata.external_ids.tvdb == taken_tvdb_id

      assert {:error, {:already_in_library, found}} = Add.from_attrs(attrs, relay_config(bypass))

      assert found.id == existing.id
      assert found.tvdb_id == taken_tvdb_id
      assert found.tmdb_id == tmdb_id
      assert Repo.aggregate(MediaItem, :count) == before_count
    end
  end
end
