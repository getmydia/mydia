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
  end

  describe "a waiter parked across a relocation" do
    test "is answered once the relocated encoder reports the segment ready" do
      state = base_state()
      {:ok, pid} = Harness.start_link(state)

      task = Task.async(fn -> HlsSession.request_segment(pid, 100) end)
      # Gives the harness time to process the call above (relocate + park)
      # before the notification below arrives. Without this, the cast could
      # land first and be dropped by the generation guard, since the window
      # would not have relocated to generation 1 yet — the same convention
      # hls_session_ready_test.exs uses in this directory for the same
      # cross-process synchronization problem.
      Process.sleep(50)

      HlsSession.notify_segments(pid, 1, [100])

      assert {:ok, path} = Task.await(task)
      assert path == Path.join(state.temp_dir, "segment_00100.ts")
    end

    test "ignores a stale-generation notification instead of resolving early" do
      {:ok, pid} = Harness.start_link(base_state())

      task = Task.async(fn -> HlsSession.request_segment(pid, 100) end)
      Process.sleep(50)

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
      Process.sleep(50)

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
end
