defmodule Mydia.Indexers.Cardigann.Wasm.EngineUnavailableTest do
  # Needs no artifact: it points the engine at a missing one. It restarts the
  # application's Engine, so it must not run beside other engine tests.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @empty %{cookies: %{}, expires_at: nil}

  setup do
    previous = Application.fetch_env(:mydia, :cardigann_wasm_path)

    missing =
      Path.join(
        System.tmp_dir!(),
        "no-such-cardigann-#{Base.url_encode64(:crypto.strong_rand_bytes(8), padding: false)}.wasm"
      )

    Application.put_env(:mydia, :cardigann_wasm_path, missing)

    restart_engine()

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:mydia, :cardigann_wasm_path, value)
        :error -> Application.delete_env(:mydia, :cardigann_wasm_path)
      end

      stop_engine()
    end)

    {:ok, missing: missing}
  end

  test "Artifact honours the :cardigann_wasm_path override", %{missing: missing} do
    assert Artifact.path() == missing
    assert {:error, :missing} = Artifact.load()
  end

  test "a missing artifact leaves the engine unavailable, not crashed" do
    refute Engine.available?()
    assert Process.whereis(Engine)

    ctx = %{definition_id: "none", request_delay_ms: 0, flaresolverr: nil}

    assert {:error, %{type: :engine_unavailable}} =
             Engine.call({:search, "id: x", %{}, query(), @empty}, ctx, 1_000)
  end

  test "a call that gives up while the engine is compiling is a timeout, not unavailable" do
    Application.put_env(:mydia, :cardigann_wasm_compile_delay_ms, 1_500)
    on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_compile_delay_ms) end)

    restart_engine()

    ctx = %{definition_id: "slow", request_delay_ms: 0, flaresolverr: nil}

    assert {:error, %{type: :timeout, details: %{compiling: true}}} =
             Engine.call({:search, "id: x", %{}, query(), @empty}, ctx, 200)
  end

  test "status answers while a slow compile runs, and waiters still settle" do
    Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn ->
      Process.sleep(2_500)
      {:unavailable, "slow compile finished"}
    end)

    on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_compile_fun) end)

    restart_engine()

    waiter = Task.async(fn -> Engine.available?() end)
    Process.sleep(100)

    {micros, status} = :timer.tc(&Engine.status/0)
    assert status == :compiling
    assert micros < 500_000

    refute Task.await(waiter, 10_000)
    assert {:unavailable, reason} = Engine.status()
    assert reason =~ "slow compile finished"
    assert reason =~ "next attempt"
  end

  @tag :capture_log
  test "a compile that raises settles as unavailable without restarting the engine" do
    Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn ->
      Process.sleep(300)
      raise "boom"
    end)

    on_exit(fn -> Application.delete_env(:mydia, :cardigann_wasm_compile_fun) end)

    restart_engine()
    pid = Process.whereis(Engine)

    refute Engine.available?()
    assert {:unavailable, reason} = Engine.status()
    assert reason =~ "compile crashed"
    assert Process.whereis(Engine) == pid
  end

  describe "retry" do
    setup do
      Application.put_env(:mydia, :cardigann_wasm_retry_ms, 50)

      on_exit(fn ->
        Application.delete_env(:mydia, :cardigann_wasm_retry_ms)
        Application.delete_env(:mydia, :cardigann_wasm_compile_fun)
      end)
    end

    @tag :capture_log
    test "a failed attempt is retried in the background until it works" do
      # A long timer, so the retries below happen only when the test sends them.
      Application.put_env(:mydia, :cardigann_wasm_retry_ms, 600_000)
      attempts = :counters.new(1, [])

      Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) < 3,
          do: {:unavailable, "the engine download failed: econnrefused"},
          else: :ready
      end)

      restart_engine()
      refute Engine.available?()

      assert {:unavailable, reason} = Engine.status()
      assert reason =~ "econnrefused"
      assert reason =~ ~r/next attempt \d{4}-\d\d-\d\dT/

      for attempt <- 2..3 do
        send(Engine, :retry)
        assert wait_for(fn -> :counters.get(attempts, 1) == attempt and settled?() end)
      end

      assert Engine.status() == :ready
    end

    @tag :capture_log
    test "a caller during a retry gets the unavailable answer at once" do
      Application.put_env(:mydia, :cardigann_wasm_retry_ms, 600_000)
      attempts = :counters.new(1, [])

      Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn ->
        :counters.add(attempts, 1, 1)

        if :counters.get(attempts, 1) == 1 do
          {:unavailable, "the engine download failed: timeout"}
        else
          Process.sleep(3_000)
          :ready
        end
      end)

      restart_engine()
      refute Engine.available?()

      send(Engine, :retry)
      assert wait_for(fn -> match?({:unavailable, "" <> r} when r != "", Engine.status()) end)
      assert {:unavailable, reason} = Engine.status()
      assert reason =~ "retrying now"

      ctx = %{definition_id: "retry", request_delay_ms: 0, flaresolverr: nil}

      {micros, result} =
        :timer.tc(fn -> Engine.call({:search, "id: x", %{}, query(), @empty}, ctx, 10_000) end)

      assert {:error, %{type: :engine_unavailable, message: message}} = result
      assert message =~ "timeout"
      assert micros < 1_000_000
    end

    @tag :capture_log
    test "the wait doubles after each failure" do
      Application.put_env(:mydia, :cardigann_wasm_retry_ms, 1_000)
      Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn -> {:unavailable, "no"} end)

      restart_engine()
      refute Engine.available?()

      state = :sys.get_state(Engine)
      assert state.failures == 1
      assert Process.read_timer(state.timer) in 1..1_000
    end

    @tag :capture_log
    test "a permanent failure is not retried" do
      attempts = :counters.new(1, [])

      Application.put_env(:mydia, :cardigann_wasm_compile_fun, fn ->
        :counters.add(attempts, 1, 1)
        {:unavailable, "does not match the checksum pinned in this build", :permanent}
      end)

      restart_engine()
      refute Engine.available?()
      Process.sleep(400)

      assert {:unavailable, reason} = Engine.status()
      assert reason == "does not match the checksum pinned in this build"
      assert :counters.get(attempts, 1) == 1
    end
  end

  # Not mid-attempt: unavailable without "retrying now", or ready.
  defp settled? do
    case Engine.status() do
      :ready -> true
      {:unavailable, reason} -> not String.contains?(reason, "retrying now")
      _ -> false
    end
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(50) && wait_for(fun, tries - 1)
    end
  end

  # The application starts the engine only under CARDIGANN_ENGINE=prowlarr, so
  # these tests start (and afterwards remove) it themselves.
  defp stop_engine do
    Supervisor.terminate_child(Mydia.Supervisor, Engine)
    Supervisor.delete_child(Mydia.Supervisor, Engine)
  end

  defp restart_engine do
    stop_engine()
    :ok = Engine.ensure_started()
  end

  defp query,
    do: %{
      kind: :search,
      term: "x",
      categories: [],
      imdb_id: nil,
      tmdb_id: nil,
      tvdb_id: nil,
      season: nil,
      episode: nil,
      limit: nil,
      offset: nil
    }
end
