defmodule MydiaWeb.Api.HlsControllerTest do
  @moduledoc """
  Exercises `root_segment/2` through the real plug pipeline: routing, auth,
  and the controller's own `with`/`else` branching.

  `SessionSubtitles.ensure/2` and `SessionFiles`'s own behaviour
  (materialization, the image-subtitle rejection, path-traversal rejection,
  content-type mapping) are unit-tested directly in
  `test/mydia/streaming/session_subtitles_test.exs` and
  `test/mydia/streaming/session_files_test.exs`. This file exists only to
  prove `root_segment/2` wires those outcomes to the right HTTP status and
  headers, and that the subtitle branch does not swallow ordinary segment
  serving. It uses `Mydia.Streaming.HlsSessionStub` in place of a real
  `HlsSession` so no ffmpeg process is spawned.
  """

  use MydiaWeb.ConnCase, async: false

  import Mydia.MediaFixtures

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Plugins.SingleFlight
  alias Mydia.Streaming.HlsSessionStub
  alias Mydia.Subtitles.ImageTrack

  setup do
    {_user, token} = create_user_and_token()

    temp_dir = Path.join(System.tmp_dir!(), "hls_ctrl_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    session_id = "hls-ctrl-#{System.unique_integer([:positive])}"

    {:ok, token: token, temp_dir: temp_dir, session_id: session_id}
  end

  # Registers the stub session for the given info, defaulting to an unused
  # media_file_id: most cases here never reach materialize/3 because the
  # file already exists on disk or the name never parses as a subtitle.
  defp register_session(session_id, temp_dir, media_file_id \\ "unused") do
    {:ok, _pid} =
      HlsSessionStub.start_link(session_id, %{
        media_file_id: media_file_id,
        temp_dir: temp_dir
      })

    :ok
  end

  describe "GET /api/v1/hls/:session_id/:segment" do
    test "a materialized subtitle returns 200 with a text/vtt content type", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)
      File.write!(Path.join(dir, "subs_2.vtt"), "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_2.vtt")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "text/vtt")
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body =~ "WEBVTT"
    end

    test "an image-based subtitle track returns 415, not 404", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      media_file =
        media_file_fixture(%{
          metadata: %FileMetadata{
            streams: [
              %StreamInfo{index: 3, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "spa"}
            ]
          }
        })

      register_session(session_id, dir, media_file.id)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_3.vtt")

      assert conn.status == 415
      assert json_response(conn, 415)["error"] =~ "Image-based subtitles"
      refute File.exists?(Path.join(dir, "subs_3.vtt"))
    end

    test "a traversal-shaped segment name returns 403", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/..")

      assert conn.status == 403
    end

    test "an ordinary segment name still falls through to normal file serving", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)
      File.write!(Path.join(dir, "segment_001.ts"), "tsdata")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/segment_001.ts")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "video/mp2t")
      assert get_resp_header(conn, "cache-control") == ["public, max-age=31536000, immutable"]
      assert conn.resp_body == "tsdata"
    end

    test "an unmaterialized, nonexistent segment still returns 404", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/segment_999.ts")

      assert conn.status == 404
    end

    test "requires authentication", %{conn: conn, temp_dir: dir, session_id: session_id} do
      register_session(session_id, dir)

      conn = get(conn, "/api/v1/hls/#{session_id}/segment_001.ts")

      assert conn.status in [401, 302]
    end
  end

  describe "GET /api/v1/hls/:session_id/:track_id/index.m3u8" do
    test "an ordinary track_id still serves the variant playlist", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)
      track_dir = Path.join(dir, "0")
      File.mkdir_p!(track_dir)
      File.write!(Path.join(track_dir, "index.m3u8"), "#EXTM3U\n")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/0/index.m3u8")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/vnd.apple.mpegurl")
      assert conn.resp_body =~ "#EXTM3U"
    end

    # Phoenix URI-decodes each path segment before matching routes (see
    # `Phoenix.Router.call/2`), so a track_id of `..%2F..%2Fetc` arrives here
    # decoded to the single path_info segment "../../etc" - a string that
    # itself contains slashes - not rejected or split by the router. Only
    # `SessionFiles.safe_path/2` stands between that value and `File.read/1`.
    test "a traversal-shaped track_id returns 403", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      register_session(session_id, dir)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/..%2F..%2Fetc/index.m3u8")

      assert conn.status == 403
    end
  end

  describe "GET /api/v1/hls/:session_id/subs_<index>.mks" do
    setup %{temp_dir: dir, session_id: session_id} do
      media_file =
        media_file_fixture(%{
          metadata: %FileMetadata{
            streams: [
              %StreamInfo{index: 2, type: :subtitle, codec: "subrip", language: "eng"},
              %StreamInfo{index: 3, type: :subtitle, codec: "hdmv_pgs_subtitle", language: "spa"}
            ]
          }
        })
        |> Mydia.Repo.preload(:library_path)

      source = MediaFile.absolute_path(media_file)
      File.mkdir_p!(Path.dirname(source))
      File.write!(source, "placeholder")
      {:ok, cached} = ImageTrack.cache_path(media_file, 3)

      on_exit(fn ->
        File.rm_rf(media_file.library_path.path)
        File.rm_rf(Path.dirname(cached))
      end)

      register_session(session_id, dir, media_file.id)
      {:ok, cached: cached}
    end

    test "a copied track returns 200 and is revalidated rather than cached for good", %{
      conn: conn,
      token: token,
      session_id: session_id,
      cached: cached
    } do
      File.mkdir_p!(Path.dirname(cached))
      File.write!(cached, "mks bytes")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_3.mks")

      assert conn.status == 200
      assert get_resp_header(conn, "cache-control") == ["no-cache"]
      assert conn.resp_body == "mks bytes"
    end

    test "a track still being copied returns 503 with Retry-After", %{
      conn: conn,
      token: token,
      session_id: session_id,
      cached: cached
    } do
      :ok =
        SingleFlight.acquire(ImageTrack.lock_slug(cached), :skip, Mydia.Streaming.SubtitleLock)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_3.mks")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["2"]
    end

    test "a failed copy returns 415", %{
      conn: conn,
      token: token,
      session_id: session_id,
      cached: cached
    } do
      File.mkdir_p!(Path.dirname(cached))
      File.write!(ImageTrack.failed_marker(cached), "boom")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_3.mks")

      assert conn.status == 415
    end

    test "a text stream asked for as a bitmap returns 404", %{
      conn: conn,
      token: token,
      session_id: session_id
    } do
      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_2.mks")

      assert conn.status == 404
    end
  end
end
