defmodule MydiaWeb.Api.StreamControllerTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.Library.MediaFile

  setup do
    # Create test user and get auth token
    user = MydiaWeb.AuthHelpers.create_test_user()
    {_user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    # Create a test library path
    library_path = library_path_fixture()

    # Create the library directory if it doesn't exist
    File.mkdir_p!(library_path.path)

    # Create a test video file in the library path
    test_file_name = "test_video_#{System.unique_integer([:positive])}.mp4"
    test_file_path = Path.join(library_path.path, test_file_name)
    File.write!(test_file_path, :crypto.strong_rand_bytes(1024 * 10))

    # Create media file with relative path
    media_file =
      media_file_fixture(%{
        library_path_id: library_path.id,
        relative_path: test_file_name
      })

    # Preload library_path for absolute path resolution
    media_file = Mydia.Repo.preload(media_file, :library_path)

    on_exit(fn ->
      # Clean up test file
      if File.exists?(test_file_path) do
        File.rm!(test_file_path)
      end
    end)

    {:ok, user: user, token: token, media_file: media_file, test_file_path: test_file_path}
  end

  describe "GET /api/v1/stream/:id" do
    test "streams full file when no Range header is present", %{
      conn: conn,
      token: token,
      media_file: media_file
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/#{media_file.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "accept-ranges") == ["bytes"]
      assert get_resp_header(conn, "content-type") == ["video/mp4"]
      assert get_resp_header(conn, "content-length") |> List.first() |> String.to_integer() > 0
    end

    test "returns 206 Partial Content for range requests", %{
      conn: conn,
      token: token,
      media_file: media_file
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("range", "bytes=0-499")
        |> get("/api/v1/stream/#{media_file.id}")

      assert conn.status == 206
      assert get_resp_header(conn, "content-range") |> List.first() =~ ~r/bytes 0-499\/\d+/
      assert get_resp_header(conn, "content-length") == ["500"]
    end

    test "handles range request from offset to end", %{
      conn: conn,
      token: token,
      media_file: media_file
    } do
      file_path = MediaFile.absolute_path(media_file)
      file_stat = File.stat!(file_path)
      file_size = file_stat.size

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("range", "bytes=100-")
        |> get("/api/v1/stream/#{media_file.id}")

      assert conn.status == 206

      [content_range] = get_resp_header(conn, "content-range")
      assert content_range == "bytes 100-#{file_size - 1}/#{file_size}"

      [content_length] = get_resp_header(conn, "content-length")
      assert String.to_integer(content_length) == file_size - 100
    end

    test "returns 416 for invalid range requests", %{
      conn: conn,
      token: token,
      media_file: media_file
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> put_req_header("range", "bytes=invalid-range")
        |> get("/api/v1/stream/#{media_file.id}")

      assert conn.status == 416
      assert json_response(conn, 416)["error"] == "Invalid range request"
    end

    test "returns 404 for non-existent media file", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/00000000-0000-0000-0000-000000000000")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "Media file not found"
    end

    test "returns 404 when file doesn't exist on disk", %{
      conn: conn,
      token: token
    } do
      # Create a media file record with non-existent relative path
      media_file =
        media_file_fixture(%{relative_path: "nonexistent/file.mp4"})
        |> Mydia.Repo.preload(:library_path)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/#{media_file.id}")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "Media file not found on disk"
    end

    test "requires authentication", %{conn: conn, media_file: media_file} do
      conn = get(conn, "/api/v1/stream/#{media_file.id}")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end

    test "streaming a fixture file runs no ffprobe analysis", %{
      conn: conn,
      token: token,
      media_file: media_file
    } do
      conn
      |> put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/stream/#{media_file.id}")

      reloaded = Mydia.Repo.get!(MediaFile, media_file.id)

      # A fixture file is 10KB of random bytes. If the request analyzes it,
      # ffprobe's reading of noise replaces the codec fields the test set up
      # and the streaming decision stops being deterministic.
      assert reloaded.analyzed_at == media_file.analyzed_at
      assert reloaded.analysis_attempts == media_file.analysis_attempts
      assert reloaded.codec == media_file.codec
      assert reloaded.audio_codec == media_file.audio_codec
    end

    test "sets correct MIME type for different file extensions", %{conn: _conn, token: token} do
      test_files = [
        {".mp4", "mp4", "h264", "aac", "video/mp4"},
        {".webm", "webm", "vp9", "opus", "video/webm"}
      ]

      for {ext, container, codec, audio_codec, expected_mime} <- test_files do
        # Create test library path
        library_path = library_path_fixture()
        File.mkdir_p!(library_path.path)

        # Create test file with specific extension
        test_file_name = "test_video_#{System.unique_integer([:positive])}#{ext}"
        test_path = Path.join(library_path.path, test_file_name)
        File.write!(test_path, :crypto.strong_rand_bytes(1024 * 10))

        media_file =
          media_file_fixture(%{
            library_path_id: library_path.id,
            relative_path: test_file_name,
            codec: codec,
            audio_codec: audio_codec,
            metadata: %{"container" => container, "duration" => 120.5}
          })

        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer #{token}")
          |> get("/api/v1/stream/#{media_file.id}")

        assert get_resp_header(conn, "content-type") == [expected_mime]

        # Clean up
        File.rm!(test_path)
      end
    end
  end

  describe "GET /api/v1/stream/:content_type/:id/candidates" do
    test "returns candidates for a movie with direct play compatible file", %{
      conn: conn,
      token: token
    } do
      # Create a test movie with H.264 + AAC (direct play compatible)
      library_path = library_path_fixture()
      File.mkdir_p!(library_path.path)
      test_file_name = "movie_#{System.unique_integer([:positive])}.mp4"
      test_file_path = Path.join(library_path.path, test_file_name)
      File.write!(test_file_path, :crypto.strong_rand_bytes(1024 * 10))

      media_item = media_item_fixture(%{type: "movie"})

      _media_file =
        media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: test_file_name,
          media_item_id: media_item.id,
          codec: "h264",
          audio_codec: "aac",
          metadata: %{"container" => "mp4", "duration" => 120.5}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/#{media_item.id}/candidates")

      assert conn.status == 200
      response = json_response(conn, 200)

      assert is_list(response["candidates"])
      assert response["candidates"] != []

      # First candidate should be DIRECT_PLAY for compatible file
      first_candidate = List.first(response["candidates"])
      assert first_candidate["strategy"] == "DIRECT_PLAY"
      assert first_candidate["container"] == "mp4"
      assert first_candidate["mime"] =~ "video/mp4"

      # Metadata should be present
      assert response["metadata"]["duration"] == 120.5
      assert response["metadata"]["original_codec"] == "h264"
      assert response["metadata"]["original_audio_codec"] == "aac"

      # Clean up
      File.rm!(test_file_path)
    end

    test "returns candidates for episode with HEVC (needs transcoding)", %{
      conn: conn,
      token: token
    } do
      # Create a test episode with HEVC (needs transcoding for most browsers)
      # Need to use a series library type for episodes
      library_path = library_path_fixture(%{type: :series})
      File.mkdir_p!(library_path.path)
      test_file_name = "episode_#{System.unique_integer([:positive])}.mkv"
      test_file_path = Path.join(library_path.path, test_file_name)
      File.write!(test_file_path, :crypto.strong_rand_bytes(1024 * 10))

      media_item = media_item_fixture(%{type: "tv_show"})
      episode = episode_fixture(%{media_item_id: media_item.id})

      _media_file =
        media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: test_file_name,
          episode_id: episode.id,
          codec: "hevc",
          audio_codec: "aac",
          metadata: %{"container" => "mkv", "duration" => 2400.0}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/episode/#{episode.id}/candidates")

      assert conn.status == 200
      response = json_response(conn, 200)

      assert is_list(response["candidates"])
      assert response["candidates"] != []

      # Should have HLS_COPY candidates for native HEVC support (Safari)
      # and TRANSCODE fallback
      strategies = Enum.map(response["candidates"], & &1["strategy"])
      assert "TRANSCODE" in strategies

      # At least one candidate should have HEVC codec string
      hevc_candidates =
        Enum.filter(response["candidates"], fn c ->
          c["video_codec"] && String.starts_with?(c["video_codec"], "hvc1")
        end)

      assert hevc_candidates != []

      # Transcode candidate should have H.264
      transcode_candidate = Enum.find(response["candidates"], &(&1["strategy"] == "TRANSCODE"))
      assert transcode_candidate["video_codec"] =~ "avc1"

      # Clean up
      File.rm!(test_file_path)
    end

    test "returns candidates for MKV with H.264 (needs remux)", %{
      conn: conn,
      token: token
    } do
      # Create a test movie with H.264 in MKV container (needs remux)
      library_path = library_path_fixture()
      File.mkdir_p!(library_path.path)
      test_file_name = "remux_test_#{System.unique_integer([:positive])}.mkv"
      test_file_path = Path.join(library_path.path, test_file_name)
      File.write!(test_file_path, :crypto.strong_rand_bytes(1024 * 10))

      media_item = media_item_fixture(%{type: "movie"})

      _media_file =
        media_file_fixture(%{
          library_path_id: library_path.id,
          relative_path: test_file_name,
          media_item_id: media_item.id,
          codec: "h264",
          audio_codec: "aac",
          metadata: %{"container" => "mkv", "duration" => 120.5}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/#{media_item.id}/candidates")

      assert conn.status == 200
      response = json_response(conn, 200)

      # First candidate should be REMUX (container conversion only)
      first_candidate = List.first(response["candidates"])
      assert first_candidate["strategy"] == "REMUX"
      assert first_candidate["container"] == "mp4"

      # Should also have HLS_COPY fallback
      strategies = Enum.map(response["candidates"], & &1["strategy"])
      assert "HLS_COPY" in strategies

      # Clean up
      File.rm!(test_file_path)
    end

    test "returns 404 for non-existent movie", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/00000000-0000-0000-0000-000000000000/candidates")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "movie not found"
    end

    test "returns 404 for non-existent episode", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/episode/00000000-0000-0000-0000-000000000000/candidates")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "episode not found"
    end

    test "returns 400 for invalid content type", %{conn: conn, token: token} do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/invalid/some-id/candidates")

      assert conn.status == 400
      assert json_response(conn, 400)["error"] =~ "Invalid content type"
    end

    test "returns 404 when movie has no media files", %{conn: conn, token: token} do
      # Create a movie without any media files
      media_item = media_item_fixture(%{type: "movie"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/#{media_item.id}/candidates")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "No media files available"
    end

    test "requires authentication", %{conn: conn} do
      conn = get(conn, "/api/v1/stream/movie/some-id/candidates")

      # Should get 401 Unauthorized or redirect to login
      assert conn.status in [401, 302]
    end
  end

  describe "stream_movie/2 file selection" do
    test "streams the highest-resolution file, not an arbitrary one", %{
      conn: conn,
      token: token
    } do
      movie = media_item_fixture(%{type: "movie"})
      library_path = library_path_fixture()
      File.mkdir_p!(library_path.path)

      lowres_name = "lowres_#{System.unique_integer([:positive])}.mp4"
      lowres_path = Path.join(library_path.path, lowres_name)
      File.write!(lowres_path, String.duplicate("l", 100))

      uhd_name = "uhd_#{System.unique_integer([:positive])}.mp4"
      uhd_path = Path.join(library_path.path, uhd_name)
      File.write!(uhd_path, String.duplicate("u", 500))

      _lowres =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: library_path.id,
          relative_path: lowres_name,
          resolution: "1080p"
        })

      _uhd =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: library_path.id,
          relative_path: uhd_name,
          resolution: "4K"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/#{movie.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-length") == ["500"]
      assert conn.resp_body == String.duplicate("u", 500)

      File.rm!(lowres_path)
      File.rm!(uhd_path)
    end

    test "never selects a trashed file", %{conn: conn, token: token} do
      movie = media_item_fixture(%{type: "movie"})
      library_path = library_path_fixture()
      File.mkdir_p!(library_path.path)

      active_name = "active_#{System.unique_integer([:positive])}.mp4"
      active_path = Path.join(library_path.path, active_name)
      File.write!(active_path, String.duplicate("a", 100))

      trashed_name = "trashed_#{System.unique_integer([:positive])}.mp4"
      trashed_path = Path.join(library_path.path, trashed_name)
      File.write!(trashed_path, String.duplicate("t", 500))

      # Created before the active file: the pre-fix implementation takes the
      # head of an unordered preload, so creation order determines what an
      # unfiltered query returns first. Trashed-first is what makes this test
      # genuinely fail before the trashed_at filter exists (see task report).
      _trashed =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: library_path.id,
          relative_path: trashed_name,
          resolution: "4K",
          trashed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      _active =
        media_file_fixture(%{
          media_item_id: movie.id,
          library_path_id: library_path.id,
          relative_path: active_name,
          resolution: "1080p"
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/stream/movie/#{movie.id}")

      assert conn.status == 200
      assert get_resp_header(conn, "content-length") == ["100"]
      assert conn.resp_body == String.duplicate("a", 100)

      File.rm!(active_path)
      File.rm!(trashed_path)
    end
  end
end
