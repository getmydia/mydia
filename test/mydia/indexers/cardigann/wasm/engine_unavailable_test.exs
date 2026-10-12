defmodule Mydia.Indexers.Cardigann.Wasm.EngineUnavailableTest do
  # Needs no artifact: it points the engine at a missing one. It restarts the
  # application's Engine, so it must not run beside other engine tests.
  use ExUnit.Case, async: false

  alias Mydia.Indexers.Cardigann.Wasm.{Artifact, Engine}

  @empty %{cookies: %{}, expires_at: nil}

  setup do
    previous = Application.fetch_env(:mydia, :cardigann_wasm_path)

    missing =
      Path.join(System.tmp_dir!(), "no-such-cardigann-#{System.unique_integer([:positive])}.wasm")

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
    assert Engine.status() == {:unavailable, "slow compile finished"}
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
