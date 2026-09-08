defmodule Mydia.Streaming.FfmpegPresetTest do
  use ExUnit.Case, async: true

  alias Mydia.Streaming.FfmpegHlsTranscoder

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp value_after(args, flag) do
    case Enum.find_index(args, &(&1 == flag)) do
      nil -> nil
      i -> Enum.at(args, i + 1)
    end
  end

  describe "preset" do
    test "defaults to veryfast, because a player is waiting on the first segment" do
      # x264's own default is "medium". On an AV1 source that took 29.6s to
      # write a playlist, against the 2 minute ceiling in Mydia.P2p.Server and,
      # before it was raised, a 30s one. A preset chosen for offline encoding
      # spends the viewer's wall clock on quality they never get to see.
      assert value_after(args([]), "-preset") == "veryfast"
    end

    test "an operator can still trade startup latency back for quality" do
      assert value_after(args(preset: "slow"), "-preset") == "slow"
    end

    test "carries no preset when the video is stream-copied" do
      # Nothing is being encoded, so a preset would be meaningless. This also
      # pins that the default above cannot leak into the copy path.
      assert value_after(args(video_codec: "copy"), "-preset") == nil
    end
  end
end
