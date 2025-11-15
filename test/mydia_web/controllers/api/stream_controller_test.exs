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
end
