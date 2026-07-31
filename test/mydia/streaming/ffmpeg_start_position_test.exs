defmodule Mydia.Streaming.FfmpegStartPositionTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.FfmpegHlsTranscoder
  alias MydiaWeb.Schema.Resolvers.StreamingResolver

  defp args(opts) do
    FfmpegHlsTranscoder.build_ffmpeg_args("/tmp/in.mkv", "/tmp/out", opts)
  end

  defp index_of(args, value), do: Enum.find_index(args, &(&1 == value))

  describe "build_ffmpeg_args/3 start_position" do
    test "omits -ss entirely when no start position is given" do
      refute "-ss" in args([])
    end

    test "omits -ss when the start position is zero" do
      refute "-ss" in args(start_position: 0)
    end

    test "emits -ss with the requested offset in seconds" do
      result = args(start_position: 4200)

      assert "-ss" in result
      assert Enum.at(result, index_of(result, "-ss") + 1) == "4200"
    end

    test "places -ss before -i so FFmpeg uses fast input seeking" do
      # Output seeking (-ss after -i) decodes and discards everything up to the
      # offset, which for a resume an hour in would take far longer than the
      # user is willing to wait.
      result = args(start_position: 4200)

      assert index_of(result, "-ss") < index_of(result, "-i")
    end

    test "keeps the input path immediately after -i" do
      result = args(start_position: 4200)

      assert Enum.at(result, index_of(result, "-i") + 1) == "/tmp/in.mkv"
    end

    test "still ends with the playlist path" do
      assert List.last(args(start_position: 60)) == "/tmp/out/index.m3u8"
    end
  end

  describe "clamp_start_position/2" do
    test "passes a valid offset through unchanged" do
      assert StreamingResolver.clamp_start_position(4200, 5400.0) == 4200
    end

    test "treats nil as no offset" do
      assert StreamingResolver.clamp_start_position(nil, 5400.0) == 0
    end

    test "floors a negative offset at zero" do
      assert StreamingResolver.clamp_start_position(-30, 5400.0) == 0
    end

    test "clamps an offset past the end back inside the media" do
      # A client with a corrupted progress row could ask to resume beyond the
      # end. Starting FFmpeg there would produce an empty playlist.
      assert StreamingResolver.clamp_start_position(9999, 5400.0) == 5399
    end

    test "accepts any non-negative offset when the duration is unknown" do
      # Nothing to clamp against; the transcoder simply produces an empty
      # playlist if the client was wrong, which is no worse than today.
      assert StreamingResolver.clamp_start_position(4200, nil) == 4200
    end

    test "never returns a negative offset, even for a sub-second duration" do
      # trunc(0.5) - 1 is -1. A negative offset would be echoed to the client
      # and shift every position it derives from the stream timeline.
      assert StreamingResolver.clamp_start_position(10, 0.5) == 0
    end
  end

  describe "ensure_duration_known/2 inline probe budget" do
    test "falls back to the unprobed struct promptly when the budget is exceeded" do
      # No DB row, no ffprobe, no real file needed: the struct just has to
      # point at a path that does not exist, so the spawned probe task's very
      # first step is a real File.exists?/1 syscall rather than pure in-memory
      # work. Measured empirically (20,000 trials): a trivial `:ok`-returning
      # task wins a `Task.yield(task, 0)` race ~0.35% of the time, but a task
      # whose first step is File.exists?/1 on a missing path never did (0/20
      # 000) — the syscall reliably takes long enough that a budget of 0 is a
      # deterministic, non-flaky way to force the fallback branch without
      # mutating any global config (:ffprobe_timeout_ms or otherwise) to
      # simulate a slow probe.
      media_file = %MediaFile{
        id: Ecto.UUID.generate(),
        analyzed_at: nil,
        relative_path: "ghost.mkv",
        library_path: %LibraryPath{
          path: "/nonexistent-#{System.unique_integer([:positive])}"
        }
      }

      {elapsed_us, result} =
        :timer.tc(fn -> StreamingResolver.ensure_duration_known(media_file, 0) end)

      # Promptly: nowhere near the 3s default budget, let alone ffprobe's own
      # 30s timeout. A generous bound avoids flaking on a loaded CI box while
      # still catching a regression that removes the timeout altogether.
      assert elapsed_us < 500_000

      # The session still starts with a nil duration rather than raising or
      # hanging: the caller gets back the exact struct it went in with.
      assert result == media_file
    end
  end
end
