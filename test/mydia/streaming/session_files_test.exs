defmodule Mydia.Streaming.SessionFilesTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.SessionFiles

  describe "content_type/1" do
    test "maps HLS media extensions" do
      assert SessionFiles.content_type("index.m3u8") == "application/vnd.apple.mpegurl"
      assert SessionFiles.content_type("segment_001.ts") == "video/mp2t"
      assert SessionFiles.content_type("init.mp4") == "video/mp4"
      assert SessionFiles.content_type("seg.m4s") == "video/iso.segment"
    end

    test "maps .vtt to text/vtt, which a Chromecast requires for a text track" do
      assert SessionFiles.content_type("subs_3.vtt") == "text/vtt"
      assert SessionFiles.content_type("/tmp/hls/abc/subs_3.vtt") == "text/vtt"
    end

    test "maps .mks, the bitmap subtitle sidecar, to Matroska" do
      assert SessionFiles.content_type("subs_3.mks") == "application/x-matroska"
    end

    test "falls back to octet-stream" do
      assert SessionFiles.content_type("mystery.xyz") == "application/octet-stream"
    end
  end

  describe "safe_path/2" do
    test "resolves a plain name inside the directory" do
      assert {:ok, path} = SessionFiles.safe_path("/tmp/hls/abc", "segment_001.ts")
      assert path == "/tmp/hls/abc/segment_001.ts"
    end

    test "rejects traversal out of the directory" do
      assert {:error, :path_traversal} =
               SessionFiles.safe_path("/tmp/hls/abc", "../../etc/passwd")
    end

    test "rejects an absolute path" do
      assert {:error, :path_traversal} = SessionFiles.safe_path("/tmp/hls/abc", "/etc/passwd")
    end

    # The old p2p validate_path/2 used a bare String.starts_with?, so a sibling
    # directory sharing a prefix passed. This is the case that proves it fixed.
    test "rejects a sibling directory that shares the base as a string prefix" do
      assert {:error, :path_traversal} =
               SessionFiles.safe_path("/tmp/hls/abc", "../abcdef/secret.ts")
    end

    # segment/2's Membrane-style candidate joins two user-controlled params
    # (track_id and segment) into a single relative name before validating.
    # Neither component alone escapes the base, only their join does.
    test "rejects a two-component relative name that escapes only once joined" do
      joined = Path.join("track_0", "../../etc")

      assert {:error, :path_traversal} = SessionFiles.safe_path("/tmp/hls/abc", joined)
    end
  end

  defmodule StubSession do
    @moduledoc false
    use GenServer

    def start_link(replies), do: GenServer.start_link(__MODULE__, replies)

    @impl true
    def init(replies), do: {:ok, replies}

    @impl true
    def handle_call(:playlist, _from, replies), do: {:reply, replies.playlist, replies}

    def handle_call({:request_segment, index}, _from, replies),
      do: {:reply, replies.segment.(index), replies}
  end

  describe "resolve/3" do
    setup do
      dir =
        Path.join(
          System.tmp_dir!(),
          "session_files_resolve_#{System.unique_integer([:positive])}"
        )

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      %{info: %{temp_dir: dir, media_file_id: "none"}, dir: dir}
    end

    defp session(playlist, segment \\ fn _ -> {:error, :window_mode} end) do
      start_supervised!({StubSession, %{playlist: playlist, segment: segment}})
    end

    test "a full session's playlist is the published one, not the file on disk", %{info: info} do
      pid = session({:ok, "#EXTM3U\n#EXT-X-ENDLIST\n"})

      assert SessionFiles.resolve(pid, info, "index.m3u8") ==
               {:ok, {:content, "#EXTM3U\n#EXT-X-ENDLIST\n"}}
    end

    test "a window session's playlist is the file on disk", %{info: info, dir: dir} do
      pid = session({:error, :window_mode})

      assert SessionFiles.resolve(pid, info, "index.m3u8") ==
               {:ok, {:file, Path.join(dir, "index.m3u8")}}
    end

    test "a full session's segment goes through the session", %{info: info} do
      pid = session({:ok, ""}, fn 7 -> {:ok, "/somewhere/segment_00007.ts"} end)

      assert SessionFiles.resolve(pid, info, "segment_00007.ts") ==
               {:ok, {:file, "/somewhere/segment_00007.ts"}}
    end

    test "a segment the encoder has not reached is a timeout", %{info: info} do
      pid = session({:ok, ""}, fn _ -> {:error, :timeout} end)
      assert SessionFiles.resolve(pid, info, "segment_00007.ts") == {:error, :timeout}
    end

    test "a segment outside the plan is out of range", %{info: info} do
      pid = session({:ok, ""}, fn _ -> {:error, :out_of_range} end)
      assert SessionFiles.resolve(pid, info, "segment_99999.ts") == {:error, :out_of_range}
    end

    test "a window session's segment is the file on disk", %{info: info, dir: dir} do
      pid = session({:error, :window_mode})

      assert SessionFiles.resolve(pid, info, "segment_00007.ts") ==
               {:ok, {:file, Path.join(dir, "segment_00007.ts")}}
    end

    test "any other name resolves inside the session directory", %{info: info, dir: dir} do
      pid = session({:ok, ""})

      assert SessionFiles.resolve(pid, info, "init.mp4") ==
               {:ok, {:file, Path.join(dir, "init.mp4")}}
    end

    test "a name that escapes the session directory is refused", %{info: info} do
      pid = session({:ok, ""})
      assert SessionFiles.resolve(pid, info, "../other/index.m3u8") == {:error, :path_traversal}
    end
  end
end
