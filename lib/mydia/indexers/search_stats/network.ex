defmodule Mydia.Indexers.SearchStats.Network do
  @moduledoc """
  Per-process totals for one indexer call: host HTTP time spent by Prowlarr
  engine calls, and the HTTP requests sent to the tracker.

  `Mydia.Indexers.Cardigann.Wasm.Engine.call/3` runs in its caller's process,
  so one indexer search (one `Task.async_stream` task in
  `Mydia.Indexers.search_all/2`) adds up the network time of every mirror it
  tried. `search_with_metrics/3` resets the totals before the call and takes
  them after.

  Requests are counted where they leave Mydia (`add_request/0`): the built-in
  Cardigann engine, its login, FlareSolverr, the Prowlarr engine's host HTTP
  exchanges, Newznab, Jackett and the health probe's homepage GET. A request
  answered by a parity replay is not counted. Work done in another process
  hands its count back to the caller (`add_requests/1`); the Prowlarr engine
  does that for its guest's exchanges.
  """

  @key {__MODULE__, :microseconds}
  @requests {__MODULE__, :requests}

  @doc "Clears both the time and the request totals."
  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
    Process.delete(@requests)
    :ok
  end

  @spec add(non_neg_integer()) :: :ok
  def add(microseconds) do
    Process.put(@key, Process.get(@key, 0) + microseconds)
    :ok
  end

  @doc "The accumulated milliseconds, clearing them; nil when nothing was added."
  @spec take_ms() :: non_neg_integer() | nil
  def take_ms do
    case Process.delete(@key) do
      nil -> nil
      microseconds -> div(microseconds, 1_000)
    end
  end

  @doc "Counts one HTTP request sent to the tracker."
  @spec add_request() :: :ok
  def add_request, do: add_requests(1)

  @doc "Counts `count` requests another process sent on this call's behalf."
  @spec add_requests(non_neg_integer()) :: :ok
  def add_requests(0), do: :ok

  def add_requests(count) when is_integer(count) and count > 0 do
    Process.put(@requests, Process.get(@requests, 0) + count)
    :ok
  end

  @doc "The requests counted, clearing them; nil when none were."
  @spec take_requests() :: non_neg_integer() | nil
  def take_requests, do: Process.delete(@requests)
end
