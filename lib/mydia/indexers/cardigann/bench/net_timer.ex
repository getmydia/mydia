defmodule Mydia.Indexers.Cardigann.Bench.NetTimer do
  @moduledoc """
  Measures the time the Elixir Cardigann engine spends inside HTTP requests.

  Req 0.7.4 emits no telemetry, so the benchmark installs this module as the Req
  `:adapter` (through `Req.default_options/1`, only for the duration of a run).
  It runs `Req.Finch` unchanged and adds the elapsed time of each request to an
  atomics counter registered for the calling process. Requests made by processes
  that never registered, directly or through `$callers`, are not timed.

  What is timed is the adapter step: connection checkout, the exchange and the
  body read. Req's own request and response steps (headers, decompression,
  redirect and retry bookkeeping, cookie handling) run outside it and count as
  engine overhead, as does any sleep between retries.
  """

  @table :mydia_cardigann_bench_net

  @doc "Creates the registry table. Idempotent; the table is owned by the caller."
  @spec init() :: :ok
  def init do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set])
    end

    :ok
  end

  @doc "Registers the calling process; returns the counter to read back later."
  @spec register() :: :atomics.atomics_ref()
  def register do
    counter = :atomics.new(1, signed: false)
    :ets.insert(@table, {self(), counter})
    counter
  end

  @spec unregister() :: :ok
  def unregister do
    :ets.delete(@table, self())
    :ok
  end

  @doc "Microseconds recorded on `counter`, as milliseconds."
  @spec read_ms(:atomics.atomics_ref()) :: float()
  def read_ms(counter), do: :atomics.get(counter, 1) / 1000

  # Req adapter behaviour: a module with run/1.
  @doc false
  def run(request) do
    started = System.monotonic_time(:microsecond)

    try do
      Req.Finch.run(request)
    after
      record(System.monotonic_time(:microsecond) - started)
    end
  end

  defp record(micros) do
    with true <- :ets.whereis(@table) != :undefined,
         counter when counter != nil <- find_counter() do
      :atomics.add(counter, 1, max(micros, 0))
    end

    :ok
  end

  defp find_counter do
    Enum.find_value([self() | Process.get(:"$callers", [])], &lookup_counter/1)
  end

  defp lookup_counter(pid) do
    case :ets.lookup(@table, pid) do
      [{^pid, counter}] -> counter
      [] -> nil
    end
  end
end
