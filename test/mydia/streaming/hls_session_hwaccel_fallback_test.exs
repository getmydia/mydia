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
  # Two things a test that only exercises hwaccel_fallback/2 in isolation
  # cannot distinguish a live mechanism from a dead one:
  #
  #   1. HlsSession only ever Process.link/1s to its backend_pid, never
  #      Process.monitor/1s it, and never traps exits (confirmed by reading
  #      start_registered_session/7 and relocate/2). A link to a
  #      non-trapping process only kills it for a non-normal exit reason,
  #      which is exactly why FfmpegHlsTranscoder now stops with :normal
  #      (plus an on_hwaccel_failed callback) instead of
  #      {:hwaccel_failed, output} for this specific failure: the old
  #      {:hwaccel_failed, output} stop reason would have killed the
  #      linked session before any handle_info/handle_cast clause could
  #      ever run.
  #   2. start_backend/6 rebuilds its transcoder opts from an explicit
  #      whitelist, so a :capabilities key placed in backend_opts is
  #      silently dropped unless start_backend/6 itself forwards it.
  #
  # This drives the real link + notification + relocate/2 + start_backend/6
  # chain: a real backend process, really linked to the session the way
  # start_registered_session/7 links it, really exiting with :normal, and
  # asserts the session is still alive and has relocated onto a new backend
  # carrying :capabilities -- the only way to catch either class of bug.
  # ---------------------------------------------------------------------

  defmodule Harness do
    @moduledoc """
    Stands in for the live HlsSession GenServer. set_backend/2 links to a
    backend pid from *within* the harness process (Process.link/1 always
    acts on the calling process), exactly mirroring the
    `Process.link(backend_pid)` call in start_registered_session/7 -- the
    only way to exercise the real link semantics this test is about.
    """
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    def set_backend(harness_pid, backend_pid) do
      GenServer.call(harness_pid, {:set_backend, backend_pid})
    end

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call({:set_backend, pid}, _from, state) do
      Process.link(pid)
      {:reply, :ok, %{state | backend_pid: pid}}
    end

    @impl true
    def handle_cast(msg, state), do: HlsSession.handle_cast(msg, state)
  end

  defmodule CapturingBackend do
    @moduledoc """
    Stands in for FfmpegHlsTranscoder in its ordinary running state. Stores
    the full opts it was started with (the same opts start_backend/6 built
    from backend_opts) as its own state, so a test can read back exactly
    what reached the transcoder.
    """
    use GenServer

    def start_transcoding(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule FailingHwaccelBackend do
    @moduledoc """
    Stands in for FfmpegHlsTranscoder's hardware-failure exit path: on
    trigger_failure/2, invokes the on_hwaccel_failed callback it was
    started with, then stops with reason :normal -- precisely what the real
    exit-status handler now does. trigger_failure/2 is a synchronous call
    (the process replies before it stops) so a test can be certain the
    on_hwaccel_failed callback -- and whatever cast it sends -- has already
    run by the time the call returns.
    """
    use GenServer

    def start_transcoding(opts), do: GenServer.start_link(__MODULE__, opts)

    def trigger_failure(pid, output), do: GenServer.call(pid, {:fail, output})

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_call({:fail, output}, _from, opts) do
      if cb = Keyword.get(opts, :on_hwaccel_failed), do: cb.(output)
      {:stop, :normal, :ok, opts}
    end
  end

  describe "restarting the backend after a hardware failure" do
    test "the session survives the backend's :normal exit, relocates, and forwards :capabilities" do
      {:ok, plan} = SegmentPlan.build(600.0, 4)

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
        backend_pid: nil,
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

      # Wired exactly the way start_backend/6 wires on_hwaccel_failed: the
      # session's pid and this backend's generation (0, matching state above).
      {:ok, dying_backend_pid} =
        FailingHwaccelBackend.start_transcoding(
          on_hwaccel_failed: fn output ->
            HlsSession.notify_hwaccel_failed(harness_pid, 0, output)
          end
        )

      :ok = Harness.set_backend(harness_pid, dying_backend_pid)

      assert Process.alive?(harness_pid)

      # Synchronous: by the time this returns, the on_hwaccel_failed callback
      # has already run and its cast to harness_pid is already in its mailbox
      # (a local GenServer.cast enqueues before returning). :sys.get_state/1
      # below, issued afterward from this same process, is therefore only
      # answered once that cast has been handled -- the same guarantee this
      # codebase already relies on elsewhere for cast-then-:sys.get_state
      # synchronization (see hls_session_segments_test.exs).
      :ok = FailingHwaccelBackend.trigger_failure(dying_backend_pid, "vaapi init failed")

      refute Process.alive?(dying_backend_pid)

      # The whole point: a :normal exit over a plain Process.link does not
      # kill the linked, non-trapping session. Before this task's fix (when
      # FfmpegHlsTranscoder stopped with {:hwaccel_failed, output} instead),
      # this assertion is exactly what would have failed.
      assert Process.alive?(harness_pid),
             "the session died from the backend's exit instead of surviving it and relocating"

      new_state = :sys.get_state(harness_pid)

      assert new_state.accel == :none
      assert new_state.accel_fallbacks == 1
      refute new_state.backend_pid == dying_backend_pid

      transcoder_opts = :sys.get_state(new_state.backend_pid)

      assert Keyword.has_key?(transcoder_opts, :capabilities),
             ":capabilities from backend_opts never reached start_backend/6's transcoder opts"

      caps = Keyword.fetch!(transcoder_opts, :capabilities)
      assert caps.backend == :none
      assert caps.reason =~ "fell back"
    end
  end
end
