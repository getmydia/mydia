defmodule Mydia.Indexers.Cardigann.Wasm.Slots do
  @moduledoc """
  Caps how many Cardigann guest instances run at once. Each instance grows its
  own .NET heap (`native/cardigann_guest/BENCH.md`, "Memory per instance"), so
  concurrent searches add up; this bounds the worst case at `max` instances.

  `run/3` holds a slot for the length of `fun`. Time spent queueing counts
  against the caller's timeout. A slot is freed when the holder returns, raises
  or dies (monitored). A caller that gives up in the queue cancels its request,
  so a slot granted after it gave up is handed back.
  """

  use GenServer

  require Logger

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    max = Keyword.get(opts, :max, Application.get_env(:mydia, :cardigann_wasm_max_instances, 2))
    GenServer.start_link(__MODULE__, max, name: name)
  end

  @spec run(GenServer.server(), pos_integer(), (-> result)) ::
          {:ok, result, non_neg_integer()} | {:error, :timeout}
        when result: term()
  def run(server \\ __MODULE__, timeout_ms, fun) do
    if GenServer.whereis(server) do
      started = System.monotonic_time(:millisecond)

      try do
        :ok = GenServer.call(server, :acquire, timeout_ms)
      catch
        :exit, {:timeout, _} ->
          GenServer.cast(server, {:cancel, self()})
          {:error, :timeout}

        :exit, reason ->
          Logger.warning("Cardigann slots unavailable (#{inspect(reason)}), running unslotted")
          {:ok, fun.(), System.monotonic_time(:millisecond) - started}
      else
        :ok ->
          waited = System.monotonic_time(:millisecond) - started

          try do
            {:ok, fun.(), waited}
          after
            GenServer.cast(server, {:release, self()})
          end
      end
    else
      {:ok, fun.(), 0}
    end
  end

  # Holders and queued callers are both monitored, so a process that dies in
  # either place is cleaned up. Queue entries are {pid, from, ref}.
  @impl true
  def init(max), do: {:ok, %{max: max, holders: %{}, queue: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _} = from, state) do
    if map_size(state.holders) < state.max do
      {:reply, :ok, %{state | holders: Map.put(state.holders, pid, Process.monitor(pid))}}
    else
      entry = {pid, from, Process.monitor(pid)}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, release(state, pid)}

  # Gave up in the queue: drop the request, or hand back a slot granted too late.
  def handle_cast({:cancel, pid}, state), do: {:noreply, state |> dequeue(pid) |> release(pid)}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, state |> dequeue(pid) |> release(pid)}

  defp dequeue(state, pid) do
    {gone, kept} = state.queue |> :queue.to_list() |> Enum.split_with(&(elem(&1, 0) == pid))
    Enum.each(gone, fn {_, _, ref} -> Process.demonitor(ref, [:flush]) end)
    %{state | queue: :queue.from_list(kept)}
  end

  defp release(state, pid) do
    case Map.pop(state.holders, pid) do
      {nil, _} ->
        state

      {ref, holders} ->
        Process.demonitor(ref, [:flush])
        next(%{state | holders: holders})
    end
  end

  # The queued caller's monitor carries over as its holder monitor.
  defp next(state) do
    case :queue.out(state.queue) do
      {{:value, {pid, from, ref}}, queue} ->
        GenServer.reply(from, :ok)
        %{state | queue: queue, holders: Map.put(state.holders, pid, ref)}

      {:empty, _} ->
        state
    end
  end
end
