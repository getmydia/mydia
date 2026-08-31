defmodule MydiaWeb.Api.HlsFullPlaylistTest do
  use MydiaWeb.ConnCase, async: false

  alias Mydia.Streaming.SegmentPlan

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
end
