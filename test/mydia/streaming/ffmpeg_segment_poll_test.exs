defmodule Mydia.Streaming.FfmpegSegmentPollTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  describe "finished_indices/1" do
    test "reads every segment FFmpeg has listed" do
      playlist = """
      #EXTM3U
      #EXT-X-VERSION:3
      #EXT-X-TARGETDURATION:4
      #EXT-X-MEDIA-SEQUENCE:100
      #EXTINF:4.000000,
      segment_00100.ts
      #EXTINF:4.000000,
      segment_00101.ts
      """

      assert FfmpegHlsTranscoder.finished_indices(playlist) == [100, 101]
    end

    test "returns nothing for a playlist with no segments yet" do
      assert FfmpegHlsTranscoder.finished_indices("#EXTM3U\n#EXT-X-VERSION:3\n") == []
    end

    test "ignores lines that are not segment filenames" do
      playlist = "#EXTM3U\nsubtitle_2.vtt\nsegment_00007.ts\n"

      assert FfmpegHlsTranscoder.finished_indices(playlist) == [7]
    end

    test "sorts indices ascending regardless of file order" do
      assert FfmpegHlsTranscoder.finished_indices("segment_00009.ts\nsegment_00002.ts\n") ==
               [2, 9]
    end
  end
end
