defmodule Mydia.Jobs do
  @moduledoc """
  Context for managing and monitoring Oban background jobs.
  """

  import Ecto.Query
  alias Mydia.Repo
  alias Oban.Job

  @doc """
  Lists all configured cron jobs from Oban configuration.

  Returns a list of maps with job details including:
  - worker: the worker module name
  - schedule: the cron expression
  - next_run: DateTime of next scheduled run
  """
  def list_cron_jobs do
    config = Oban.config()
    cron_plugin = find_cron_plugin(config.plugins)

    case cron_plugin do
      nil ->
        []

      {Oban.Plugins.Cron, opts} ->
        crontab = Keyword.get(opts, :crontab, [])

        Enum.map(crontab, fn {expression, worker} ->
          %{
            worker: worker,
            worker_name: worker_display_name(worker),
            schedule: expression,
            next_run: calculate_next_run(expression)
          }
        end)
    end
  end

  @doc """
  Lists job execution history with optional filtering.

  ## Options
  - `:worker` - Filter by worker module
  - `:state` - Filter by job state (completed, failed, retryable, etc.)
  - `:limit` - Limit number of results (default: 100)
  - `:offset` - Offset for pagination (default: 0)
  """
  def list_job_history(opts \\ []) do
    worker = Keyword.get(opts, :worker)
    state = Keyword.get(opts, :state)
    limit = Keyword.get(opts, :limit, 100)
    offset = Keyword.get(opts, :offset, 0)

    query =
      from j in Job,
        order_by: [desc: j.attempted_at],
        limit: ^limit,
        offset: ^offset

    query =
      if worker do
        from j in query, where: j.worker == ^to_string(worker)
      else
        query
      end

    query =
      if state do
        from j in query, where: j.state == ^to_string(state)
      else
        query
      end

    Repo.all(query)
  end

  @doc """
  Gets the latest job execution for a specific worker.
  """
  def get_latest_job(worker) do
    from(j in Job,
      where: j.worker == ^to_string(worker),
      order_by: [desc: j.attempted_at],
      limit: 1
    )
    |> Repo.one()
  end

  @doc """
  Gets statistics for a specific worker.

  Returns a map with:
  - total_executions: total number of job attempts
  - completed_count: number of completed jobs
  - failed_count: number of failed jobs
  - success_rate: percentage of successful completions
  - avg_duration_ms: average execution time in milliseconds
  """
  def get_job_stats(worker) do
    worker_string = to_string(worker)

    # Get counts by state
    counts =
      from(j in Job,
        where: j.worker == ^worker_string and not is_nil(j.attempted_at),
        group_by: j.state,
        select: {j.state, count(j.id)}
      )
      |> Repo.all()
      |> Map.new()

    completed = Map.get(counts, "completed", 0)
    failed = Map.get(counts, "discarded", 0) + Map.get(counts, "cancelled", 0)
    total = Enum.reduce(counts, 0, fn {_state, count}, acc -> acc + count end)

    # Calculate average duration for completed jobs
    avg_duration =
      from(j in Job,
        where: j.worker == ^worker_string and j.state == "completed",
        select: fragment("AVG(CAST((completed_at - attempted_at) AS REAL))")
      )
      |> Repo.one()

    # Convert seconds to milliseconds
    avg_duration_ms =
      if avg_duration do
        round(avg_duration * 1000)
      else
        0
      end

    success_rate =
      if total > 0 do
        Float.round(completed / total * 100, 1)
      else
        0.0
      end

    %{
      total_executions: total,
      completed_count: completed,
      failed_count: failed,
      success_rate: success_rate,
      avg_duration_ms: avg_duration_ms
    }
  end

  @doc """
  Manually triggers a job by enqueueing it to Oban.

  Returns {:ok, job} or {:error, changeset}.
  """
  def trigger_job(worker) when is_atom(worker) do
    worker.new(%{})
    |> Oban.insert()
  end

  @doc """
  Counts total jobs in history for pagination.
  """
  def count_job_history(opts \\ []) do
    worker = Keyword.get(opts, :worker)
    state = Keyword.get(opts, :state)

    query = from(j in Job)

    query =
      if worker do
        from j in query, where: j.worker == ^to_string(worker)
      else
        query
      end

    query =
      if state do
        from j in query, where: j.state == ^to_string(state)
      else
        query
      end

    Repo.aggregate(query, :count, :id)
  end

  # Private helpers

  defp find_cron_plugin(plugins) do
    Enum.find(plugins, fn
      {Oban.Plugins.Cron, _opts} -> true
      _ -> false
    end)
  end

  defp calculate_next_run(cron_expression) do
    case Crontab.CronExpression.Parser.parse(cron_expression) do
      {:ok, expression} ->
        now = DateTime.utc_now()

        case Crontab.Scheduler.get_next_run_date(expression, now) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp worker_display_name(worker) when is_atom(worker) do
    worker
    |> Module.split()
    |> List.last()
    |> humanize_name()
  end

  defp humanize_name(name) do
    name
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
