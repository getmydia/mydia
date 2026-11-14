defmodule Mydia.Downloads.BuiltIn.SpaceGuardTest.StubAdapter do
  @moduledoc false
  # A download client whose torrents live in an Agent the test owns. Pause and
  # resume flip the torrent's state and report the call to the test process.

  alias Mydia.Downloads.Structs.DownloadStatus

  def list_torrents(%{torrents: agent}, _opts) do
    case Agent.get(agent, & &1) do
      {:error, _} = error ->
        error

      torrents ->
        {:ok,
         Enum.map(torrents, fn {id, state} ->
           %DownloadStatus{id: id, name: "The Lantern Keepers #{id}", state: state, progress: 0.5}
         end)}
    end
  end

  def pause_torrent(config, id), do: record(config, :pause, id, :paused)
  def resume_torrent(config, id), do: record(config, :resume, id, :downloading)

  defp record(%{torrents: agent, test: pid}, call, id, state) do
    send(pid, {call, id})
    Agent.update(agent, &List.keystore(&1, id, 0, {id, state}))
  end
end

defmodule Mydia.Downloads.BuiltIn.SpaceGuardTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Mydia.Downloads.BuiltIn.{Config, SpaceGuard, Status}
  alias __MODULE__.StubAdapter

  @moduletag :tmp_dir

  @gib 1024 ** 3
  @reserve 5_000_000_000

  setup %{tmp_dir: dir} do
    status = :"status_#{System.unique_integer([:positive])}"
    topic = "built_in_status:test:#{System.unique_integer([:positive])}"
    start_supervised!({Status, name: status, topic: topic})
    Status.put(status, :engine, :running)

    {:ok, torrents} = Agent.start_link(fn -> [] end)
    {:ok, free} = Agent.start_link(fn -> {:ok, 100 * @gib} end)

    config = %Config{
      enabled?: true,
      download_path: Path.join(dir, "downloads"),
      state_dir: dir,
      min_free_space_bytes: @reserve
    }

    %{status: status, torrents: torrents, free: free, config: config, dir: dir}
  end

  defp start_guard(ctx, overrides \\ []) do
    test = self()

    opts =
      [
        config: ctx.config,
        status: ctx.status,
        client: {StubAdapter, %{torrents: ctx.torrents, test: test}},
        free_bytes: fn path ->
          send(test, {:free_bytes, path})
          Agent.get(ctx.free, & &1)
        end,
        interval_ms: :timer.hours(1),
        # The real runtime entry is a global persistent_term; async tests
        # must not read it.
        runtime: fn -> nil end
      ]
      |> Keyword.merge(overrides)

    start_supervised!({SpaceGuard, opts})
  end

  defp torrents(ctx, list), do: Agent.update(ctx.torrents, fn _ -> list end)
  defp free(ctx, value), do: Agent.update(ctx.free, fn _ -> value end)
  defp record_path(ctx), do: Path.join(ctx.dir, "space-paused")
  defp recorded(ctx), do: record_path(ctx) |> File.read!() |> String.split("\n", trim: true)

  test "below the reserve pauses only downloading torrents and records them", ctx do
    torrents(ctx, [
      {"aaa", :downloading},
      {"bbb", :seeding},
      {"ccc", :paused},
      {"ddd", :downloading}
    ])

    free(ctx, {:ok, @reserve - 1})
    guard = start_guard(ctx)

    assert SpaceGuard.check_now(guard) == :ok

    assert_received {:pause, "aaa"}
    assert_received {:pause, "ddd"}
    refute_received {:pause, _}
    assert Enum.sort(recorded(ctx)) == ["aaa", "ddd"]
    assert %Status{disk: {:low, %{free: free, reserve: "5 GB"}}} = Status.get(ctx.status)
    assert free =~ " GB"
  end

  test "measures the download path", ctx do
    guard = start_guard(ctx)
    SpaceGuard.check_now(guard)
    assert_received {:free_bytes, path}
    assert path == ctx.config.download_path
  end

  test "between the reserve and the reserve plus 1 GiB nothing changes either way", ctx do
    torrents(ctx, [{"aaa", :downloading}])
    free(ctx, {:ok, @reserve + div(@gib, 2)})
    guard = start_guard(ctx)

    SpaceGuard.check_now(guard)
    refute_received {:pause, _}
    refute File.exists?(record_path(ctx))
    assert Status.get(ctx.status).disk == :ok

    # Low, then back into the band: still paused, still recorded.
    free(ctx, {:ok, 1})
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}

    free(ctx, {:ok, @reserve + div(@gib, 2)})
    SpaceGuard.check_now(guard)
    refute_received {:resume, _}
    assert recorded(ctx) == ["aaa"]
    assert {:low, _} = Status.get(ctx.status).disk
  end

  test "above the reserve plus 1 GiB resumes exactly the recorded torrents", ctx do
    torrents(ctx, [{"aaa", :downloading}, {"bbb", :paused}])
    free(ctx, {:ok, 1})
    guard = start_guard(ctx)
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}

    free(ctx, {:ok, @reserve + @gib + 1})
    SpaceGuard.check_now(guard)

    assert_received {:resume, "aaa"}
    refute_received {:resume, _}
    refute File.exists?(record_path(ctx))
    assert Status.get(ctx.status).disk == :ok
  end

  test "a torrent the user resumes while low is dropped and not paused again", ctx do
    torrents(ctx, [{"aaa", :downloading}, {"bbb", :downloading}])
    free(ctx, {:ok, 1})
    guard = start_guard(ctx)
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}
    assert_received {:pause, "bbb"}

    # The user resumes "aaa" by hand.
    torrents(ctx, [{"aaa", :downloading}, {"bbb", :paused}])
    SpaceGuard.check_now(guard)
    refute_received {:pause, _}
    assert recorded(ctx) == ["bbb"]

    SpaceGuard.check_now(guard)
    refute_received {:pause, _}

    # Recovery resumes only what is still recorded.
    free(ctx, {:ok, 100 * @gib})
    SpaceGuard.check_now(guard)
    assert_received {:resume, "bbb"}
    refute_received {:resume, _}

    # The next crossing pauses it again.
    free(ctx, {:ok, 1})
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}
  end

  test "a torrent that starts downloading while low is paused too", ctx do
    free(ctx, {:ok, 1})
    guard = start_guard(ctx)
    SpaceGuard.check_now(guard)
    refute_received {:pause, _}

    torrents(ctx, [{"new", :downloading}])
    SpaceGuard.check_now(guard)
    assert_received {:pause, "new"}
    assert recorded(ctx) == ["new"]
  end

  test "after a restart the recorded torrents resume once there is room", ctx do
    File.write!(record_path(ctx), "aaa\nbbb\n")
    torrents(ctx, [{"aaa", :paused}, {"bbb", :paused}, {"ccc", :paused}])
    guard = start_guard(ctx)

    SpaceGuard.check_now(guard)

    assert_received {:resume, "aaa"}
    assert_received {:resume, "bbb"}
    refute_received {:resume, _}
    refute File.exists?(record_path(ctx))
  end

  test "the first check runs on its own after start", ctx do
    torrents(ctx, [{"aaa", :downloading}])
    free(ctx, {:ok, 1})
    start_guard(ctx, interval_ms: 10)
    assert_receive {:pause, "aaa"}, 1_000
  end

  test "a free space error pauses and resumes nothing and warns once an hour", ctx do
    File.write!(record_path(ctx), "aaa\n")
    torrents(ctx, [{"aaa", :paused}, {"bbb", :downloading}])
    free(ctx, {:error, :df_unavailable})
    guard = start_guard(ctx)
    before = Status.get(ctx.status)

    log =
      capture_log(fn ->
        SpaceGuard.check_now(guard)
        SpaceGuard.check_now(guard)
        SpaceGuard.check_now(guard)
      end)

    refute_received {:pause, _}
    refute_received {:resume, _}
    assert Status.get(ctx.status) == before
    assert recorded(ctx) == ["aaa"]
    # Async tests share the log; this message is the guard's alone.
    assert log |> String.split("Space guard could not measure free space") |> length() == 2
  end

  test "a client error is logged and retried on the next check", ctx do
    Agent.update(ctx.torrents, fn _ -> {:error, :econnrefused} end)
    free(ctx, {:ok, 1})
    guard = start_guard(ctx)

    log = capture_log(fn -> SpaceGuard.check_now(guard) end)
    assert log =~ "econnrefused"
    assert Process.alive?(guard)

    torrents(ctx, [{"aaa", :downloading}])
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}
  end

  test "nothing is sent to the client while the engine is blocked", ctx do
    Status.put(ctx.status, :engine, :starting)
    torrents(ctx, [{"aaa", :downloading}])
    free(ctx, {:ok, 1})
    guard = start_guard(ctx)

    SpaceGuard.check_now(guard)
    refute_received {:pause, _}
    assert {:low, _} = Status.get(ctx.status).disk

    Status.put(ctx.status, :engine, :running)
    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}
  end

  test "a reserve of 0 resumes anything still recorded", ctx do
    File.write!(record_path(ctx), "aaa\n")
    torrents(ctx, [{"aaa", :paused}])
    guard = start_guard(ctx, config: %{ctx.config | min_free_space_bytes: 0})

    SpaceGuard.check_now(guard)

    refute_received {:free_bytes, _}
    assert_received {:resume, "aaa"}
    refute File.exists?(record_path(ctx))
  end

  test "a recorded torrent the client no longer has is dropped", ctx do
    File.write!(record_path(ctx), "gone\n")
    guard = start_guard(ctx)

    SpaceGuard.check_now(guard)

    refute_received {:resume, _}
    refute File.exists?(record_path(ctx))
  end

  test "a reserve changed on the runtime entry is honoured on the next check", ctx do
    alias Mydia.Downloads.BuiltIn.Runtime

    torrents(ctx, [{"aaa", :downloading}])
    free(ctx, {:ok, @reserve + 3 * @gib})
    {:ok, runtime} = Agent.start_link(fn -> nil end)
    guard = start_guard(ctx, runtime: fn -> Agent.get(runtime, & &1) end)

    SpaceGuard.check_now(guard)
    refute_received {:pause, _}

    Agent.update(runtime, fn _ ->
      %Runtime{
        api_port: 1,
        credentials: {"mydia", "x"},
        config: %{ctx.config | min_free_space_bytes: 20_000_000_000}
      }
    end)

    SpaceGuard.check_now(guard)
    assert_received {:pause, "aaa"}
    assert {:low, %{reserve: "20 GB"}} = Status.get(ctx.status).disk
  end

  test "a restarted guard clears a low banner a previous guard left", ctx do
    Status.put(ctx.status, :disk, {:low, %{free: "1 GB", reserve: "5 GB"}})
    guard = start_guard(ctx)

    SpaceGuard.check_now(guard)

    assert Status.get(ctx.status).disk == :ok
  end

  test "a record write that fails is retried on every later check until it lands", ctx do
    torrents(ctx, [{"aaa", :downloading}])
    free(ctx, {:ok, 1})
    {:ok, fail?} = Agent.start_link(fn -> true end)
    test = self()

    write = fn path, ids ->
      send(test, {:write, ids})

      if Agent.get(fail?, & &1),
        do: {:error, :eacces},
        else: SpaceGuard.write_record_file(path, ids)
    end

    guard = start_guard(ctx, write_record: write)

    log = capture_log(fn -> SpaceGuard.check_now(guard) end)
    assert_received {:pause, "aaa"}
    assert log =~ "eacces"
    refute File.exists?(record_path(ctx))

    # The torrent is paused now, so this check has nothing downloading, and
    # free space cannot even be measured. The pending write still lands.
    Agent.update(fail?, fn _ -> false end)
    free(ctx, {:error, :df_unavailable})
    capture_log(fn -> SpaceGuard.check_now(guard) end)
    assert recorded(ctx) == ["aaa"]

    # Once written, a quiet check writes nothing more.
    flush_writes()
    SpaceGuard.check_now(guard)
    refute_received {:write, _}
  end

  defp flush_writes do
    receive do
      {:write, _} -> flush_writes()
    after
      0 -> :ok
    end
  end

  test "a reserve of 0 never measures free space", ctx do
    torrents(ctx, [{"aaa", :downloading}])
    guard = start_guard(ctx, config: %{ctx.config | min_free_space_bytes: 0})

    SpaceGuard.check_now(guard)

    refute_received {:free_bytes, _}
    refute_received {:pause, _}
    assert Status.get(ctx.status).disk == :ok
  end
end
