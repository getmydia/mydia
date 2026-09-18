defmodule Mydia.Jobs.Broadcaster do
  @moduledoc """
  Broadcasts Oban job status changes to PubSub for real-time UI updates.

  This module attaches to Oban telemetry events and broadcasts to a PubSub topic
  so that LiveViews can subscribe and update their UI when jobs start/complete.
  """

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

  @doc """
  Broadcasts the current job status to all subscribers.
  Called after job events to notify listeners.
  """
  def broadcast_status do
    executing_jobs = Mydia.Jobs.list_executing_jobs()
    Phoenix.PubSub.broadcast(@pubsub, @topic, {:jobs_status_changed, executing_jobs})
  end

  # Telemetry event handlers

  def handle_event([:oban, :job, :start], _measurements, _metadata, _config) do
    broadcast_status()
  end

  def handle_event([:oban, :job, :stop], _measurements, _metadata, _config) do
    broadcast_status()
  end

  def handle_event([:oban, :job, :exception], _measurements, metadata, _config) do
    broadcast_status()
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
