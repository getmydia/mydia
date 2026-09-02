defmodule Mydia.Jobs.ErrorLogger do
  @moduledoc """
  Logs Oban job failures.

  Oban emits `[:oban, :job, :exception]` for every failed attempt, but nothing
  in this application listened for it and `Oban.Telemetry.attach_default_logger/1`
  was never called. A worker that raised produced no output at all: the crash
  was recorded only in the `errors` column of `oban_jobs`, and a job that
  exhausted `max_attempts` was discarded in silence.

  That is how a TV search which crashed on every one of its three attempts
  looked, from the logs, exactly like a search that found nothing worth
  grabbing. Sibling of `Mydia.Jobs.Broadcaster`; both are attached from
  `Mydia.Application.start/2`.
  """

  require Logger

  @handler_id "mydia-oban-error-logger"
  @event [:oban, :job, :exception]

  @spec attach() :: :ok | {:error, :already_exists}
  def attach do
    :telemetry.attach(@handler_id, @event, &__MODULE__.handle_event/4, nil)
  end

  @spec detach() :: :ok | {:error, :not_found}
  def detach do
    :telemetry.detach(@handler_id)
  end

  @doc false
  def handle_event(@event, _measurements, %{job: job} = metadata, _config) do
    Logger.error(
      "Oban job failed: #{job.worker} (attempt #{job.attempt}/#{job.max_attempts})",
      oban_job_id: job.id,
      oban_worker: job.worker,
      oban_args: inspect(job.args),
      oban_attempt: job.attempt,
      oban_max_attempts: job.max_attempts,
      oban_error: format_error(metadata)
    )
  end

  def handle_event(_event, _measurements, _metadata, _config), do: :ok

  defp format_error(%{kind: kind, reason: reason, stacktrace: stacktrace})
       when is_list(stacktrace) do
    Exception.format(kind, reason, stacktrace)
  end

  defp format_error(%{reason: reason}), do: inspect(reason)

  defp format_error(_), do: "unknown"
end
