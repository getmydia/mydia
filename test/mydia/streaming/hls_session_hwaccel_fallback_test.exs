defmodule Mydia.Streaming.HlsSessionHwaccelFallbackTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.HardwareAccel.Capabilities
  alias Mydia.Streaming.{HlsSession, SegmentPlan, TranscodeWindow}

  describe "hwaccel_fallback/2" do
    test "flips the session to software and keeps the segment index" do
      state = %HlsSession.State{
        session_id: "s1",
        temp_dir: "/tmp/s1",
        backend: :ffmpeg,
        backend_opts: [start_number: 42, grid_aligned: true],
        window_generation: 3,
        accel: :auto,
        accel_fallbacks: 0
      }

      {:retry, next} = HlsSession.hwaccel_fallback(state, 42)

      assert next.accel == :none
      assert next.accel_fallbacks == 1
      assert Keyword.get(next.backend_opts, :start_number) == 42
      # Every other backend option survives: the fallback re-encodes the same
      # window, it does not reconfigure the session.
      assert Keyword.get(next.backend_opts, :grid_aligned) == true

      caps = Keyword.fetch!(next.backend_opts, :capabilities)
      assert caps.backend == :none
      assert caps.reason =~ "fell back"
    end

    test "only one fallback per session" do
      # A persistently broken device must not spin the session in a restart
      # loop; the second failure is a real failure.
      state = %HlsSession.State{
        session_id: "s1",
        temp_dir: "/tmp/s1",
        backend: :ffmpeg,
        backend_opts: [],
        accel: :none,
        accel_fallbacks: 1
      }

      assert :stop = HlsSession.hwaccel_fallback(state, 42)
    end
  end

  # ---------------------------------------------------------------------
  # The trap this task calls out explicitly: start_backend/6 rebuilds its
  # transcoder opts from an explicit whitelist, so a :capabilities key placed
  # in backend_opts is silently dropped unless start_backend/6 itself forwards
  # it. hwaccel_fallback/2 returning a State with :capabilities in
  # backend_opts (asserted above) is necessary but not sufficient — this
  # drives the real handle_info :DOWN clause through relocate/2 and
  # start_backend/6 and inspects what actually reached the (fake) transcoder,
  # which is the only way to catch that key being dropped.
  # ---------------------------------------------------------------------

  defmodule Harness do
    @moduledoc false
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_info(msg, state), do: HlsSession.handle_info(msg, state)
  end

  defmodule CapturingBackend do
    @moduledoc """
    Stands in for FfmpegHlsTranscoder. Stores the full opts it was started
    with (the same opts start_backend/6 built from backend_opts) as its own
    state, so a test can read back exactly what reached the transcoder.
    """
    use GenServer

    def start_transcoding(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  describe "restarting the backend after a hardware failure (:DOWN handling)" do
    test "the software capabilities set by hwaccel_fallback/2 reach the restarted backend" do
      {:ok, plan} = SegmentPlan.build(600.0, 4)

      {:ok, dead_backend_pid} = CapturingBackend.start_transcoding([])

      state = %HlsSession.State{
        session_id: "hwaccel-fallback-restart-test",
        media_file: %MediaFile{
          codec: "h264",
          relative_path: "movie.mkv",
          library_path: %LibraryPath{path: "/tmp"}
        },
        media_file_id: 1,
        user_id: 1,
        mode: :transcode,
        start_position: 0,
        backend: :ffmpeg,
        backend_pid: dead_backend_pid,
        temp_dir: "/tmp/mydia-hls-hwaccel-fallback-test",
        db_job_id: nil,
        segment_plan: plan,
        backend_opts: [
          transcoder_module: CapturingBackend,
          start_number: 7,
          grid_aligned: true
        ],
        playlist_mode: :full,
        window: TranscodeWindow.new(7),
        window_generation: 0,
        accel: :auto,
        accel_fallbacks: 0
      }

      {:ok, harness_pid} = Harness.start_link(state)

      send(
        harness_pid,
        {:DOWN, make_ref(), :process, dead_backend_pid, {:hwaccel_failed, "vaapi init failed"}}
      )

      # :sys.get_state/1 is a synchronous system message, so it is only
      # answered after the :DOWN message above has been handled.
      new_state = :sys.get_state(harness_pid)

      assert new_state.accel == :none
      assert new_state.accel_fallbacks == 1
      refute new_state.backend_pid == dead_backend_pid

      transcoder_opts = :sys.get_state(new_state.backend_pid)

      assert Keyword.has_key?(transcoder_opts, :capabilities),
             ":capabilities from backend_opts never reached start_backend/6's transcoder opts"

      caps = Keyword.fetch!(transcoder_opts, :capabilities)
      assert caps.backend == :none
      assert caps.reason =~ "fell back"
    end
  end
end
