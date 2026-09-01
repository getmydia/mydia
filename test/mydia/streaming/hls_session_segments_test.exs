defmodule Mydia.Streaming.HlsSessionSegmentsTest do
  @moduledoc """
  Drives HlsSession's segment machinery with a stub backend.

  A real FFmpeg cannot be used here: the point of these tests is to control
  exactly when a segment becomes available and to relocate the encoder on
  demand, neither of which a real encoder lets a test do deterministically.
  """
  use ExUnit.Case, async: true

  alias Mydia.Library.MediaFile
  alias Mydia.Settings.LibraryPath
  alias Mydia.Streaming.{HlsSession, SegmentPlan, TranscodeWindow}

  describe "TranscodeWindow integration inside a session's decision path" do
    setup do
      {:ok, plan} = SegmentPlan.build(600.0, 4)
      %{plan: plan, window: TranscodeWindow.new(0) |> TranscodeWindow.mark_ready([0, 1, 2])}
    end

    test "a request for a ready segment resolves to its on-disk path", %{
      plan: plan,
      window: window
    } do
      assert TranscodeWindow.decide(window, 1) == :serve
      assert SegmentPlan.segment_name(1) == "segment_00001.ts"
      assert SegmentPlan.start_time(plan, 1) == 4.0
    end

    test "a far forward request relocates to the requested segment", %{window: window} do
      assert TranscodeWindow.decide(window, 100) == {:relocate, 100}
    end

    test "a relocation target maps to the right FFmpeg offset", %{plan: plan} do
      assert SegmentPlan.start_time(plan, 100) == 400.0
    end
  end

  describe "coalescing parallel requests" do
    test "three requests for unseen segments in one window relocate once" do
      # A player asks for the segment it seeked to and the two after it. Only
      # the first may move the encoder; the others must land inside the window
      # the first created, or they would thrash FFmpeg on every seek.
      window = TranscodeWindow.new(0) |> TranscodeWindow.mark_ready([0, 1, 2])

      assert {:relocate, 100} = TranscodeWindow.decide(window, 100)

      relocated = TranscodeWindow.relocate(window, 100)

      assert TranscodeWindow.decide(relocated, 101) == :wait
      assert TranscodeWindow.decide(relocated, 102) == :wait
    end
  end

  describe "grid_aligned?/3" do
    # Nothing previously asserted what HlsSession actually passes for
    # FFmpeg's grid_aligned opt. Covering it directly here, rather than only
    # through hand-built %HlsSession.State{} fixtures elsewhere in this file
    # that could quietly encode the same mistake this guards against.
    test "is false for a :window session even when the video would be re-encoded" do
      media_file = %MediaFile{codec: "hevc"}
      refute HlsSession.grid_aligned?(:window, media_file, nil)
    end

    test "is true for a :full session whose video is re-encoded" do
      media_file = %MediaFile{codec: "hevc"}
      assert HlsSession.grid_aligned?(:full, media_file, nil)
    end

    test "is false for a :full session whose video is copied" do
      media_file = %MediaFile{codec: "h264"}
      refute HlsSession.grid_aligned?(:full, media_file, nil)
    end

    test "is true for a :full session forced to transcode by a bitrate cap" do
      media_file = %MediaFile{codec: "h264"}
      assert HlsSession.grid_aligned?(:full, media_file, 4000)
    end
  end

  # ---------------------------------------------------------------------
  # Everything below drives the real GenServer. The two describe blocks
  # above pin how SegmentPlan and TranscodeWindow compose, which is
  # necessary but not sufficient: it says nothing about whether HlsSession
  # actually wires request_segment/2, relocate/2, notify_segments/3 and the
  # waiter timeout together correctly, which is what the approved spec for
  # this task requires a test of.
  #
  # Seam: a bare harness GenServer runs HlsSession's real handle_call/3,
  # handle_cast/2 and handle_info/2 against a hand-built %HlsSession.State{}
  # — the same "skip init/1" convention hls_session_info_test.exs already
  # uses in this directory for a single call, extended here to a live
  # process since these assertions span several messages (a relocation, a
  # segments-ready notification, a timeout). The backend itself is swapped
  # for FakeBackend through the state's own backend_opts, using the
  # :transcoder_module override start_backend/6 already reads there — no
  # global Application config is mutated, so this file stays async: true
  # (see Mydia.Downloads.JobManager for the alternative, global-config
  # version of this seam, which is why its test is async: false).
  # ---------------------------------------------------------------------

  defmodule Harness do
    @moduledoc false
    use GenServer

    def start_link(state), do: GenServer.start_link(__MODULE__, state)

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(msg, from, state), do: HlsSession.handle_call(msg, from, state)

    @impl true
    def handle_cast(msg, state), do: HlsSession.handle_cast(msg, state)

    @impl true
    def handle_info(msg, state), do: HlsSession.handle_info(msg, state)
  end

  defmodule FakeBackend do
    @moduledoc """
    Stands in for FfmpegHlsTranscoder. `start_transcoding/1` starts a bare
    GenServer that stays alive until stopped and produces nothing on its own.
    Tests call `HlsSession.notify_segments/3` directly, the same call a real
    transcoder's `on_segments` callback would make once a segment lands.
    """
    use GenServer

    def start_transcoding(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}
  end

  defmodule SlowStopBackend do
    @moduledoc """
    Same as FakeBackend, but its terminate/2 sleeps before returning,
    standing in for FfmpegHlsTranscoder.terminate/2's real, unconditional
    100ms sleep before its SIGKILL escalation check. Used to prove
    relocate/2 does not wait on that sleep inline.
    """
    use GenServer

    def start_transcoding(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def terminate(_reason, _state) do
      # 500ms, not the real backend's 100ms: what matters here is the ratio
      # between this sleep and the assertion threshold below, not fidelity
      # to FfmpegHlsTranscoder's actual timing. At a 2x margin (100ms sleep,
      # 50_000us threshold) this test flaked under full-suite CPU load,
      # observed at 55_043us. Widening the sleep instead of the threshold
      # keeps a genuine regression (a synchronous stop) failing by 5x rather
      # than shrinking the room between "passes" and "regression detected".
      Process.sleep(500)
      :ok
    end
  end

  defp base_state(overrides \\ []) do
    {:ok, plan} = SegmentPlan.build(600.0, 4)

    struct!(
      %HlsSession.State{
        session_id: "segments-test-session",
        media_file: %MediaFile{
          relative_path: "movie.mkv",
          library_path: %LibraryPath{path: "/tmp"}
        },
        media_file_id: 1,
        user_id: 1,
        mode: :transcode,
        start_position: 0,
        backend: :ffmpeg,
        backend_pid: nil,
        temp_dir: "/tmp/mydia-hls-segments-test",
        last_activity: DateTime.utc_now(),
        db_job_id: nil,
        segment_plan: plan,
        backend_opts: [transcoder_module: FakeBackend],
        playlist_mode: :full,
        window: TranscodeWindow.new(0) |> TranscodeWindow.mark_ready([0, 1, 2]),
        segment_waiters: %{},
        window_generation: 0
      },
      overrides
    )
  end

  defp fake_from, do: {self(), make_ref()}

  # A Process.sleep here would be a race, not a synchronization: under load
  # the spawned Task's request_segment/2 call may not have reached the
  # harness's mailbox within an arbitrary fixed delay, and if a notification
  # sent right after the sleep arrives before the waiter parks, it is
  # dropped and nothing ever resolves the call. Polling :sys.get_state/1
  # instead is deterministic: it is itself a synchronous call into the same
  # GenServer, so it serialises behind whatever is already queued ahead of
  # it, including a request_segment call already in flight.
  defp await_waiter(pid, index, attempts \\ 200) do
    %{segment_waiters: waiters} = :sys.get_state(pid)

    cond do
      Map.has_key?(waiters, index) ->
        :ok

      attempts == 0 ->
        flunk("waiter for segment #{index} never parked")

      true ->
        Process.sleep(5)
        await_waiter(pid, index, attempts - 1)
    end
  end

  describe "relocation, driven sequentially through handle_call/3" do
    # A GenServer's mailbox is strictly single-threaded: three concurrent
    # request_segment calls from three separate player requests can only ever
    # be processed by HlsSession one at a time, in arrival order. Feeding
    # handle_call/3 the same way — one call at a time, threading the previous
    # call's returned state into the next — is a faithful, deterministic
    # stand-in for that serialization: no live process or Task.async (and no
    # sleep-based synchronization) is needed to prove the encoder is
    # relocated once rather than thrashed on every request.
    test "three requests for unseen segments in the same window relocate exactly once" do
      state = base_state()

      {:noreply, state} = HlsSession.handle_call({:request_segment, 100}, fake_from(), state)
      {:noreply, state} = HlsSession.handle_call({:request_segment, 101}, fake_from(), state)
      {:noreply, state} = HlsSession.handle_call({:request_segment, 102}, fake_from(), state)

      assert state.window_generation == 1
      assert Enum.sort(Map.keys(state.segment_waiters)) == [100, 101, 102]
    end

    test "relocation preserves the segments an earlier window already wrote" do
      state = base_state()

      {:noreply, state} = HlsSession.handle_call({:request_segment, 100}, fake_from(), state)
      assert state.window_generation == 1

      # Segment 1 was marked ready by the window base_state/1 starts with,
      # before the relocation above ever ran. relocate/2 must not have
      # touched TranscodeWindow's `available` set, so it still serves.
      assert {:reply, {:ok, path}, _state} =
               HlsSession.handle_call({:request_segment, 1}, fake_from(), state)

      assert path == Path.join(state.temp_dir, "segment_00001.ts")
    end

    test "does not block on the outgoing backend's stop" do
      {:ok, outgoing_pid} = SlowStopBackend.start_transcoding([])

      state =
        base_state(
          backend_pid: outgoing_pid,
          backend_opts: [transcoder_module: FakeBackend]
        )

      # SlowStopBackend's terminate/2 sleeps 500ms, standing in for
      # FfmpegHlsTranscoder.terminate/2's real sleep before its SIGKILL
      # escalation check. If relocate/2 called stop_backend/2 inline instead
      # of through Task.start/1, this handle_call would take at least that
      # long to return, freezing the session's whole mailbox (every other
      # segment request, get_info, heartbeat) for the duration.
      {elapsed_us, {:noreply, _state}} =
        :timer.tc(fn -> HlsSession.handle_call({:request_segment, 100}, fake_from(), state) end)

      assert elapsed_us < 100_000
    end
  end

  describe "an out-of-range segment index" do
    # base_state/1 builds a 600.0s / 4s plan, so valid indices run 0..149.
    # request_segment must reject anything outside that before it ever
    # reaches TranscodeWindow.decide/2: an out-of-range index has no
    # corresponding segment, and decide/2 would otherwise relocate the
    # running encoder to seek FFmpeg past end of file, stopping the
    # playback the viewer is actually watching.
    test "is rejected without relocating or parking a waiter" do
      {:ok, backend_pid} = FakeBackend.start_transcoding([])
      state = base_state(backend_pid: backend_pid)

      assert {:reply, {:error, :out_of_range}, new_state} =
               HlsSession.handle_call({:request_segment, 99_999}, fake_from(), state)

      # The backend was not touched: no relocation, no new generation, no
      # waiter parked on an index that will never arrive.
      assert new_state.backend_pid == backend_pid
      assert new_state.window_generation == state.window_generation
      assert new_state.segment_waiters == %{}
    end

    test "also rejects a negative index" do
      state = base_state()

      assert {:reply, {:error, :out_of_range}, _state} =
               HlsSession.handle_call({:request_segment, -1}, fake_from(), state)
    end

    test "the boundary index (count) is out of range, but count - 1 is not" do
      state = base_state()
      last_valid = state.segment_plan.count - 1

      assert {:reply, {:error, :out_of_range}, _state} =
               HlsSession.handle_call(
                 {:request_segment, state.segment_plan.count},
                 fake_from(),
                 state
               )

      # last_valid (149) is not in `available` (only 0, 1, 2 are marked
      # ready in base_state/1) and is past last_ready_index + wait_ahead, so
      # it relocates rather than erroring -- proving the boundary itself,
      # not every high index, is what gets rejected.
      assert {:noreply, _state} =
               HlsSession.handle_call({:request_segment, last_valid}, fake_from(), state)
    end
  end

  describe "a waiter parked across a relocation" do
    test "is answered once the relocated encoder reports the segment ready" do
      state = base_state()
      {:ok, pid} = Harness.start_link(state)

      task = Task.async(fn -> HlsSession.request_segment(pid, 100) end)
      # Waits for the harness to actually process the call above (relocate +
      # park) before the notification below arrives. Without this, the cast
      # could land first and be dropped by the generation guard, since the
      # window would not have relocated to generation 1 yet.
      await_waiter(pid, 100)

      HlsSession.notify_segments(pid, 1, [100])

      assert {:ok, path} = Task.await(task)
      assert path == Path.join(state.temp_dir, "segment_00100.ts")
    end

    test "ignores a stale-generation notification instead of resolving early" do
      {:ok, pid} = Harness.start_link(base_state())

      task = Task.async(fn -> HlsSession.request_segment(pid, 100) end)
      await_waiter(pid, 100)

      # Generation 0 belonged to the encoder relocate/2 just replaced. Its
      # indices must not resolve a waiter parked against generation 1.
      HlsSession.notify_segments(pid, 0, [100])
      refute Task.yield(task, 50)

      HlsSession.notify_segments(pid, 1, [100])
      assert {:ok, _path} = Task.await(task)
    end

    test "times out rather than hanging forever when the segment never arrives" do
      {:ok, pid} = Harness.start_link(base_state())

      task = Task.async(fn -> HlsSession.request_segment(pid, 100) end)
      await_waiter(pid, 100)

      # Fires the same handle_info clause the real Process.send_after timer
      # would, on the test's own schedule instead of waiting out the real
      # (10s) window.
      %{segment_waiters: %{100 => [from]}} = :sys.get_state(pid)
      send(pid, {:waiter_timeout, 100, from})

      assert Task.await(task) == {:error, :timeout}

      # The waiter must be gone, not just answered: a segment that shows up
      # after the timeout has already replied must not try to reply again to
      # a caller that has moved on.
      refute Map.has_key?(:sys.get_state(pid).segment_waiters, 100)
    end
  end

  describe "a :window session's segments_ready notification" do
    # Regression test for a crash that reached master: FfmpegHlsTranscoder's
    # on_segments callback used to be wired unconditionally in start_backend/6,
    # for both :full and :window sessions. A :window session has no
    # TranscodeWindow (its `window` field is nil -- see start_registered_session/7,
    # called from init/1), but
    # TranscodeWindow.mark_ready/2 pattern-matches %TranscodeWindow{} in its
    # head, so the first {:segments_ready, ...} cast a real encoder sent for a
    # windowed session raised FunctionClauseError and took the whole session
    # GenServer down roughly 60ms after start. Every later playlist request
    # then 404'd because the session no longer existed (CI / Player E2E on
    # master, run 33452019208; player/integration_test/p2p_streaming_test.dart
    # failing on "HLS playlist should be ready with segments").
    #
    # The fix has two halves: start_backend/6 no longer wires on_segments at
    # all for a :window session (nothing to notify), and handle_cast/2 gained
    # a `%{window: nil}` clause as defence in depth so this cast is inert even
    # if some future caller re-introduces it. This test exercises the
    # handle_cast/2 guard directly, which is what actually protects the
    # session if that ever happens.
    test "does not crash the session" do
      state =
        base_state(
          playlist_mode: :window,
          segment_plan: nil,
          window: nil
        )

      # Trapping exits keeps a crash from taking the test process down with the
      # link, so the failure surfaces as :sys.get_state/1 exiting with :noproc
      # rather than as an unrelated-looking test process death.
      Process.flag(:trap_exit, true)
      {:ok, pid} = Harness.start_link(state)

      # window_generation defaults to 0 in base_state/1; matching it here
      # means this notification is not discarded by the stale-generation
      # guard clause and actually reaches the window: nil clause under test.
      HlsSession.notify_segments(pid, 0, [0])

      # :sys.get_state/1 is a synchronous system message. Sent from the same
      # process right after the cast, it is guaranteed to be handled after it,
      # so this synchronises on the cast actually being processed instead of
      # sleeping and hoping. If the cast crashed the session, the call exits
      # with :noproc and the test fails.
      assert %{window: nil} = :sys.get_state(pid)
    end
  end
end
