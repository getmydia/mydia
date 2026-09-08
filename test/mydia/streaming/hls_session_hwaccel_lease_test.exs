defmodule Mydia.Streaming.HlsSessionHwaccelLeaseTest do
  @moduledoc """
  Covers the fix for HLS playback never taking a `:playback` hardware lease
  (CodeRabbit finding on PR #751): before this, `FfmpegHlsTranscoder` could
  ask for the hardware encoder without ever going through
  `Mydia.Streaming.HardwareAccel`'s lease accounting, so the concurrency cap
  did not constrain playback at all.

  The lease is claimed once per `HlsSession`, not once per
  `FfmpegHlsTranscoder` process (see `acquire_hwaccel_lease/0`'s comment for
  why: the transcoder is restarted on every seek, and a per-transcoder lease
  would churn HardwareAccel on every one of them). That means the meaningful
  units to test are: the gating decision
  (`maybe_acquire_hwaccel_lease/2`, whether a session bothers leasing at
  all), the "not running" fallback shape (`acquire_hwaccel_lease/0`, which
  `mix test` always exercises since `HardwareAccel` is never started in this
  suite), and the two release sites (`hwaccel_fallback/2` and `terminate/2`).
  Exercising a real lease being GRANTED would need a `HardwareAccel` process
  registered under its literal global name, which risks colliding with every
  other `async: true` test that assumes that name is never registered (see
  `hardware_accel_test.exs`'s own "the supervisor does not start the probe
  under mix test" guard) -- deliberately not attempted here.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.HlsSession

  @reencode_media_file %MediaFile{
    codec: "hevc",
    relative_path: "movie.mkv",
    library_path: %LibraryPath{path: "/tmp"}
  }

  @copy_media_file %MediaFile{
    codec: "h264",
    relative_path: "movie.mkv",
    library_path: %LibraryPath{path: "/tmp"}
  }

  describe "maybe_acquire_hwaccel_lease/2" do
    test "a session that will re-encode attempts a lease" do
      # HardwareAccel is never started under mix test (see
      # hardware_accel_test.exs), so this exercises the refusal branch: a
      # session that WOULD lease still gets software capabilities rather than
      # nil, so build_ffmpeg_args/3 never reaches for hardware it was refused.
      assert {%Capabilities{backend: :none, reason: reason}, nil} =
               HlsSession.maybe_acquire_hwaccel_lease(@reencode_media_file, nil)

      assert reason =~ "no hardware slot free"
    end

    test "a bitrate cap forces a re-encode and therefore a lease attempt" do
      # max_bitrate forces reencodes_video?/2 to true regardless of codec --
      # even an already-compatible h264 source is transcoded to control the
      # output bitrate.
      assert {%Capabilities{backend: :none}, nil} =
               HlsSession.maybe_acquire_hwaccel_lease(@copy_media_file, 2000)
    end

    test "a stream-copy session never attempts a lease" do
      assert {nil, nil} = HlsSession.maybe_acquire_hwaccel_lease(@copy_media_file, nil)
    end

    test "no media file (mode unknown) is treated as re-encoding, matching build_ffmpeg_args/3" do
      assert {%Capabilities{backend: :none}, nil} =
               HlsSession.maybe_acquire_hwaccel_lease(nil, nil)
    end
  end

  describe "acquire_hwaccel_lease/0" do
    test "reports software with no lease when HardwareAccel is not running" do
      assert {%Capabilities{backend: :none, reason: reason}, nil} =
               HlsSession.acquire_hwaccel_lease()

      assert reason =~ "no hardware slot free for playback"
    end
  end

  describe "hwaccel_fallback/2 releases the session's lease" do
    test "clears hwaccel_lease from state so terminate/2 cannot double-release it" do
      state = %HlsSession.State{
        session_id: "s1",
        temp_dir: "/tmp/s1",
        backend: :ffmpeg,
        backend_opts: [start_number: 42, grid_aligned: true],
        window_generation: 3,
        accel: :auto,
        accel_fallbacks: 0,
        # A throwaway ref stands in for a real lease: HardwareAccel is not
        # running under mix test, so HardwareAccel.release/2 is a documented
        # no-op regardless of what this holds. The behaviour under test is
        # that hwaccel_fallback/2 calls it at all and clears the field, not
        # what the (absent) server does with it.
        hwaccel_lease: make_ref()
      }

      {:retry, next} = HlsSession.hwaccel_fallback(state, 42)

      assert next.hwaccel_lease == nil
    end

    test "a session with no lease (stream-copy, or already refused) is unaffected" do
      state = %HlsSession.State{
        session_id: "s1",
        temp_dir: "/tmp/s1",
        backend: :ffmpeg,
        backend_opts: [start_number: 0, grid_aligned: false],
        window_generation: 0,
        accel: :auto,
        accel_fallbacks: 0,
        hwaccel_lease: nil
      }

      {:retry, next} = HlsSession.hwaccel_fallback(state, 0)

      assert next.hwaccel_lease == nil
    end
  end

  describe "terminate/2 releases the session's lease" do
    test "does not crash when a lease is present" do
      tmp_dir =
        Path.join(System.tmp_dir!(), "hls-lease-terminate-#{System.unique_integer([:positive])}")

      File.mkdir_p!(tmp_dir)

      state = %HlsSession.State{
        session_id: "terminate-lease-test",
        temp_dir: tmp_dir,
        backend: :ffmpeg,
        backend_pid: nil,
        db_job_id: nil,
        hwaccel_lease: make_ref()
      }

      assert :ok = HlsSession.terminate(:normal, state)
      refute File.exists?(tmp_dir)
    end
  end
end
