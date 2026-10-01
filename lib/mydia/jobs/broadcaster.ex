defmodule Mydia.Jobs.Broadcaster do
  @moduledoc """
  Bridges Oban job telemetry to the rest of the app.

  Job starts and stops are forwarded to `Mydia.Jobs.StatusTracker`, which
  decides what the sidebar shows and broadcasts on this module's topic.
  LiveViews subscribe here. Failed jobs are also recorded as events.
  """

  alias Mydia.Jobs.StatusTracker

  @pubsub Mydia.PubSub
  @topic "jobs:status"

  @doc """
  Returns the PubSub topic for job status updates.
  """
  def topic, do: @topic

  @doc """
  Subscribes the current process to job status updates.
  """
  def subscribe do
    Phoenix.PubSub.subscribe(@pubsub, @topic)
  end

  @doc """
  Attaches telemetry handlers for Oban job events.
  Should be called once at application startup.
  """
  def attach do
    :telemetry.attach_many(
      "mydia-jobs-broadcaster",
      [
        [:oban, :job, :start],
        [:oban, :job, :stop],
        [:oban, :job, :exception]
      ],
      &handle_event/4,
      nil
    )
  end

  @doc """
  Detaches the telemetry handlers.
  """
  def detach do
    :telemetry.detach("mydia-jobs-broadcaster")
  end

  # Telemetry event handlers

  def handle_event([:oban, :job, :start], _measurements, %{job: job}, _config) do
    StatusTracker.job_started(job)
  end

  def handle_event([:oban, :job, :stop], _measurements, %{job: job}, _config) do
    StatusTracker.job_finished(job)
  end

  def handle_event([:oban, :job, :exception], _measurements, %{job: job} = metadata, _config) do
    StatusTracker.job_finished(job)
    record_job_failure(metadata)
  end

  defp record_job_failure(%{job: job} = metadata) do
    worker_name = job.worker
    error = format_error(metadata)
    job_args = job.args || %{}

    # Build metadata with job context
    event_metadata =
      %{
        "queue" => to_string(job.queue),
        "attempt" => job.attempt,
        "max_attempts" => job.max_attempts,
        "args" => job_args
      }
      |> maybe_add_stacktrace(metadata)

    Mydia.Events.job_failed(worker_name, error, event_metadata)
  end

  defp format_error(%{kind: kind, reason: reason}) do
    case kind do
      :error ->
        Exception.format_banner(:error, reason, [])

      _ ->
        "#{kind}: #{inspect(reason)}"
    end
  end

  defp format_error(%{kind: kind, error: error}) do
    case kind do
      :error ->
        Exception.format_banner(:error, error, [])

      _ ->
        "#{kind}: #{inspect(error)}"
    end
  end

  defp format_error(_), do: "Unknown error"

  defp maybe_add_stacktrace(meta, %{stacktrace: stacktrace}) when is_list(stacktrace) do
    # Only include first few frames to keep it readable
    formatted =
      stacktrace
      |> Enum.take(5)
      |> Exception.format_stacktrace()

    Map.put(meta, "stacktrace", formatted)
  end

  defp maybe_add_stacktrace(meta, _), do: meta
end
