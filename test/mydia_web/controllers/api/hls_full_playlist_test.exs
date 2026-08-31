defmodule MydiaWeb.Api.HlsFullPlaylistTest do
  @moduledoc """
  Covers `SegmentPlan` in isolation, and then the controller dispatch a
  `:full`-mode session takes: `master_playlist/2`'s `{:ok, playlist}` branch
  and `root_segment/2`'s `HlsSession.request_segment/2` branch, neither of
  which the plain `hls_controller_test.exs` conn tests reach (that file only
  ever requests three-digit legacy segment names, which fall through to the
  window path). Uses `Mydia.Streaming.HlsSessionStub` in place of a real
  `HlsSession` so no ffmpeg process is spawned.
  """

  use MydiaWeb.ConnCase, async: false

  alias Mydia.Streaming.HlsSessionStub
  alias Mydia.Streaming.SegmentPlan

  setup do
    {_user, token} = create_user_and_token()

    temp_dir = Path.join(System.tmp_dir!(), "hls_full_#{System.unique_integer([:positive])}")
    File.mkdir_p!(temp_dir)
    on_exit(fn -> File.rm_rf(temp_dir) end)

    session_id = "hls-full-#{System.unique_integer([:positive])}"

    {:ok, token: token, temp_dir: temp_dir, session_id: session_id}
  end

  describe "playlist rendering" do
    test "a full session's playlist covers the whole file and ends" do
      {:ok, plan} = SegmentPlan.build(600.0)
      text = SegmentPlan.playlist(plan)

      assert text =~ "#EXT-X-PLAYLIST-TYPE:VOD"
      assert String.ends_with?(text, "#EXT-X-ENDLIST\n")
      assert text =~ "segment_00149.ts"
    end
  end

  describe "segment name parsing at the controller boundary" do
    test "a segment filename resolves to an index" do
      assert SegmentPlan.index_from_name("segment_00100.ts") == {:ok, 100}
    end

    test "a subtitle filename does not, so it falls through to the file path" do
      # SessionSubtitles materializes .vtt tracks on demand. Routing one into
      # request_segment would ask the encoder to relocate to a segment that does
      # not exist.
      assert SegmentPlan.index_from_name("subtitle_2.vtt") == :error
    end

    test "a traversal attempt does not parse as a segment" do
      assert SegmentPlan.index_from_name("../../../etc/passwd") == :error
    end
  end

  describe "GET /api/v1/hls/:session_id/index.m3u8 (full mode)" do
    test "a full session's playlist is served with the HLS content type", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      {:ok, plan} = SegmentPlan.build(30.0)
      playlist_text = SegmentPlan.playlist(plan)

      {:ok, _pid} =
        HlsSessionStub.start_link(session_id, %{media_file_id: "unused", temp_dir: dir}, %{
          playlist: {:ok, playlist_text}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/index.m3u8")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "application/vnd.apple.mpegurl")
      assert conn.resp_body == playlist_text
    end
  end

  describe "GET /api/v1/hls/:session_id/:segment (full mode)" do
    test "a full-mode segment is served from the path the session resolves", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      segment_path = Path.join(dir, "segment_00042.ts")
      File.write!(segment_path, "tsdata")

      {:ok, _pid} =
        HlsSessionStub.start_link(session_id, %{media_file_id: "unused", temp_dir: dir}, %{
          request_segment: {:ok, segment_path}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/segment_00042.ts")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "video/mp2t")
      assert conn.resp_body == "tsdata"
    end

    test "a segment timeout returns 503 with Retry-After, not 404", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      {:ok, _pid} =
        HlsSessionStub.start_link(session_id, %{media_file_id: "unused", temp_dir: dir}, %{
          request_segment: {:error, :timeout}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/segment_00042.ts")

      assert conn.status == 503
      assert get_resp_header(conn, "retry-after") == ["1"]
      assert json_response(conn, 503)["error"] =~ "not ready"
    end

    # If the controller mis-routed a subtitle name into request_segment/2,
    # this session would answer with a timeout and the response would be a
    # 503 rather than the materialized track.
    test "a subtitle name still routes to the window path, not request_segment", %{
      conn: conn,
      token: token,
      temp_dir: dir,
      session_id: session_id
    } do
      File.write!(Path.join(dir, "subs_2.vtt"), "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n")

      {:ok, _pid} =
        HlsSessionStub.start_link(session_id, %{media_file_id: "unused", temp_dir: dir}, %{
          request_segment: {:error, :timeout}
        })

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/v1/hls/#{session_id}/subs_2.vtt")

      assert conn.status == 200
      [content_type] = get_resp_header(conn, "content-type")
      assert String.starts_with?(content_type, "text/vtt")
      assert conn.resp_body =~ "WEBVTT"
    end
  end
end
