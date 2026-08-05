defmodule Mydia.Streaming.FfmpegScaleCapTest do
  # async: false and an explicit restore: this mutates the cached runtime
  # config, which is global. A concurrent test reading it would otherwise see
  # this file's value and fail nondeterministically.
  use ExUnit.Case, async: false

  alias Mydia.Streaming.FfmpegHlsTranscoder

  setup do
    original = Application.get_env(:mydia, :runtime_config)

    on_exit(fn ->
      if original do
        Application.put_env(:mydia, :runtime_config, original)
      else
        Application.delete_env(:mydia, :runtime_config)
      end
    end)

    :ok
  end

  # Overrides only the :streaming embed of the layered runtime config
  # (Mydia.Config.get().streaming), which is what effective_max_height/1
  # reads. Writing the old flat Application.put_env(:mydia, :streaming, ...)
  # key here would be silently ignored — and that flat key is exactly what
  # made this setting unreachable to an operator, since config/config.exs is
  # compile-time and baked into the release.
  defp put_cap(value) do
    defaults = Mydia.Config.Schema.defaults()
    streaming = %{defaults.streaming | max_transcode_height: value}
    Application.put_env(:mydia, :runtime_config, %{defaults | streaming: streaming})
  end

  defp filter(opts) do
    args = FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
    index = Enum.find_index(args, &(&1 == "-vf"))
    if index, do: Enum.at(args, index + 1), else: nil
  end

  describe "max_transcode_height configuration" do
    test "applies the configured ceiling when no height was requested" do
      put_cap(1080)

      assert filter(video_codec: "libx264") == "scale=-2:2*trunc(min(1080\\,ih)/2)"
    end

    test "takes the lower of the request and the ceiling" do
      put_cap(720)

      assert filter(video_codec: "libx264", max_height: 1080) ==
               "scale=-2:2*trunc(min(720\\,ih)/2)"
    end

    test "honours a request below the ceiling" do
      put_cap(1080)

      assert filter(video_codec: "libx264", max_height: 480) ==
               "scale=-2:2*trunc(min(480\\,ih)/2)"
    end

    test "defaults to unlimited so nothing scales unasked" do
      put_cap(nil)

      assert filter(video_codec: "libx264") == nil
    end
  end

  describe "effective_max_height/1" do
    test "is the single source both the filter and the GraphQL echo derive from" do
      # The resolver composes through this same function so a server with a
      # ceiling set cannot tell a client "Original" while really scaling. If
      # this ever goes private again, that echo silently starts lying.
      put_cap(720)

      assert FfmpegHlsTranscoder.effective_max_height(nil) == 720
      assert FfmpegHlsTranscoder.effective_max_height(1080) == 720
      assert FfmpegHlsTranscoder.effective_max_height(480) == 480
    end

    test "leaves the request alone when no ceiling is configured" do
      put_cap(nil)

      assert FfmpegHlsTranscoder.effective_max_height(nil) == nil
      assert FfmpegHlsTranscoder.effective_max_height(720) == 720
    end
  end
end
