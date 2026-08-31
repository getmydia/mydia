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

  describe "final_segment_catchup/1" do
    setup do
      dir = Path.join(System.tmp_dir!(), "hls_catchup_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)

      %{playlist_path: Path.join(dir, "index.m3u8")}
    end

    test "reports segments that appear only after the last poll", %{
      playlist_path: playlist_path
    } do
      # The encoder wrote 101 and 102 in the gap between the last successful
      # poll (which only ever saw up to 100) and process exit. Nothing polled
      # again before the GenServer stopped.
      File.write!(playlist_path, """
      #EXTM3U
      #EXTINF:4.000000,
      segment_00100.ts
      #EXTINF:4.000000,
      segment_00101.ts
      #EXTINF:4.000000,
      segment_00102.ts
      """)

      test_pid = self()

      state = %FfmpegHlsTranscoder.State{
        playlist_path: playlist_path,
        ready_notified: true,
        seen_segments: MapSet.new([100]),
        on_segments: fn indices -> send(test_pid, {:segments, indices}) end
      }

      updated = FfmpegHlsTranscoder.final_segment_catchup(state)

      assert_receive {:segments, [101, 102]}
      assert updated.seen_segments == MapSet.new([100, 101, 102])
    end

    test "does not call on_segments when nothing new appeared", %{playlist_path: playlist_path} do
      File.write!(playlist_path, """
      #EXTM3U
      #EXTINF:4.000000,
      segment_00100.ts
      """)

      test_pid = self()

      state = %FfmpegHlsTranscoder.State{
        playlist_path: playlist_path,
        ready_notified: true,
        seen_segments: MapSet.new([100]),
        on_segments: fn indices -> send(test_pid, {:segments, indices}) end
      }

      FfmpegHlsTranscoder.final_segment_catchup(state)

      refute_received {:segments, _}
    end
  end
end
