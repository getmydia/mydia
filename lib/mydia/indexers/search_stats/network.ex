defmodule Mydia.Indexers.SearchStats.Network do
  @moduledoc """
  Per-process total of host HTTP time spent by Prowlarr engine calls.

  `Mydia.Indexers.Cardigann.Wasm.Engine.call/3` runs in its caller's process,
  so one indexer search (one `Task.async_stream` task in
  `Mydia.Indexers.search_all/2`) adds up the network time of every mirror it
  tried. `search_with_metrics/3` resets the total before the call and takes it
  after.
  """

  @key {__MODULE__, :microseconds}

  @spec reset() :: :ok
  def reset do
    Process.delete(@key)
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
end
