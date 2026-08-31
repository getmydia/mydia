defmodule Mydia.Streaming.SegmentPlanTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.SegmentPlan

  defp plan!(duration, seconds \\ 4) do
    {:ok, plan} = SegmentPlan.build(duration, seconds)
    plan
  end

  describe "build/2" do
    test "divides an exact multiple into whole segments" do
      assert %SegmentPlan{count: 15, segment_seconds: 4, duration: 60.0} = plan!(60.0)
    end

    test "rounds a partial final segment up into the count" do
      # 61s is fifteen full segments plus a 1s tail, which still needs an entry.
      assert %SegmentPlan{count: 16} = plan!(61.0)
    end

    test "accepts an integer duration" do
      assert %SegmentPlan{count: 15, duration: 60.0} = plan!(60)
    end

    test "refuses an unknown duration" do
      # ensure_duration_known/2 can return a file with no duration when the
      # inline probe budget is exceeded. That session has no plan and falls
      # back to the windowed playlist.
      assert SegmentPlan.build(nil, 4) == :error
    end

    test "refuses a zero or negative duration" do
      assert SegmentPlan.build(0, 4) == :error
      assert SegmentPlan.build(-10.0, 4) == :error
    end

    test "refuses a non-positive segment length" do
      assert SegmentPlan.build(60.0, 0) == :error
    end
  end

  describe "default_segment_seconds/0" do
    test "is four, matching the transcoder's -hls_time" do
      assert SegmentPlan.default_segment_seconds() == 4
    end
  end

  describe "start_time/2 and index_for_time/2" do
    test "segment n starts at n * segment_seconds" do
      assert SegmentPlan.start_time(plan!(600.0), 100) == 400.0
    end

    test "a time inside a segment maps back to that segment" do
      plan = plan!(600.0)
      assert SegmentPlan.index_for_time(plan, 400.0) == 100
      assert SegmentPlan.index_for_time(plan, 403.9) == 100
      assert SegmentPlan.index_for_time(plan, 404.0) == 101
    end

    test "floors a negative time at the first segment" do
      assert SegmentPlan.index_for_time(plan!(600.0), -5.0) == 0
    end

    test "clamps a time past the end onto the last segment" do
      # A client with a corrupt progress row can ask to resume past the end.
      plan = plan!(600.0)
      assert SegmentPlan.index_for_time(plan, 9999.0) == plan.count - 1
    end
  end

  describe "duration_of/2" do
    test "reports the full segment length for every segment but the last" do
      assert SegmentPlan.duration_of(plan!(61.0), 0) == 4.0
      assert SegmentPlan.duration_of(plan!(61.0), 14) == 4.0
    end

    test "reports the remainder for the final segment" do
      assert_in_delta SegmentPlan.duration_of(plan!(61.0), 15), 1.0, 0.000001
    end

    test "reports a full final segment when the duration divides exactly" do
      assert SegmentPlan.duration_of(plan!(60.0), 14) == 4.0
    end
  end

  describe "segment_name/1 and index_from_name/1" do
    test "pads the index to five digits" do
      assert SegmentPlan.segment_name(0) == "segment_00000.ts"
      assert SegmentPlan.segment_name(100) == "segment_00100.ts"
      assert SegmentPlan.segment_name(49_999) == "segment_49999.ts"
    end

    test "round-trips through index_from_name/1" do
      assert SegmentPlan.index_from_name(SegmentPlan.segment_name(742)) == {:ok, 742}
    end

    test "rejects anything that is not a segment filename" do
      # The controller feeds this every path under a session directory,
      # including subtitle tracks, so a non-match must be an ordinary answer
      # rather than a crash.
      assert SegmentPlan.index_from_name("index.m3u8") == :error
      assert SegmentPlan.index_from_name("subtitle_2.vtt") == :error
      assert SegmentPlan.index_from_name("segment_.ts") == :error
      assert SegmentPlan.index_from_name("../../etc/passwd") == :error
    end

    test "rejects a segment name with a trailing newline" do
      # Erlang's re treats an unanchored `$` as end-of-string OR just before one
      # trailing newline, so `$` here would accept this. The controller feeds this
      # function untrusted request paths, and its contract is that anything which
      # is not a segment filename returns :error.
      assert SegmentPlan.index_from_name("segment_00000.ts\n") == :error
    end

    test "rejects other trailing whitespace and control characters" do
      assert SegmentPlan.index_from_name("segment_00000.ts\r") == :error
      assert SegmentPlan.index_from_name("segment_00000.ts\r\n") == :error
      assert SegmentPlan.index_from_name("segment_00000.ts ") == :error
    end
  end

  describe "playlist/1" do
    test "declares a complete VOD playlist that ends" do
      text = SegmentPlan.playlist(plan!(61.0))

      assert text =~ "#EXTM3U"
      assert text =~ "#EXT-X-VERSION:3"
      assert text =~ "#EXT-X-TARGETDURATION:4"
      assert text =~ "#EXT-X-PLAYLIST-TYPE:VOD"
      assert String.ends_with?(text, "#EXT-X-ENDLIST\n")
    end

    test "lists every segment exactly once, in order" do
      text = SegmentPlan.playlist(plan!(61.0))
      names = Regex.scan(~r/segment_\d{5}\.ts/, text) |> List.flatten()

      assert length(names) == 16
      assert List.first(names) == "segment_00000.ts"
      assert List.last(names) == "segment_00015.ts"
    end

    test "declares the short final segment's real length" do
      text = SegmentPlan.playlist(plan!(61.0))

      assert text =~ "#EXTINF:1.000000,\nsegment_00015.ts"
    end

    test "never declares an EXTINF longer than the target duration" do
      # A player rejects a playlist whose TARGETDURATION is smaller than any
      # EXTINF it contains.
      plan = plan!(61.0)
      text = SegmentPlan.playlist(plan)

      durations =
        Regex.scan(~r/#EXTINF:([\d.]+),/, text)
        |> Enum.map(fn [_, d] -> String.to_float(d) end)

      assert Enum.max(durations) <= plan.segment_seconds
    end
  end
end
