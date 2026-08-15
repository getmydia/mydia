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
end
