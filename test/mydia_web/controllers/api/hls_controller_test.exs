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

  alias Mydia.Library.Structs.FileMetadata
  alias Mydia.Library.Structs.StreamInfo
  alias Mydia.Streaming.HlsSessionStub

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
end
