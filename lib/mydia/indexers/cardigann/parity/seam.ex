defmodule Mydia.Indexers.Cardigann.Parity.Seam do
  @moduledoc """
  Process-scoped switch that routes a Cardigann engine's HTTP through the
  parity harness instead of the network.

  The active value lives in the process dictionary and is found through the
  `$callers` chain, so work done in `Task`s the engine spawns still sees it.
  Production code only ever reads it (`current/0`, `replaying?/0`,
  `put_req_plug/1`); it is `nil` outside the harness.
  """

  alias Mydia.Indexers.Cardigann.Parity.Replay

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

  @doc """
  True while a parity replay is serving this process's requests. Replay answers
  from a recording, so there is no tracker to throttle for.
  """
  @spec replaying?() :: boolean()
  def replaying?, do: match?(%{replay: _}, current())

  @doc """
  Adds Req's `:plug` option to `opts` when a parity replay is active, so the
  request is answered from the recorded capture. Returns `opts` untouched
  otherwise.
  """
  @spec put_req_plug(keyword()) :: keyword()
  def put_req_plug(opts) when is_list(opts) do
    case current() do
      %{replay: replay} -> Keyword.put(opts, :plug, Replay.req_plug(replay))
      _ -> opts
    end
  end

  defp lookup(pid) when pid == self(), do: Process.get(@key)

  # Asking for the one key copies only its value, not the caller's whole
  # dictionary, which keeps the lookup cheap on the production hot path.
  defp lookup(pid) when is_pid(pid) do
    case Process.info(pid, {:dictionary, @key}) do
      {{:dictionary, @key}, :undefined} -> nil
      {{:dictionary, @key}, value} -> value
      # The caller has exited.
      nil -> nil
    end
  end

  defp lookup(_), do: nil
end
