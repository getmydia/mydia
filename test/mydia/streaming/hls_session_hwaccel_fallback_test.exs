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
  # Three things a test that only exercises hwaccel_fallback/2 in isolation
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
  #   3. relocate/2 assumes :full-mode state (SegmentPlan, TranscodeWindow)
  #      and is only ever reachable, outside this task, through
  #      {:request_segment, index}, which a :window session's handle_call
  #      answers with {:error, :window_mode} before relocate/2 could run.
  #      handle_cast({:hwaccel_failed, ...}) is a second path into it, and a
  #      :window session (segment_plan: nil, window: nil, and the DEFAULT
  #      playlist mode -- see @default_playlist_mode in
  #      hls_session_supervisor.ex) must not be routed through it, or
  #      SegmentPlan.start_time(nil, _) crashes the session instead of
  #      falling back.
  #
  # run_hwaccel_failure_scenario/1 below drives the real link + notification
  # + start_backend/6 chain -- a real backend process, really linked to the
  # session the way start_registered_session/7 links it, really exiting with
  # :normal -- for both playlist_mode values through one shared body, so
  # :full and :window cannot silently drift apart the way they did to
  # introduce the :window crash this describe block was rewritten to catch.
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

  defmodule FailingHwaccelBackend do
    @moduledoc """
    Stands in for FfmpegHlsTranscoder, both as the initially-running backend
    and as the backend start_backend/6 restarts after a fallback (via
    `transcoder_module: FailingHwaccelBackend` in backend_opts) -- the same
    module plays both roles because a real transcoder does too.

    Its own GenServer state *is* the opts it was started with, so a test can
    read back exactly what start_backend/6 built (the :capabilities check).
    trigger_failure/2 invokes the on_hwaccel_failed callback it was started
    with, then stops with reason :normal -- precisely what the real
    exit-status handler now does -- via a synchronous call (the process
    replies before it stops) so a test can be certain the callback, and
    whatever cast it sends, has already run by the time the call returns.
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

  # Builds the state a real session would have right before a hardware
  # failure, for each playlist_mode. segment_plan/window exist only in :full
  # mode, matching start_registered_session/7 exactly (a :window session
  # never gets a SegmentPlan or a TranscodeWindow).
  defp build_state(:full) do
    {:ok, plan} = SegmentPlan.build(600.0, 4)

    %HlsSession.State{
      session_id: "hwaccel-fallback-full-test",
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
      temp_dir: "/tmp/mydia-hls-hwaccel-fallback-full-test",
      db_job_id: nil,
      segment_plan: plan,
      backend_opts: [
        transcoder_module: FailingHwaccelBackend,
        start_number: 7,
        grid_aligned: true
      ],
      playlist_mode: :full,
      window: TranscodeWindow.new(7),
      window_generation: 0,
      accel: :auto,
      accel_fallbacks: 0
    }
  end

  defp build_state(:window) do
    %HlsSession.State{
      session_id: "hwaccel-fallback-window-test",
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
      temp_dir: "/tmp/mydia-hls-hwaccel-fallback-window-test",
      db_job_id: nil,
      segment_plan: nil,
      backend_opts: [
        transcoder_module: FailingHwaccelBackend,
        start_number: 0,
        grid_aligned: false
      ],
      playlist_mode: :window,
      window: nil,
      window_generation: 0,
      accel: :auto,
      accel_fallbacks: 0
    }
  end

  # Starts a harness in `playlist_mode`, links it to a real FailingHwaccelBackend
  # exactly the way start_registered_session/7 would, triggers a real
  # hardware-init failure, and asserts the session survives, restarts, and
  # forwards :capabilities to the new backend. Returns the harness pid and
  # the new backend pid so a caller can drive a second failure for the
  # one-fallback-per-session test below.
  defp run_hwaccel_failure_scenario(playlist_mode) do
    state = build_state(playlist_mode)
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
    # kill the linked, non-trapping session, AND (for :window) the fallback
    # does not route through relocate/2, which would crash on
    # SegmentPlan.start_time(nil, _). Before the respective fixes, this
    # assertion is exactly what would have failed.
    assert Process.alive?(harness_pid),
           "the #{playlist_mode} session died from the backend's exit instead of " <>
             "surviving it and restarting"

    new_state = :sys.get_state(harness_pid)

    assert new_state.accel == :none
    assert new_state.accel_fallbacks == 1
    assert new_state.window_generation == 1
    refute new_state.backend_pid == dying_backend_pid

    transcoder_opts = :sys.get_state(new_state.backend_pid)

    assert Keyword.has_key?(transcoder_opts, :capabilities),
           ":capabilities from backend_opts never reached start_backend/6's transcoder opts"

    caps = Keyword.fetch!(transcoder_opts, :capabilities)
    assert caps.backend == :none
    assert caps.reason =~ "fell back"

    %{harness_pid: harness_pid, new_backend_pid: new_state.backend_pid}
  end

  describe "restarting the backend after a hardware failure" do
    test "a :full session survives the backend's :normal exit, relocates, and forwards :capabilities" do
      run_hwaccel_failure_scenario(:full)
    end

    test "a :window session survives the backend's :normal exit, restarts, and forwards :capabilities" do
      # The regression this test exists for: :window is @default_playlist_mode
      # (hls_session_supervisor.ex), so this is the common path, not an edge
      # case -- a hardware-init failure on it must not crash the session.
      run_hwaccel_failure_scenario(:window)
    end

    for playlist_mode <- [:full, :window] do
      test "only one fallback per session, in #{playlist_mode} mode" do
        %{harness_pid: harness_pid, new_backend_pid: new_backend_pid} =
          run_hwaccel_failure_scenario(unquote(playlist_mode))

        # Harness.start_link/1 links this test process to the harness (every
        # GenServer.start_link/2 call links to its caller), same as
        # start_registered_session/7 links a real session's owning process.
        # This second failure is expected to stop the harness for real (a
        # non-:normal reason), which would otherwise crash this test process
        # right along with it -- see the identical trap_exit comment in
        # hls_session_segments_test.exs. Process.monitor/1 below is
        # unaffected either way; it is what actually observes the stop.
        Process.flag(:trap_exit, true)
        ref = Process.monitor(harness_pid)

        # The restarted backend is itself a FailingHwaccelBackend, so it can
        # report a second hardware failure exactly like the first one did.
        # accel_fallbacks is now 1, so hwaccel_fallback/2 must answer :stop
        # this time: a persistently broken device must not spin the session
        # in a restart loop.
        :ok = FailingHwaccelBackend.trigger_failure(new_backend_pid, "vaapi init failed again")

        assert_receive {:DOWN, ^ref, :process, ^harness_pid,
                        {:backend_terminated, {:hwaccel_failed, "vaapi init failed again"}}}
      end
    end
  end
end
