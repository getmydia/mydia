defmodule MydiaWeb.Api.Player.V1.SubtitleControllerTest do
  use MydiaWeb.ConnCase, async: true

  alias Mydia.{Media, Repo}

  setup do
    # Create test user and get auth token
    {user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    # Create library path
    {:ok, library_path} =
      Repo.insert(%Mydia.Settings.LibraryPath{
        path: "/tmp/test-movies",
        type: :movies
      })

    # Create test media item (movie)
    {:ok, movie} =
      Media.create_media_item(%{
        title: "Test Movie",
        type: "movie",
        library_path_id: library_path.id,
        year: 2024
      })

    # Create media file for the movie
    {:ok, media_file} =
      Repo.insert(%Mydia.Library.MediaFile{
        media_item_id: movie.id,
        library_path_id: library_path.id,
        relative_path: "Test.Movie.mkv",
        size: 1_000_000,
        resolution: "1080p",
        codec: "H.264",
        audio_codec: "AAC"
      })

    # Create test episode (skip auto episode refresh to avoid unique constraint violations)
    {:ok, tv_show} =
      Media.create_media_item(
        %{
          title: "Test Show",
          type: "tv_show",
          library_path_id: library_path.id,
          year: 2024
        },
        skip_episode_refresh: true
      )

    {:ok, episode} =
      Media.create_episode(%{
        media_item_id: tv_show.id,
        season_number: 1,
        episode_number: 1,
        title: "Pilot"
      })

    {:ok, episode_file} =
      Repo.insert(%Mydia.Library.MediaFile{
        episode_id: episode.id,
        media_item_id: tv_show.id,
        library_path_id: library_path.id,
        relative_path: "Test.Show.S01E01.mkv",
        size: 1_000_000,
        resolution: "1080p",
        codec: "H.264",
        audio_codec: "AAC"
      })

    # Create external subtitle for testing
    {:ok, external_subtitle} =
      Repo.insert(%Mydia.Subtitles.Subtitle{
        media_file_id: media_file.id,
        language: "en",
        provider: "test",
        subtitle_hash: "test-hash-123",
        file_path: "/tmp/test-subtitle.srt",
        format: "srt"
      })

    {:ok,
     user: user,
     token: token,
     movie: movie,
     media_file: media_file,
     episode: episode,
     episode_file: episode_file,
     external_subtitle: external_subtitle}
  end

  describe "GET /api/player/v1/subtitles/:type/:id" do
    test "lists subtitles for a movie", %{
      conn: conn,
      token: token,
      movie: movie,
      external_subtitle: external_subtitle
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}")

      assert %{"data" => tracks} = json_response(conn, 200)
      assert is_list(tracks)

      # Should contain the external subtitle
      external_track = Enum.find(tracks, fn t -> t["track_id"] == external_subtitle.id end)
      assert external_track != nil
      assert external_track["language"] == "en"
      assert external_track["format"] == "srt"
      assert external_track["embedded"] == false
    end

    test "lists subtitles for an episode", %{
      conn: conn,
      token: token,
      episode: episode
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/episode/#{episode.id}")

      assert %{"data" => tracks} = json_response(conn, 200)
      assert is_list(tracks)
    end

    test "lists subtitles for a media file", %{
      conn: conn,
      token: token,
      media_file: media_file,
      external_subtitle: external_subtitle
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/file/#{media_file.id}")

      assert %{"data" => tracks} = json_response(conn, 200)
      assert is_list(tracks)

      # Should contain the external subtitle
      external_track = Enum.find(tracks, fn t -> t["track_id"] == external_subtitle.id end)
      assert external_track != nil
      assert external_track["language"] == "en"
    end

    test "returns 404 for non-existent movie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Media not found"
    end

    test "returns 404 for non-existent episode", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/episode/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Media not found"
    end

    test "returns 400 for invalid type", %{conn: conn, token: token, movie: movie} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/invalid/#{movie.id}")

      assert json_response(conn, 400)["error"] =~
               "Invalid type. Use 'movie', 'episode', or 'file'"
    end

    test "requires authentication", %{conn: conn, movie: movie} do
      conn = get(conn, "/api/player/v1/subtitles/movie/#{movie.id}")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/player/v1/subtitles/:type/:id/:track" do
    test "downloads external subtitle", %{
      conn: conn,
      token: token,
      movie: movie,
      external_subtitle: external_subtitle
    } do
      # Create a temporary subtitle file for testing
      File.write!(external_subtitle.file_path, "Test subtitle content")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/#{external_subtitle.id}")

      assert response(conn, 200) == "Test subtitle content"
      assert get_resp_header(conn, "content-type") == ["text/plain; charset=utf-8"]

      # Clean up
      File.rm(external_subtitle.file_path)
    end

    test "returns 404 for non-existent subtitle track", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/00000000-0000-0000-0000-000000000000")

      assert json_response(conn, 404)["error"] == "Subtitle track not found"
    end

    test "returns 404 when subtitle file is missing on disk", %{
      conn: conn,
      token: token,
      movie: movie,
      external_subtitle: external_subtitle
    } do
      # Ensure the file doesn't exist
      File.rm(external_subtitle.file_path)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/#{external_subtitle.id}")

      assert json_response(conn, 404)["error"] == "Subtitle file not found on disk"
    end

    test "returns 404 for non-existent media", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/00000000-0000-0000-0000-000000000000/0")

      assert json_response(conn, 404)["error"] == "Media not found"
    end

    test "requires authentication", %{conn: conn, movie: movie, external_subtitle: subtitle} do
      conn = get(conn, "/api/player/v1/subtitles/movie/#{movie.id}/#{subtitle.id}")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end
end
