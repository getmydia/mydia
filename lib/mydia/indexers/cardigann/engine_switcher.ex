defmodule Mydia.Indexers.Cardigann.EngineSwitcher do
  @moduledoc """
  Applies the `cardigann.engine` setting without a restart.

  Switching to Prowlarr starts `Wasm.Engine` and keeps the built-in engine
  serving searches until the wasm engine reports ready; only then is the
  `:cardigann` adapter re-registered. A failed download or compile never breaks
  search. Switching back re-registers the built-in adapter first, then stops
  the engine, which frees the compiled component. The cache on disk stays, so a
  later switch loads in about a second; `remove_cache/1` deletes it.

  Boot goes through the same path. Both engines share the stored Cardigann
  session, so a cutover does not log anyone out. In-flight wasm calls run in
  their caller's process with their own store and finish normally.

  The active engine is cached in `:persistent_term` for
  `Mydia.Indexers.CardigannFeatureFlags.active_engine/0`.
  """

  use GenServer

  alias Mydia.Indexers.Adapter.Registry
  alias Mydia.Indexers.Cardigann.{EngineSetting, Wasm}
  alias Mydia.Indexers.Cardigann.EngineSwitcher.{Status, Transition}

  @topic "cardigann_engine"
  @active_key {__MODULE__, :active}

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec topic() :: String.t()
  def topic, do: @topic

  @doc "The engine serving searches now."
  @spec active() :: :builtin | :prowlarr
  def active, do: :persistent_term.get(@active_key, :builtin)

  @spec status(GenServer.server()) :: Status.t()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  catch
    :exit, _ ->
      %Status{
        desired: EngineSetting.setting(),
        active: active(),
        locked: EngineSetting.env_locked?()
      }
  end

  @doc "Saves the choice (in the caller, which owns the DB connection) and applies it."
  @spec switch(:builtin | :prowlarr, keyword()) :: :ok | {:error, term()}
  def switch(engine, opts \\ []) do
    with :ok <- EngineSetting.save(engine, opts),
         do: GenServer.call(Keyword.get(opts, :server, __MODULE__), {:apply, engine})
  end

  @spec retry_now(GenServer.server()) :: :ok
  def retry_now(server \\ __MODULE__), do: GenServer.call(server, :retry_now)

  @spec remove_cache(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, :in_use}
  def remove_cache(server \\ __MODULE__), do: GenServer.call(server, :remove_cache)

  @doc "Bytes the cached engine files use on disk."
  @spec cache_bytes() :: non_neg_integer()
  def cache_bytes do
    Wasm.Artifact.cache_dir()
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.map(fn path ->
      case File.stat(path) do
        {:ok, %{type: :regular, size: size}} -> size
        _ -> 0
      end
    end)
    |> Enum.sum()
  end

  # Server

  @impl true
  def init(opts) do
    Phoenix.PubSub.subscribe(Mydia.PubSub, Wasm.Engine.topic())

    engine =
      Keyword.get_lazy(opts, :engine, fn ->
        Application.get_env(:mydia, :cardigann_wasm_engine_module, Wasm.Engine)
      end)

    state = %{engine: engine, desired: :builtin, active: :builtin, transition: nil}
    {:ok, state, {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    state = state |> set_active(:builtin) |> apply_engine(EngineSetting.setting())
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, to_status(state), state}

  def handle_call({:apply, engine}, _from, state),
    do: {:reply, :ok, state |> apply_engine(engine) |> tap(&broadcast/1)}

  def handle_call(:retry_now, _from, state) do
    if state.transition, do: state.engine.retry_now()
    {:reply, :ok, state}
  end

  def handle_call(:remove_cache, _from, %{active: :builtin, transition: nil} = state) do
    bytes = cache_bytes()
    File.rm_rf(Wasm.Artifact.cache_dir())
    {:reply, {:ok, bytes}, state}
  end

  def handle_call(:remove_cache, _from, state), do: {:reply, {:error, :in_use}, state}

  @impl true
  def handle_info({:cardigann_wasm_engine, event}, %{transition: %Transition{} = t} = state) do
    state =
      case event do
        :ready ->
          %{set_active(state, :prowlarr) | transition: nil}

        {:phase, phase} ->
          %{
            state
            | transition: %{
                t
                | phase: phase,
                  phase_started_at: now(),
                  error: nil,
                  next_retry_at: nil
              }
          }

        {:progress, bytes, total} ->
          %{state | transition: %{t | bytes: bytes, total: total}}

        {:unavailable, reason, due} ->
          %{state | transition: %{t | phase: :failed, error: reason, next_retry_at: due}}
      end

    broadcast(state)
    {:noreply, state}
  end

  # Events with no transition running (a stopped engine's last words, or a
  # bench run) change nothing.
  def handle_info({:cardigann_wasm_engine, _event}, state), do: {:noreply, state}

  # Applying

  defp apply_engine(%{active: :prowlarr, transition: nil} = state, :prowlarr),
    do: %{state | desired: :prowlarr}

  defp apply_engine(%{transition: %Transition{}} = state, :prowlarr),
    do: %{state | desired: :prowlarr}

  defp apply_engine(state, :prowlarr) do
    state.engine.ensure_started()
    state = %{state | desired: :prowlarr, transition: %Transition{phase_started_at: now()}}

    # Already compiled (a switcher restart, or a switch back and forth while
    # the process was still up): no event will come, so cut over now.
    if state.engine.status() == :ready,
      do: %{set_active(state, :prowlarr) | transition: nil},
      else: state
  end

  defp apply_engine(state, :builtin) do
    state = %{set_active(state, :builtin) | desired: :builtin, transition: nil}
    state.engine.stop()
    state
  end

  defp set_active(state, engine) do
    :persistent_term.put(@active_key, engine)
    Registry.register(:cardigann, adapter_for(engine))
    %{state | active: engine}
  end

  defp adapter_for(:prowlarr), do: Wasm.Adapter
  defp adapter_for(:builtin), do: Mydia.Indexers.Adapter.Cardigann

  defp to_status(state) do
    %Status{
      desired: state.desired,
      active: state.active,
      transition: state.transition,
      locked: EngineSetting.env_locked?()
    }
  end

  defp broadcast(state),
    do: Phoenix.PubSub.broadcast(Mydia.PubSub, @topic, {:cardigann_engine, to_status(state)})

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
