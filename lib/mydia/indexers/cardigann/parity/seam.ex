defmodule Mydia.Indexers.Cardigann.Parity.Seam do
  @moduledoc """
  Process-scoped switch that routes a Cardigann engine's HTTP through the
  parity harness instead of the network.

  The active value lives in the process dictionary and is found through the
  `$callers` chain, so work done in `Task`s the engine spawns still sees it.
  Production code only ever reads `current/0`; it is `nil` outside the harness.
  """

  @key {__MODULE__, :active}

  @type active :: %{optional(:replay) => pid(), optional(:record) => pid()}

  @doc "Runs `fun` with `active` installed, restoring the previous value afterwards."
  @spec with(active(), (-> result)) :: result when result: term()
  def with(active, fun) when is_map(active) and is_function(fun, 0) do
    previous = Process.get(@key)
    Process.put(@key, active)

    try do
      fun.()
    after
      if previous, do: Process.put(@key, previous), else: Process.delete(@key)
    end
  end

  @doc "The active seam for this process or one of its callers, if any."
  @spec current() :: active() | nil
  def current do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(&lookup/1)
  end

  defp lookup(pid) when pid == self(), do: Process.get(@key)

  defp lookup(pid) when is_pid(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> dict |> List.keyfind(@key, 0, {nil, nil}) |> elem(1)
      # The caller has exited.
      nil -> nil
    end
  end

  defp lookup(_), do: nil
end
