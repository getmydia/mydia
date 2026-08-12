defmodule Mydia.Jobs do
  @moduledoc """
  Context for managing and monitoring Oban background jobs.
  """

  import Ecto.Query
  import Mydia.DB
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

        Enum.map(crontab, fn
          {expression, worker, _opts} ->
            %{
              worker: worker,
              worker_name: worker_display_name(worker),
              schedule: expression,
              next_run: calculate_next_run(expression)
            }

          {expression, worker} ->
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
        from j in query, where: j.worker == ^inspect(worker)
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
      where: j.worker == ^inspect(worker),
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
    worker_string = inspect(worker)

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
        select: avg_timestamp_diff_seconds(j.completed_at, j.attempted_at)
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
  Returns the args a crontab entry declares for `worker`, or `%{}`.

  Takes the crontab rather than reading it, so it can be tested without a
  running Oban, which the test environment disables to keep its pool off the
  SQL Sandbox. `crontab/0` supplies it in production.
  """
  @spec cron_args_from(list(), module()) :: map()
  def cron_args_from(crontab, worker) when is_list(crontab) and is_atom(worker) do
    Enum.find_value(crontab, %{}, fn
      {_expression, ^worker, entry_opts} -> Keyword.get(entry_opts, :args, %{})
      _entry -> nil
    end)
  end

  @doc """
  Builds the job changeset a manual trigger would insert for `worker`.

  Split from `trigger_job/1` so the args-threading behaviour can be tested
  without a running Oban, which the test environment disables.
  """
  @spec build_job(list(), module()) :: Ecto.Changeset.t()
  def build_job(crontab, worker) when is_list(crontab) and is_atom(worker) do
    crontab
    |> cron_args_from(worker)
    |> worker.new()
  end

  @doc """
  Manually triggers a job by enqueueing it to Oban.

  Uses the worker's crontab args so a manual run is identical to a scheduled
  one. Enqueueing `%{}` unconditionally used to strip `args:` from every
  scheduled worker that declared them, which discarded the job.

  Returns {:ok, job} or {:error, changeset}.
  """
  def trigger_job(worker) when is_atom(worker) do
    crontab()
    |> build_job(worker)
    |> Oban.insert()
  end

  @doc """
  Lists currently executing jobs.

  Returns a list of jobs that are currently in the "executing" state,
  useful for displaying active job status in the UI.
  """
  def list_executing_jobs do
    from(j in Job,
      where: j.state == "executing",
      order_by: [asc: j.attempted_at],
      select: %{
        id: j.id,
        worker: j.worker,
        attempted_at: j.attempted_at
      }
    )
    |> Repo.all()
    |> Enum.map(fn job ->
      Map.put(job, :worker_name, worker_display_name_from_string(job.worker))
    end)
  end

  @doc """
  Counts currently executing jobs.
  """
  def count_executing_jobs do
    from(j in Job, where: j.state == "executing")
    |> Repo.aggregate(:count, :id)
  end

  @doc """
  Resets stale executing jobs to available state.

  Jobs can get stuck in "executing" state if the application restarts while
  jobs are running. This function finds jobs that have been executing for
  longer than the specified timeout and resets them to "available" so they
  can be retried.

  ## Options
  - `:timeout_minutes` - Consider jobs stale after this many minutes (default: 60)

  Returns `{:ok, count}` where count is the number of jobs reset.
  """
  def reset_stale_executing_jobs(opts \\ []) do
    timeout_minutes = Keyword.get(opts, :timeout_minutes, 60)
    cutoff = DateTime.utc_now() |> DateTime.add(-timeout_minutes * 60, :second)

    {count, _} =
      from(j in Job,
        where: j.state == "executing" and j.attempted_at < ^cutoff
      )
      |> Repo.update_all(set: [state: "available", attempted_at: nil, attempted_by: nil])

    {:ok, count}
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
        from j in query, where: j.worker == ^inspect(worker)
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

  @doc """
  Cancels a job by its ID.

  Returns `:ok` if the job was cancelled, or `{:error, reason}` if it could not be cancelled.
  """
  def cancel_job(job_id) when is_integer(job_id) do
    Oban.cancel_job(job_id)
  end

  # Private helpers

  # The one place that reads the running Cron plugin's crontab, so callers that
  # need a worker's scheduled args do not each re-derive it.
  defp crontab do
    case find_cron_plugin(Oban.config().plugins) do
      {Oban.Plugins.Cron, opts} -> Keyword.get(opts, :crontab, [])
      _ -> []
    end
  end

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

  defp worker_display_name_from_string(worker_string) when is_binary(worker_string) do
    worker_string
    |> String.split(".")
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
