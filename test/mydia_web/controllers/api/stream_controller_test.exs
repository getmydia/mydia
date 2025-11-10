defmodule MydiaWeb.Api.StreamControllerTest do
  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  setup do
    # Create test user and get auth token
    user = MydiaWeb.AuthHelpers.create_test_user()
    {_user, token} = MydiaWeb.AuthHelpers.create_user_and_token()

    # Create a test media file with actual file on disk
    test_file_path = create_test_video_file()
    media_file = media_file_fixture(%{path: test_file_path})

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
      file_stat = File.stat!(media_file.path)
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
      # Create a media file record with non-existent path
      media_file = media_file_fixture(%{path: "/nonexistent/file.mp4"})

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

    test "sets correct MIME type for different file extensions", %{conn: _conn, token: token} do
      test_files = [
        {".mp4", "mp4", "h264", "aac", "video/mp4"},
        {".webm", "webm", "vp9", "opus", "video/webm"}
      ]

      for {ext, container, codec, audio_codec, expected_mime} <- test_files do
        # Create test file with specific extension
        test_path = create_test_video_file(ext)

        media_file =
          media_file_fixture(%{
            path: test_path,
            codec: codec,
            audio_codec: audio_codec,
            metadata: %{"container" => container}
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

  # Helper to create a small test video file
  defp create_test_video_file(ext \\ ".mp4") do
    # Create temp directory if it doesn't exist
    temp_dir = System.tmp_dir!()
    test_file_path = Path.join(temp_dir, "test_video_#{System.unique_integer([:positive])}#{ext}")

    # Create a small dummy file (not a real video, but good enough for HTTP range testing)
    File.write!(test_file_path, :crypto.strong_rand_bytes(1024 * 10))

    test_file_path
  end
end
