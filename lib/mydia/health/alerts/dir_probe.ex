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
    worker = spawn_worker(table, path, check)

    # insert_new is the claim: of several concurrent callers, exactly one
    # registers its worker. The worker waits for :go, so it is always
    # registered before it can finish and remove its own entry.
    if :ets.insert_new(table, {path, worker}) do
      send(worker, {:go, self()})
      await(worker, timeout)
    else
      Process.exit(worker, :kill)
      claimed(table, path, check, timeout)
    end
  end

  defp claimed(table, path, check, timeout) do
    case :ets.lookup(table, path) do
      [{^path, pid}] ->
        if Process.alive?(pid) do
          :timeout
        else
          :ets.delete_object(table, {path, pid})
          probe(table, path, check, timeout)
        end

      [] ->
        probe(table, path, check, timeout)
    end
  end

  defp spawn_worker(table, path, check) do
    spawn(fn ->
      receive do
        {:go, caller} ->
          result = check.(path)
          :ets.delete_object(table, {path, self()})
          send(caller, {:dir_probe, self(), result})
      end
    end)
  end

  defp await(worker, timeout) do
    receive do
      {:dir_probe, ^worker, result} -> result
    after
      timeout -> :timeout
    end
  end
end
