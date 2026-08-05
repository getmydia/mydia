defmodule Mydia.Streaming.FfmpegScaleCapTest do
  # async: false and an explicit restore: this mutates application env, which
  # is global. A concurrent test reading :streaming config would otherwise see
  # this file's value and fail nondeterministically.
  use ExUnit.Case, async: false

  alias Mydia.Streaming.FfmpegHlsTranscoder

  setup do
    original = Application.get_env(:mydia, :streaming, [])
    on_exit(fn -> Application.put_env(:mydia, :streaming, original) end)
    {:ok, original: original}
  end

  defp put_cap(original, value) do
    Application.put_env(
      :mydia,
      :streaming,
      Keyword.put(original, :max_transcode_height, value)
    )
  end

  defp filter(opts) do
    args = FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
    index = Enum.find_index(args, &(&1 == "-vf"))
    if index, do: Enum.at(args, index + 1), else: nil
  end

  describe "max_transcode_height configuration" do
    test "applies the configured ceiling when no height was requested",
         %{original: original} do
      put_cap(original, 1080)

      assert filter(video_codec: "libx264") == "scale=-2:min(1080\\,ih)"
    end

    test "takes the lower of the request and the ceiling",
         %{original: original} do
      put_cap(original, 720)

      assert filter(video_codec: "libx264", max_height: 1080) ==
               "scale=-2:min(720\\,ih)"
    end

    test "honours a request below the ceiling", %{original: original} do
      put_cap(original, 1080)

      assert filter(video_codec: "libx264", max_height: 480) ==
               "scale=-2:min(480\\,ih)"
    end

    test "defaults to unlimited so nothing scales unasked",
         %{original: original} do
      put_cap(original, nil)

      assert filter(video_codec: "libx264") == nil
    end
  end
end
