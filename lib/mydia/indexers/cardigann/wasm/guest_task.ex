defmodule Mydia.Indexers.Cardigann.Wasm.GuestTask do
  @moduledoc """
  Runs one guest call in a short-lived process of `Mydia.TaskSupervisor`.

  An instance's memory stays resident until the process whose heap references
  its store and instance resources is garbage collected, so a long-lived
  caller (an Oban worker, a LiveView) would hold the last instance between
  calls. The guest work therefore runs in a process that ends with the call.
  The task is not linked to the caller (a crashing guest must never kill a
  search worker; it comes back as an `engine_error`), and keeps `$callers`.
  Everything the guest needs from the caller is in `ctx` (HostHttp's imports
  run in the instance's own process, never the caller's), and telemetry stays
  in the caller.

  The guest still must not outlive its caller, or the concurrency slot would be
  freed while it runs: a watcher linked to the task monitors the caller and
  kills the task when the caller dies. The task does not trap exits and the
  instance is linked to it, so the instance dies with the task.
  """

  alias Mydia.Indexers.Adapter.Error

  # Slack above the guest's own budget before the guest process is given up on.
  @task_grace_ms 5_000

  @doc """
  Runs `fun` (zero-arity, returns the call result) in a guest task and returns
  its result, or an error tuple when the task exits or overruns `timeout_ms`.
  """
  @spec run(map(), non_neg_integer(), (-> result)) :: result | {:error, Error.t()}
        when result: term()
  def run(ctx, timeout_ms, fun) do
    caller = self()
    task = Task.Supervisor.async_nolink(Mydia.TaskSupervisor, fn -> guest(caller, ctx, fun) end)

    case Task.yield(task, timeout_ms + @task_grace_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} ->
        result

      {:exit, reason} ->
        {:error, Error.engine_error("Engine instance exited: #{inspect(reason)}")}

      nil ->
        {:error, Error.timeout("Cardigann call timed out after #{timeout_ms} ms")}
    end
  end

  @doc """
  Test seam: a per-call hook in `ctx` (`:guest_probe`) that observes the guest
  processes. A no-op when `ctx` carries none.
  """
  @spec probe(map(), term()) :: :ok
  def probe(%{guest_probe: probe}, event) when is_function(probe, 1) do
    probe.(event)
    :ok
  end

  def probe(_ctx, _event), do: :ok

  defp guest(caller, ctx, fun) do
    task = self()

    watcher =
      spawn_link(fn ->
        ref = Process.monitor(caller)

        receive do
          {:DOWN, ^ref, :process, _, _} -> Process.exit(task, :kill)
        end
      end)

    probe(ctx, {:task, task})
    probe(ctx, {:watcher, watcher})

    try do
      fun.()
    after
      Process.unlink(watcher)
      Process.exit(watcher, :kill)
    end
  end
end
