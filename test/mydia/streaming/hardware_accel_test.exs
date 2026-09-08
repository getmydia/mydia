defmodule Mydia.Streaming.HardwareAccelTest do
  use ExUnit.Case, async: false

  alias Mydia.Streaming.HardwareAccel
  alias Mydia.Streaming.HardwareAccel.Capabilities

  @vaapi %Capabilities{
    backend: :vaapi,
    device: "/dev/dri/renderD128",
    encoders: [:h264],
    decode_profiles: [:hevc, :av1]
  }

  defp start_with(caps, opts \\ []) do
    name = :"hwaccel_#{System.unique_integer([:positive])}"
    opts = Keyword.merge([name: name, probe: fn _ -> caps end, cap: 3], opts)
    start_supervised!({HardwareAccel, opts})
    name
  end

  # A dead lease holder's :DOWN reaches HardwareAccel independently of any
  # :DOWN the test process set up for its own synchronization, so there is no
  # ordering guarantee between "test observed the holder die" and "server
  # finished reclaiming the slot". Poll briefly instead of asserting once.
  # 400 attempts at 5ms is a 2s ceiling, matching the explicit budgets on the
  # assert_receive calls beside it. The holder's :DOWN and HardwareAccel's
  # reclamation of its slot are independently ordered, so a shorter wait can
  # still lose the race under the concurrent PostgreSQL CI job.
  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> true
      attempts > 0 -> Process.sleep(5) && eventually(fun, attempts - 1)
      true -> false
    end
  end

  describe "capabilities/0 without a running process" do
    test "reports software rather than crashing" do
      # Every existing streaming test runs with no probe process. They must keep
      # asserting software arguments, so absence is a supported state.
      caps = HardwareAccel.capabilities()

      assert caps.backend == :none
      assert caps.reason =~ "not running"
    end
  end

  describe "capabilities/1" do
    test "returns what the probe found" do
      name = start_with(@vaapi)

      assert HardwareAccel.capabilities(name).backend == :vaapi
    end
  end

  describe "surviving the process exiting mid-call" do
    # GenServer.whereis/1 resolves a pid before the call is made, but the
    # process can die in the gap -- realistically the probe crashing and the
    # supervisor restarting it. :sys.suspend/1 makes that race deterministic:
    # the suspended process still queues the call message but never answers
    # it, so killing it while a caller is blocked on GenServer.call/3
    # reliably reproduces "exited while a call was in flight" instead of
    # "was already gone before the call was made" (which capabilities/0's
    # own "without a running process" test above already covers).
    test "capabilities/1 reports software instead of crashing the caller" do
      name = start_with(@vaapi)
      pid = GenServer.whereis(name)

      :sys.suspend(pid)
      task = Task.async(fn -> HardwareAccel.capabilities(name) end)
      Process.sleep(50)
      Process.exit(pid, :kill)

      assert %Capabilities{backend: :none, reason: reason} = Task.await(task)
      assert reason =~ "not running"
    end

    test "lease/2 is refused instead of crashing the caller" do
      name = start_with(@vaapi)
      pid = GenServer.whereis(name)

      :sys.suspend(pid)
      task = Task.async(fn -> HardwareAccel.lease(name, :playback) end)
      Process.sleep(50)
      Process.exit(pid, :kill)

      assert :refused = Task.await(task)
    end

    test "report_failure/3 reports ok instead of crashing the caller" do
      name = start_with(@vaapi)
      pid = GenServer.whereis(name)

      :sys.suspend(pid)
      task = Task.async(fn -> HardwareAccel.report_failure(name, :vaapi, "hevc") end)
      Process.sleep(50)
      Process.exit(pid, :kill)

      assert :ok = Task.await(task)
    end
  end

  describe "leases" do
    test "playback takes slots up to the cap" do
      name = start_with(@vaapi, cap: 2)

      assert {:ok, _} = HardwareAccel.lease(name, :playback)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
      assert :refused = HardwareAccel.lease(name, :playback)
    end

    test "background is refused one slot early so playback keeps headroom" do
      name = start_with(@vaapi, cap: 2)

      assert {:ok, _} = HardwareAccel.lease(name, :background)
      assert :refused = HardwareAccel.lease(name, :background)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "a cap of one refuses background entirely" do
      name = start_with(@vaapi, cap: 1)

      assert :refused = HardwareAccel.lease(name, :background)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "releasing frees the slot" do
      name = start_with(@vaapi, cap: 1)

      {:ok, ref} = HardwareAccel.lease(name, :playback)
      assert :refused = HardwareAccel.lease(name, :playback)

      :ok = HardwareAccel.release(name, ref)
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
    end

    test "software capabilities refuse every lease" do
      name = start_with(Capabilities.software("no device"))

      assert :refused = HardwareAccel.lease(name, :playback)
    end

    test "reclaims a lease when its holder dies without releasing it" do
      # The realistic failure mode this feature will meet: an ffmpeg-wrapping
      # session gets OOM-killed or times out and never calls release/2. The
      # slot must come back on its own rather than leaking until HardwareAccel
      # itself restarts.
      name = start_with(@vaapi, cap: 1)
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, ref} = HardwareAccel.lease(name, :playback)
          send(test_pid, {:leased, ref})

          receive do
            :die -> :ok
          end
        end)

      # Explicit budget rather than ExUnit's 100ms default: the PostgreSQL CI
      # job runs the suite concurrently (max_cases: System.schedulers_online()
      # in test_helper.exs, against 1 for SQLite), where a cross-process
      # handoff can exceed 100ms without anything being wrong.
      assert_receive {:leased, _ref}, 2_000
      assert :refused = HardwareAccel.lease(name, :playback)

      holder_monitor = Process.monitor(holder)
      send(holder, :die)
      assert_receive {:DOWN, ^holder_monitor, :process, ^holder, :normal}, 2_000

      assert eventually(fn -> match?({:ok, _}, HardwareAccel.lease(name, :playback)) end)
    end

    test "a normal release demonitors, so a late DOWN cannot double-free the slot" do
      name = start_with(@vaapi, cap: 1)

      {:ok, ref} = HardwareAccel.lease(name, :playback)
      :ok = HardwareAccel.release(name, ref)

      # Two independent leases now fit in the cap-1 slot: proof the release
      # path leaves no stray monitor that could otherwise reclaim a slot a
      # second, unrelated holder is legitimately using.
      assert {:ok, _} = HardwareAccel.lease(name, :playback)
      assert :refused = HardwareAccel.lease(name, :playback)
    end
  end

  describe "report_failure/3" do
    test "demotes only the failing codec, keeping the rest on full hardware" do
      # A device whose AV1 decode is advertised but broken must not lose HEVC,
      # which is 94.5% of the library.
      name = start_with(@vaapi, demote_after: 2)

      HardwareAccel.report_failure(name, :vaapi, "av1")
      assert Capabilities.can_decode?(HardwareAccel.capabilities(name), :av1)

      HardwareAccel.report_failure(name, :vaapi, "av1")
      caps = HardwareAccel.capabilities(name)

      refute Capabilities.can_decode?(caps, :av1)
      assert Capabilities.can_decode?(caps, :hevc)
      assert caps.backend == :vaapi
    end

    test "an unknown codec name never demotes anything" do
      name = start_with(@vaapi, demote_after: 1)

      HardwareAccel.report_failure(name, :vaapi, "not_a_codec")

      assert HardwareAccel.capabilities(name).decode_profiles == [:hevc, :av1]
    end
  end

  describe "call timeout hardening" do
    test "lease/2 and report_failure/3 wait out a slow probe instead of racing the default GenServer timeout" do
      name = :"hwaccel_#{System.unique_integer([:positive])}"

      start_supervised!({HardwareAccel,
       name: name,
       cap: 3,
       probe: fn _ ->
         # Longer than the default GenServer.call/3 timeout (5s). Before
         # this fix, lease/2 and report_failure/3 used that default while
         # queued behind this same handle_continue, so both would raise
         # exit(:timeout) here instead of simply waiting the probe out the
         # way capabilities/1 already does.
         Process.sleep(5_300)
         @vaapi
       end})

      lease_task = Task.async(fn -> HardwareAccel.lease(name, :playback) end)
      failure_task = Task.async(fn -> HardwareAccel.report_failure(name, :vaapi, "hevc") end)

      assert {:ok, _ref} = Task.await(lease_task, 10_000)
      assert :ok = Task.await(failure_task, 10_000)
    end
  end

  describe "the config wiring" do
    test "passes the configured hwaccel and device through to the probe" do
      # Every other test here injects a probe stub that ignores its argument,
      # so nothing exercises handle_continue's read of Mydia.Config.get().
      # Pin it: a future rename of the streaming.hwaccel/hwaccel_device schema
      # fields would otherwise make handle_continue's Map.get/3 calls fall
      # back to :auto/nil silently, disabling the feature while the rest of
      # the suite stayed green.
      test_pid = self()
      name = :"hwaccel_#{System.unique_integer([:positive])}"

      start_supervised!(
        {HardwareAccel,
         name: name,
         cap: 3,
         probe: fn opts ->
           send(test_pid, {:probe_opts, opts})
           Capabilities.software("stub")
         end}
      )

      assert_receive {:probe_opts, opts}, 2_000

      streaming = Mydia.Config.get().streaming
      assert Keyword.fetch!(opts, :hwaccel) == streaming.hwaccel
      assert Keyword.fetch!(opts, :device) == streaming.hwaccel_device
    end
  end

  test "the supervisor does not start the probe under mix test" do
    # If this fails, every streaming test that asserts software arguments is
    # now at the mercy of whether the developer's machine has a GPU.
    assert GenServer.whereis(Mydia.Streaming.HardwareAccel) == nil
  end
end
