defmodule Mydia.Indexers.FlareSolverr.Gate do
  @moduledoc """
  Node-wide cap on concurrent FlareSolverr requests.

  Every FlareSolverr request opens a Chrome tab. `Indexers.search_all/2` fans
  out to every enabled indexer at once, so with several Cloudflare-protected
  indexers FlareSolverr was asked for half a dozen tabs together and crashed
  them ("tab crashed"), failing every indexer but the first. Callers queue
  here instead, in arrival order.

  A slot is held by a monitored caller, so a search task killed at its
  deadline frees its slot. A caller that gives up waiting cancels its place in
  the queue, and if the grant raced the cancel the slot is released at once.
  """

  use GenServer

  @default_timeout 60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, :ok, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs `fun` once a slot is free.

  ## Options

    * `:limit` - slots available, at least 1 (default: 1)
    * `:timeout` - milliseconds to wait for a slot (default: 60_000)
    * `:server` - the gate process (default: this module)

  Returns `{:error, :flaresolverr_busy}` when no slot freed up in time.
  """
  @spec run((-> result), keyword()) :: result | {:error, :flaresolverr_busy} when result: var
  def run(fun, opts \\ []) when is_function(fun, 0) do
    server = Keyword.get(opts, :server, __MODULE__)
    limit = max(Keyword.get(opts, :limit, 1), 1)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    ref = make_ref()

    try do
      GenServer.call(server, {:acquire, ref, limit}, timeout)
    catch
      :exit, {:timeout, _} ->
        GenServer.cast(server, {:cancel, ref})
        {:error, :flaresolverr_busy}
    else
      :ok ->
        try do
          fun.()
        after
          GenServer.cast(server, {:release, ref})
        end
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{holders: %{}, queue: :queue.new()}}

  @impl true
  def handle_call({:acquire, ref, limit}, {pid, _} = from, state) do
    monitor = Process.monitor(pid)
    state = %{state | queue: :queue.in({ref, from, monitor, limit}, state.queue)}
    {:noreply, grant(state)}
  end

  @impl true
  def handle_cast({:release, ref}, state), do: {:noreply, state |> drop(ref) |> grant()}
  def handle_cast({:cancel, ref}, state), do: {:noreply, state |> drop(ref) |> grant()}

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    ref =
      Enum.find_value(state.holders, fn {r, m} -> if m == monitor, do: r end) ||
        Enum.find_value(:queue.to_list(state.queue), fn {r, _f, m, _l} ->
          if m == monitor, do: r
        end)

    state = if ref, do: drop(state, ref), else: state
    {:noreply, grant(state)}
  end

  # The limit is read per call from the live config, so the head of the queue
  # carries the limit that applies when it is granted.
  defp grant(state) do
    case :queue.peek(state.queue) do
      {:value, {ref, from, monitor, limit}} when map_size(state.holders) < limit ->
        GenServer.reply(from, :ok)
        {_, queue} = :queue.out(state.queue)
        grant(%{state | queue: queue, holders: Map.put(state.holders, ref, monitor)})

      _ ->
        state
    end
  end

  defp drop(state, ref) do
    case Map.pop(state.holders, ref) do
      {nil, _} ->
        {dropped, kept} =
          Enum.split_with(:queue.to_list(state.queue), fn {r, _, _, _} -> r == ref end)

        Enum.each(dropped, fn {_, _, monitor, _} -> Process.demonitor(monitor, [:flush]) end)
        %{state | queue: :queue.from_list(kept)}

      {monitor, holders} ->
        Process.demonitor(monitor, [:flush])
        %{state | holders: holders}
    end
  end
end
