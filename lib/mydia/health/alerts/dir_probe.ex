defmodule Mydia.Health.Alerts.DirProbe do
  @moduledoc """
  `File.dir?/1` with a time limit, for library roots that may sit on a hung
  network mount.

  Each check runs in its own process. The caller waits at most `:timeout`
  (5 seconds) and gets `:timeout` if the check has not answered. A check
  blocked in the kernel cannot be killed, so it is left running and recorded
  in an ETS table; until it returns, later probes of the same path answer
  `:timeout` at once instead of starting another stuck check. At most one
  blocked check exists per path, however long the mount stays hung.

  The table is created by `Mydia.Health.Alerts` (`create_table/0`). Without
  it, as in tests that do not start the watcher, the check runs inline.
  """

  @table :mydia_health_dir_probes
  @timeout 5_000

  @doc "Creates the shared probe table. Called by the owning process."
  def create_table, do: :ets.new(@table, [:set, :public, :named_table])

  @spec dir?(String.t(), keyword()) :: boolean() | :timeout
  def dir?(path, opts \\ []) do
    table = Keyword.get(opts, :table, @table)
    check = Keyword.get(opts, :check, &File.dir?/1)

    if :ets.info(table) == :undefined,
      do: check.(path),
      else: probe(table, path, check, Keyword.get(opts, :timeout, @timeout))
  end

  defp probe(table, path, check, timeout) do
    case :ets.lookup(table, path) do
      [{^path, pid}] ->
        if Process.alive?(pid), do: :timeout, else: start(table, path, check, timeout)

      [] ->
        start(table, path, check, timeout)
    end
  end

  defp start(table, path, check, timeout) do
    caller = self()
    ref = make_ref()

    pid =
      spawn(fn ->
        result = check.(path)
        :ets.delete_object(table, {path, self()})
        send(caller, {ref, result})
      end)

    :ets.insert(table, {path, pid})

    receive do
      {^ref, result} -> result
    after
      timeout -> :timeout
    end
  end
end
