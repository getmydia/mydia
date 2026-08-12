defmodule Mydia.Subtitles.Health do
  @moduledoc """
  Tracks consecutive failures per subtitle provider and skips the ones that are
  clearly down.

  Failure detection is passive, driven only by searches a user asked for. The
  indexer equivalent probes on a timer, which is fine when a probe is free.
  Probing OpenSubtitles is not free: it spends the same daily allowance the user
  wants for actual downloads, so a provider is judged on the requests it was
  already given.

  Three consecutive failures open the circuit for five minutes. Afterwards one
  request is admitted, and its outcome either closes the circuit or opens it
  again. State is in-memory: losing it on restart costs one round of real
  requests to rediscover, which is cheaper than persisting it.
  """

  use GenServer

  require Logger

  @failure_threshold 3
  @cooldown_ms :timer.minutes(5)

  ## Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Records a successful search, closing the circuit.
  """
  @spec record_success(atom()) :: :ok
  def record_success(provider_type) do
    GenServer.cast(__MODULE__, {:success, provider_type})
  end

  @doc """
  Records a failed search. Three in a row open the circuit.
  """
  @spec record_failure(atom()) :: :ok
  def record_failure(provider_type) do
    GenServer.cast(__MODULE__, {:failure, provider_type})
  end

  @doc """
  Returns false while a provider's circuit is open and its cooldown has not
  elapsed. Unknown providers are available.
  """
  @spec available?(atom()) :: boolean()
  def available?(provider_type) do
    GenServer.call(__MODULE__, {:available?, provider_type})
  catch
    :exit, _reason -> true
  end

  @doc """
  Clears all state for a provider.
  """
  @spec reset(atom()) :: :ok
  def reset(provider_type) do
    GenServer.call(__MODULE__, {:reset, provider_type})
  end

  @doc false
  # Test seam: ages the cooldown out without sleeping for five minutes.
  def expire_cooldown_for_test(provider_type) do
    GenServer.call(__MODULE__, {:expire_cooldown, provider_type})
  end

  ## Server callbacks

  @impl true
  def init(_opts), do: {:ok, %{}}

  @impl true
  def handle_cast({:success, provider_type}, state) do
    {:noreply, Map.delete(state, provider_type)}
  end

  @impl true
  def handle_cast({:failure, provider_type}, state) do
    entry = Map.get(state, provider_type, %{failures: 0, opened_at: nil})
    failures = entry.failures + 1

    entry =
      if failures >= @failure_threshold do
        Logger.warning("Subtitle provider circuit opened",
          provider: provider_type,
          failures: failures
        )

        %{failures: failures, opened_at: System.monotonic_time(:millisecond)}
      else
        %{failures: failures, opened_at: nil}
      end

    {:noreply, Map.put(state, provider_type, entry)}
  end

  @impl true
  def handle_call({:available?, provider_type}, _from, state) do
    available =
      case Map.get(state, provider_type) do
        nil ->
          true

        %{opened_at: nil} ->
          true

        %{opened_at: opened_at} ->
          System.monotonic_time(:millisecond) - opened_at >= @cooldown_ms
      end

    {:reply, available, state}
  end

  @impl true
  def handle_call({:reset, provider_type}, _from, state) do
    {:reply, :ok, Map.delete(state, provider_type)}
  end

  @impl true
  def handle_call({:expire_cooldown, provider_type}, _from, state) do
    state =
      case Map.get(state, provider_type) do
        nil ->
          state

        entry ->
          Map.put(state, provider_type, %{
            entry
            | opened_at: System.monotonic_time(:millisecond) - @cooldown_ms - 1
          })
      end

    {:reply, :ok, state}
  end
end
