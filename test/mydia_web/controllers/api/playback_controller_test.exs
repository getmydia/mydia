defmodule MydiaWeb.Api.PlaybackControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.{Media, Playback}

  setup do
    # Create test user and get auth token
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    # Create test media item (movie) and episode
    {:ok, movie} = create_media_item("movie")
    {:ok, episode} = create_episode()

    {:ok, user: user, token: token, movie: movie, episode: episode}
  end

  describe "GET /api/v1/playback/movie/:id" do
    test "returns default progress when none exists", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/movie/#{movie.id}")

      assert json_response(conn, 200) == %{
               "position_seconds" => 0,
               "duration_seconds" => nil,
               "completion_percentage" => 0,
               "watched" => false
             }
    end

    test "returns existing progress", %{conn: conn, token: token, user: user, movie: movie} do
      # Create some progress
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 1250,
          duration_seconds: 5400
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/movie/#{movie.id}")

      response = json_response(conn, 200)
      assert response["position_seconds"] == 1250
      assert response["duration_seconds"] == 5400
      assert_in_delta response["completion_percentage"], 23.15, 0.01
      assert response["watched"] == false
      assert response["last_watched_at"] != nil
    end

    test "returns 404 for non-existent movie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/movie/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Media item not found"
    end

    test "returns 404 when media item is not a movie", %{
      conn: conn,
      token: token
    } do
      # Create a TV show instead of a movie
      {:ok, tv_show} = create_media_item("tv_show")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/movie/#{tv_show.id}")

      assert json_response(conn, 404)["error"] == "Media item is not a movie"
    end

    test "requires authentication", %{conn: conn, movie: movie} do
      conn = get(conn, "/api/v1/playback/movie/#{movie.id}")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v1/playback/episode/:id" do
    test "returns default progress when none exists", %{
      conn: conn,
      token: token,
      episode: episode
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/episode/#{episode.id}")

      assert json_response(conn, 200) == %{
               "position_seconds" => 0,
               "duration_seconds" => nil,
               "completion_percentage" => 0,
               "watched" => false
             }
    end

    test "returns existing progress", %{conn: conn, token: token, user: user, episode: episode} do
      # Create some progress
      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 800,
          duration_seconds: 1800
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/episode/#{episode.id}")

      response = json_response(conn, 200)
      assert response["position_seconds"] == 800
      assert response["duration_seconds"] == 1800
      assert_in_delta response["completion_percentage"], 44.44, 0.01
      assert response["watched"] == false
      assert response["last_watched_at"] != nil
    end

    test "returns 404 for non-existent episode", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/playback/episode/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Episode not found"
    end

    test "requires authentication", %{conn: conn, episode: episode} do
      conn = get(conn, "/api/v1/playback/episode/#{episode.id}")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/playback/movie/:id" do
    test "creates new progress", %{conn: conn, token: token, movie: movie} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: 1250,
          duration_seconds: 5400
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 1250
      assert response["duration_seconds"] == 5400
      assert_in_delta response["completion_percentage"], 23.15, 0.01
      assert response["watched"] == false
      assert response["last_watched_at"] != nil
    end

    test "updates existing progress", %{conn: conn, token: token, user: user, movie: movie} do
      # Create initial progress
      {:ok, _progress} =
        Playback.save_progress(user.id, [media_item_id: movie.id], %{
          position_seconds: 500,
          duration_seconds: 5400
        })

      # Update progress
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: 2000,
          duration_seconds: 5400
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 2000
      assert response["duration_seconds"] == 5400
      assert_in_delta response["completion_percentage"], 37.04, 0.01
      assert response["watched"] == false
    end

    test "automatically marks as watched at 90%+", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: 4900,
          duration_seconds: 5400
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 4900
      assert_in_delta response["completion_percentage"], 90.74, 0.01
      assert response["watched"] == true
    end

    test "returns 422 for invalid data - negative position", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: -10,
          duration_seconds: 5400
        })

      response = json_response(conn, 422)
      assert response["error"] == "Invalid data"
      assert response["details"]["position_seconds"] != nil
    end

    test "returns 422 for invalid data - zero duration", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: 100,
          duration_seconds: 0
        })

      response = json_response(conn, 422)
      assert response["error"] == "Invalid data"
      assert response["details"]["duration_seconds"] != nil
    end

    test "returns 404 for non-existent movie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/00000000-0000-0000-0000-000000000000", %{
          position_seconds: 100,
          duration_seconds: 5400
        })

      assert json_response(conn, 404)["error"] == "Media item not found"
    end

    test "returns 404 when media item is not a movie", %{
      conn: conn,
      token: token
    } do
      # Create a TV show instead of a movie
      {:ok, tv_show} = create_media_item("tv_show")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{tv_show.id}", %{
          position_seconds: 100,
          duration_seconds: 5400
        })

      assert json_response(conn, 404)["error"] == "Media item is not a movie"
    end

    test "requires authentication", %{conn: conn, movie: movie} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/movie/#{movie.id}", %{
          position_seconds: 100,
          duration_seconds: 5400
        })

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  describe "POST /api/v1/playback/episode/:id" do
    test "creates new progress", %{conn: conn, token: token, episode: episode} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/#{episode.id}", %{
          position_seconds: 800,
          duration_seconds: 1800
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 800
      assert response["duration_seconds"] == 1800
      assert_in_delta response["completion_percentage"], 44.44, 0.01
      assert response["watched"] == false
      assert response["last_watched_at"] != nil
    end

    test "updates existing progress", %{conn: conn, token: token, user: user, episode: episode} do
      # Create initial progress
      {:ok, _progress} =
        Playback.save_progress(user.id, [episode_id: episode.id], %{
          position_seconds: 300,
          duration_seconds: 1800
        })

      # Update progress
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/#{episode.id}", %{
          position_seconds: 1200,
          duration_seconds: 1800
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 1200
      assert response["duration_seconds"] == 1800
      assert_in_delta response["completion_percentage"], 66.67, 0.01
      assert response["watched"] == false
    end

    test "automatically marks as watched at 90%+", %{
      conn: conn,
      token: token,
      episode: episode
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/#{episode.id}", %{
          position_seconds: 1650,
          duration_seconds: 1800
        })

      response = json_response(conn, 200)
      assert response["position_seconds"] == 1650
      assert_in_delta response["completion_percentage"], 91.67, 0.01
      assert response["watched"] == true
    end

    test "returns 422 for invalid data", %{
      conn: conn,
      token: token,
      episode: episode
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/#{episode.id}", %{
          position_seconds: -10,
          duration_seconds: 1800
        })

      response = json_response(conn, 422)
      assert response["error"] == "Invalid data"
      assert response["details"]["position_seconds"] != nil
    end

    test "returns 404 for non-existent episode", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/00000000-0000-0000-0000-000000000000", %{
          position_seconds: 100,
          duration_seconds: 1800
        })

      assert json_response(conn, 404)["error"] == "Episode not found"
    end

    test "requires authentication", %{conn: conn, episode: episode} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/api/v1/playback/episode/#{episode.id}", %{
          position_seconds: 100,
          duration_seconds: 1800
        })

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  # Helper functions for test setup
  #
  # skip_episode_refresh: true — these tests only need a persisted media item
  # to exercise the playback controller's own validation (not found, wrong
  # type), not a real episode list. Without it, a "tv_show" item with a fake
  # tmdb_id sends refresh_episodes_for_tv_show/2 to the live relay for both a
  # details fetch and a TVDB title-search recovery, neither of which is
  # cached the way the mount-time detail-page lookups are (#530).
  defp create_media_item(type) do
    Media.create_media_item(
      %{
        title: "Test #{type} #{System.unique_integer([:positive])}",
        tmdb_id: System.unique_integer([:positive]),
        type: type,
        year: 2024,
        monitored: true
      },
      skip_episode_refresh: true
    )
  end

  defp create_episode do
    {:ok, media_item} =
      Media.create_media_item(
        %{
          title: "Test Show #{System.unique_integer([:positive])}",
          tmdb_id: System.unique_integer([:positive]),
          type: "tv_show",
          monitored: true
        },
        skip_episode_refresh: true
      )

    Media.create_episode(%{
      media_item_id: media_item.id,
      season_number: 1,
      episode_number: 1,
      title: "Pilot",
      monitored: true
    })
  end
end
