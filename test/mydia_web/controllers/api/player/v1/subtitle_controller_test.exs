defmodule MydiaWeb.Api.Player.V1.SubtitleControllerTest do
  use MydiaWeb.ConnCase, async: true

  import Mydia.MediaFixtures

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

    test "returns 404 for a trashed media file", %{conn: conn, token: token} do
      # This is the exact hole the player's self-heal depends on: a quality
      # upgrade trashes the old file (Mydia.Upgrades.apply_upgrade/4) but
      # leaves its row and id resolvable if this route doesn't filter it out.
      trashed =
        media_file_fixture(%{
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/file/#{trashed.id}")

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

    test "converts external subtitle content to the requested format", %{
      conn: conn,
      token: token,
      movie: movie,
      external_subtitle: external_subtitle
    } do
      # A real SRT body with a comma-decimal timing line, so VTT conversion
      # is observable rather than a coincidental no-op (the stored subtitle
      # is "srt", matching the default `format=srt`, which is why the
      # sibling "downloads external subtitle" test above can't tell a real
      # conversion apart from the old raw send_file passthrough).
      File.write!(external_subtitle.file_path, """
      1
      00:00:01,000 --> 00:00:04,000
      Hello there.
      """)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/#{external_subtitle.id}?format=vtt")

      body = response(conn, 200)
      assert String.starts_with?(body, "WEBVTT")
      assert body =~ "00:00:01.000 --> 00:00:04.000"
      refute body =~ "00:00:01,000"
      assert get_resp_header(conn, "content-type") == ["text/vtt; charset=utf-8"]

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

    test "returns 400 for an unsupported format", %{
      conn: conn,
      token: token,
      movie: movie,
      external_subtitle: external_subtitle
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/#{external_subtitle.id}?format=xml")

      body = json_response(conn, 400)
      assert body["error"] =~ "srt"
      assert body["error"] =~ "vtt"
      assert body["error"] =~ "ass"
    end

    test "rejects a path-traversal format value rather than sanitizing it", %{
      conn: conn,
      token: token,
      movie: movie
    } do
      # Target an integer (embedded) track id: that's the branch Delivery
      # unconditionally builds a cache filename and an ffmpeg output path
      # from `format`, with no pure-Elixir shortcut to dodge the filesystem.
      # The external/binary branch only reaches disk via Format.convert's
      # ffmpeg fallback, so it's a weaker target for this regression guard.
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/0?format=..%2F..%2Fetc%2Fpasswd")

      assert json_response(conn, 400)["error"] =~ "Accepted"
    end

    test "returns 415 for an image-based embedded subtitle track", %{
      conn: conn,
      token: token
    } do
      movie = media_item_fixture(%{type: "movie"})

      media_file_fixture(%{
        media_item_id: movie.id,
        metadata: %Mydia.Library.Structs.FileMetadata{
          streams: [
            %Mydia.Library.Structs.StreamInfo{
              index: 2,
              type: :subtitle,
              codec: "hdmv_pgs_subtitle",
              language: "eng"
            }
          ]
        }
      })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}/2")

      assert json_response(conn, 415)["error"] =~
               "Image-based subtitles cannot be converted to text"
    end
  end

  describe "subtitle track listing file selection" do
    test "lists tracks for the highest-resolution file, not an arbitrary one", %{
      conn: conn,
      token: token
    } do
      movie = media_item_fixture(%{type: "movie"})

      _low = media_file_fixture(%{media_item_id: movie.id, resolution: "1080p"})
      high = media_file_fixture(%{media_item_id: movie.id, resolution: "4K"})

      {:ok, subtitle} =
        Repo.insert(%Mydia.Subtitles.Subtitle{
          media_file_id: high.id,
          language: "en",
          provider: "test",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: "/tmp/high-res-subtitle.srt",
          format: "srt"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}")

      assert %{"data" => tracks} = json_response(conn, 200)

      # The external subtitle is only attached to the 4K file, so it only
      # shows up here if the controller resolved to that file.
      track = Enum.find(tracks, fn t -> t["track_id"] == subtitle.id end)
      assert track != nil
    end

    test "never resolves to a trashed file", %{conn: conn, token: token} do
      movie = media_item_fixture(%{type: "movie"})

      # Created first, so an unfiltered/unordered preload would naturally
      # return it before the active file below.
      _trashed_uhd =
        media_file_fixture(%{
          media_item_id: movie.id,
          resolution: "4K",
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      active = media_file_fixture(%{media_item_id: movie.id, resolution: "1080p"})

      {:ok, subtitle} =
        Repo.insert(%Mydia.Subtitles.Subtitle{
          media_file_id: active.id,
          language: "en",
          provider: "test",
          subtitle_hash: "hash-#{System.unique_integer([:positive])}",
          file_path: "/tmp/active-file-subtitle.srt",
          format: "srt"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/player/v1/subtitles/movie/#{movie.id}")

      assert %{"data" => tracks} = json_response(conn, 200)

      # The external subtitle is only attached to the active (non-trashed)
      # file, so it only shows up here if the controller skipped the trashed
      # 4K file.
      track = Enum.find(tracks, fn t -> t["track_id"] == subtitle.id end)
      assert track != nil
    end
  end
end
