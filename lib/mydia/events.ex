defmodule Mydia.Events do
  @moduledoc """
  The Events context handles event tracking for user actions and system operations.

  Events provide an audit trail, activity feed, and foundation for analytics.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Events.Event
  alias Phoenix.PubSub

  @pubsub_name Mydia.PubSub
  @events_topic "events:all"

  ## Event Creation

  @doc """
  Creates an event and broadcasts it to subscribers.

  This is a synchronous operation that waits for database insert and PubSub broadcast.

  ## Examples

      iex> create_event(%{category: "media", type: "media_item.added", actor_type: :user, actor_id: "123"})
      {:ok, %Event{}}

      iex> create_event(%{category: "invalid"})
      {:error, %Ecto.Changeset{}}
  """
  def create_event(attrs) do
    %Event{}
    |> Event.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, event} = result ->
        broadcast_event(event)
        result

      error ->
        error
    end
  end

  @doc """
  Creates an event asynchronously without blocking the caller.

  This is a fire-and-forget operation that returns immediately.
  Errors are logged but don't affect the calling process.

  Useful for tracking events in hot code paths where performance matters.

  ## Examples

      iex> create_event_async(%{category: "media", type: "media_item.added"})
      :ok
  """
  def create_event_async(attrs) do
    repo_config = Mydia.Repo.config()

    if repo_config[:pool] == Ecto.Adapters.SQL.Sandbox do
      # In test environment with sandbox, run synchronously to avoid connection issues
      case create_event(attrs) do
        {:ok, event} ->
          Logger.debug("Event created asynchronously: #{event.type}")

        {:error, changeset} ->
          Logger.error("Failed to create event asynchronously: #{inspect(changeset.errors)}")
      end
    else
      # In production, run asynchronously
      Task.Supervisor.start_child(Mydia.TaskSupervisor, fn ->
        case create_event(attrs) do
          {:ok, event} ->
            Logger.debug("Event created asynchronously: #{event.type}")

          {:error, changeset} ->
            Logger.error("Failed to create event asynchronously: #{inspect(changeset.errors)}")
        end
      end)
    end

    :ok
  end

  ## Event Queries

  @doc """
  Lists events with optional filtering and pagination.

  ## Options
    - `:category` - Filter by event category
    - `:type` - Filter by event type
    - `:actor_type` - Filter by actor type (:user, :system, :job)
    - `:actor_id` - Filter by actor ID (requires actor_type)
    - `:resource_type` - Filter by resource type
    - `:resource_id` - Filter by resource ID (requires resource_type)
    - `:severity` - Filter by severity level (:info, :warning, :error)
    - `:since` - Filter events after this DateTime
    - `:until` - Filter events before this DateTime
    - `:limit` - Maximum number of events to return (default: 50)
    - `:offset` - Number of events to skip (default: 0)

  ## Examples

      iex> list_events(category: "media", limit: 10)
      [%Event{}, ...]

      iex> list_events(resource_type: "media_item", resource_id: "123")
      [%Event{}, ...]
  """
  def list_events(opts \\ []) do
    Event
    |> apply_filters(opts)
    |> apply_pagination(opts)
    |> order_by([e], desc: e.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets events for a specific resource.

  ## Examples

      iex> get_resource_events("media_item", "123", limit: 10)
      [%Event{}, ...]
  """
  def get_resource_events(resource_type, resource_id, opts \\ []) do
    opts =
      opts
      |> Keyword.put(:resource_type, resource_type)
      |> Keyword.put(:resource_id, resource_id)

    list_events(opts)
  end

  @doc """
  Counts events matching the given filters.

  Accepts the same filter options as `list_events/1`.

  ## Examples

      iex> count_events(category: "media")
      42

      iex> count_events(severity: :error)
      5
  """
  def count_events(opts \\ []) do
    Event
    |> apply_filters(opts)
    |> select([e], count(e.id))
    |> Repo.one()
  end

  @doc """
  Deletes events older than the specified number of days.

  Returns the count of deleted events.

  ## Examples

      iex> delete_old_events(90)
      {:ok, 150}
  """
  def delete_old_events(days) when is_integer(days) and days > 0 do
    cutoff_date = DateTime.utc_now() |> DateTime.add(-days, :day)

    {count, _} =
      Event
      |> where([e], e.inserted_at < ^cutoff_date)
      |> Repo.delete_all()

    {:ok, count}
  end

  ## Private Helpers

  defp apply_filters(query, opts) do
    query
    |> filter_by_category(opts[:category])
    |> filter_by_type(opts[:type])
    |> filter_by_actor(opts[:actor_type], opts[:actor_id])
    |> filter_by_resource(opts[:resource_type], opts[:resource_id])
    |> filter_by_severity(opts[:severity])
    |> filter_by_date_range(opts[:since], opts[:until])
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category), do: where(query, [e], e.category == ^category)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [e], e.type == ^type)

  defp filter_by_actor(query, nil, _), do: query

  defp filter_by_actor(query, actor_type, nil),
    do: where(query, [e], e.actor_type == ^actor_type)

  defp filter_by_actor(query, actor_type, actor_id) do
    where(query, [e], e.actor_type == ^actor_type and e.actor_id == ^actor_id)
  end

  defp filter_by_resource(query, nil, _), do: query

  defp filter_by_resource(query, resource_type, nil),
    do: where(query, [e], e.resource_type == ^resource_type)

  defp filter_by_resource(query, resource_type, resource_id) do
    where(query, [e], e.resource_type == ^resource_type and e.resource_id == ^resource_id)
  end

  defp filter_by_severity(query, nil), do: query
  defp filter_by_severity(query, severity), do: where(query, [e], e.severity == ^severity)

  defp filter_by_date_range(query, nil, nil), do: query

  defp filter_by_date_range(query, since, nil) when not is_nil(since),
    do: where(query, [e], e.inserted_at >= ^since)

  defp filter_by_date_range(query, nil, until) when not is_nil(until),
    do: where(query, [e], e.inserted_at <= ^until)

  defp filter_by_date_range(query, since, until) do
    where(query, [e], e.inserted_at >= ^since and e.inserted_at <= ^until)
  end

  defp apply_pagination(query, opts) do
    limit = Keyword.get(opts, :limit, 50)
    offset = Keyword.get(opts, :offset, 0)

    query
    |> limit(^limit)
    |> offset(^offset)
  end

  defp broadcast_event(event) do
    PubSub.broadcast(@pubsub_name, @events_topic, {:event_created, event})
  end

  ## Convenience Helper Functions

  @doc """
  Records a media_item.added event.

  ## Parameters
    - `media_item` - The MediaItem struct
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor (user_id, job name, etc.)

  ## Examples

      iex> media_item_added(media_item, :user, user_id)
      :ok
  """
  def media_item_added(media_item, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_item.added",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "year" => media_item.year,
        "tmdb_id" => media_item.tmdb_id
      }
    })
  end

  @doc """
  Records a media_item.updated event.

  ## Parameters
    - `media_item` - The MediaItem struct
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor

  ## Examples

      iex> media_item_updated(media_item, :job, "metadata_refresh")
      :ok
  """
  def media_item_updated(media_item, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_item.updated",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
    })
  end

  @doc """
  Records a media_item.removed event.

  ## Parameters
    - `media_item` - The MediaItem struct
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor

  ## Examples

      iex> media_item_removed(media_item, :user, user_id)
      :ok
  """
  def media_item_removed(media_item, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_item.removed",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
    })
  end

  @doc """
  Records a media_item.monitoring_changed event.

  ## Parameters
    - `media_item` - The MediaItem struct
    - `monitored` - The new monitoring status (true/false)
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor

  ## Examples

      iex> media_item_monitoring_changed(media_item, true, :user, user_id)
      :ok
  """
  def media_item_monitoring_changed(media_item, monitored, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_item.monitoring_changed",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "monitored" => monitored
      }
    })
  end

  @doc """
  Records a media_file.imported event.

  ## Parameters
    - `media_file` - The MediaFile struct
    - `media_item` - The MediaItem struct the file belongs to
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor

  ## Examples

      iex> file_imported(media_file, media_item, :job, "media_import")
      :ok
  """
  def file_imported(media_file, media_item, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_file.imported",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "file_path" =>
          case media_file.relative_path do
            nil -> "unknown"
            relative_path -> Path.basename(relative_path)
          end,
        "resolution" => media_file.resolution,
        "codec" => media_file.codec,
        "size" => media_file.size,
        "media_title" => media_item.title,
        "media_type" => media_item.type
      }
    })
  end

  @doc """
  Records a media_item.episodes_refreshed event for TV shows.

  ## Parameters
    - `media_item` - The TV show MediaItem struct
    - `episode_count` - Number of episodes added/updated
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor

  ## Examples

      iex> episodes_refreshed(media_item, 5, :job, "metadata_refresh")
      :ok
  """
  def episodes_refreshed(media_item, episode_count, actor_type, actor_id) do
    create_event_async(%{
      category: "media",
      type: "media_item.episodes_refreshed",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: %{
        "title" => media_item.title,
        "episode_count" => episode_count
      }
    })
  end

  @doc """
  Records a download.initiated event.

  ## Parameters
    - `download` - The Download struct
    - `actor_type` - :user, :system, or :job
    - `actor_id` - The ID of the actor
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_initiated(download, :user, user_id, media_item: media_item)
      :ok
  """
  def download_initiated(download, actor_type, actor_id, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "indexer" => download.indexer,
        "download_client" => download.download_client,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.initiated",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
  end

  @doc """
  Records a download.completed event.

  ## Parameters
    - `download` - The Download struct
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_completed(download, media_item: media_item)
      :ok
  """
  def download_completed(download, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "download_client" => download.download_client,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.completed",
      actor_type: :system,
      actor_id: "download_monitor",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :info,
      metadata: metadata
    })
  end

  @doc """
  Records a download.failed event.

  ## Parameters
    - `download` - The Download struct
    - `error_message` - The error message describing the failure
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_failed(download, "Connection timeout", media_item: media_item)
      :ok
  """
  def download_failed(download, error_message, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "download_client" => download.download_client,
        "error_message" => error_message,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.failed",
      actor_type: :system,
      actor_id: "download_monitor",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :error,
      metadata: metadata
    })
  end

  @doc """
  Records a download.cancelled event.

  ## Parameters
    - `download` - The Download struct
    - `actor_type` - :user or :system
    - `actor_id` - The ID of the actor
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_cancelled(download, :user, user_id, media_item: media_item)
      :ok
  """
  def download_cancelled(download, actor_type, actor_id, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "download_client" => download.download_client,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.cancelled",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
  end

  @doc """
  Records a download.paused event.

  ## Parameters
    - `download` - The Download struct
    - `actor_type` - :user or :system
    - `actor_id` - The ID of the actor
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_paused(download, :user, user_id, media_item: media_item)
      :ok
  """
  def download_paused(download, actor_type, actor_id, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "download_client" => download.download_client,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.paused",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
  end

  @doc """
  Records a download.resumed event.

  ## Parameters
    - `download` - The Download struct
    - `actor_type` - :user or :system
    - `actor_id` - The ID of the actor
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_resumed(download, :user, user_id, media_item: media_item)
      :ok
  """
  def download_resumed(download, actor_type, actor_id, opts \\ []) do
    media_item = opts[:media_item]

    # Use media_item as resource if available, otherwise use download
    {resource_type, resource_id} =
      if media_item do
        {"media_item", media_item.id}
      else
        {"download", download.id}
      end

    metadata =
      %{
        "title" => download.title,
        "download_client" => download.download_client,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.resumed",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
  end

  @doc """
  Records a job.executed event.

  ## Parameters
    - `job_name` - The name of the job (e.g., "metadata_refresh")
    - `metadata` - Additional metadata (duration, items_processed, etc.)

  ## Examples

      iex> job_executed("metadata_refresh", %{"duration_ms" => 1500, "items_processed" => 10})
      :ok
  """
  def job_executed(job_name, metadata \\ %{}) do
    create_event_async(%{
      category: "system",
      type: "job.executed",
      actor_type: :job,
      actor_id: job_name,
      metadata: Map.merge(%{"job_name" => job_name}, metadata)
    })
  end

  @doc """
  Records a job.failed event.

  ## Parameters
    - `job_name` - The name of the job
    - `error_message` - The error message or reason for failure
    - `metadata` - Additional metadata

  ## Examples

      iex> job_failed("metadata_refresh", "Connection timeout", %{"attempts" => 3})
      :ok
  """
  def job_failed(job_name, error_message, metadata \\ %{}) do
    create_event_async(%{
      category: "system",
      type: "job.failed",
      actor_type: :job,
      actor_id: job_name,
      severity: :error,
      metadata: Map.merge(%{"job_name" => job_name, "error_message" => error_message}, metadata)
    })
  end

  @doc """
  Formats an event for display in a timeline UI.

  Returns a map with icon, color, title, and description suitable for rendering.

  ## Examples

      iex> format_for_timeline(event)
      %{
        icon: "hero-plus-circle",
        color: "text-info",
        title: "Added to Library",
        description: "Breaking Bad was added to your library"
      }
  """
  def format_for_timeline(%Event{} = event) do
    {icon, color, title} = get_event_display_properties(event.type, event.severity)
    description = build_event_description(event)

    %{
      icon: icon,
      color: color,
      title: title,
      description: description
    }
  end

  defp get_event_display_properties(type, severity) do
    case type do
      "media_item.added" ->
        {"hero-plus-circle", "text-info", "Added to Library"}

      "media_item.updated" ->
        {"hero-pencil-square", "text-info", "Updated"}

      "media_item.removed" ->
        {"hero-trash", "text-error", "Removed"}

      "media_item.monitoring_changed" ->
        {"hero-bell", "text-warning", "Monitoring Changed"}

      "media_file.imported" ->
        {"hero-document-check", "text-success", "File Imported"}

      "media_item.episodes_refreshed" ->
        {"hero-arrow-path", "text-info", "Episodes Updated"}

      "download.initiated" ->
        {"hero-arrow-down-tray", "text-primary", "Download Started"}

      "download.completed" ->
        {"hero-check-circle", "text-success", "Download Completed"}

      "download.failed" ->
        {"hero-x-circle", "text-error", "Download Failed"}

      "download.cancelled" ->
        {"hero-minus-circle", "text-warning", "Download Cancelled"}

      "download.paused" ->
        {"hero-pause-circle", "text-warning", "Download Paused"}

      "download.resumed" ->
        {"hero-play-circle", "text-info", "Download Resumed"}

      "job.executed" ->
        {"hero-cog-6-tooth", "text-success", "Job Executed"}

      "job.failed" ->
        {"hero-exclamation-triangle", "text-error", "Job Failed"}

      _ ->
        # Default based on severity
        case severity do
          :error -> {"hero-exclamation-circle", "text-error", "Error"}
          :warning -> {"hero-exclamation-triangle", "text-warning", "Warning"}
          _ -> {"hero-information-circle", "text-info", "Event"}
        end
    end
  end

  defp build_event_description(%Event{type: "media_item.added", metadata: metadata}) do
    "#{metadata["title"]} was added to your library"
  end

  defp build_event_description(%Event{type: "media_item.updated", metadata: metadata}) do
    metadata["title"] || "Media item updated"
  end

  defp build_event_description(%Event{type: "media_item.removed", metadata: metadata}) do
    "#{metadata["title"]} was removed from your library"
  end

  defp build_event_description(%Event{
         type: "media_item.monitoring_changed",
         metadata: metadata
       }) do
    status = if metadata["monitored"], do: "enabled", else: "disabled"
    "Monitoring #{status} for #{metadata["title"]}"
  end

  defp build_event_description(%Event{type: "media_file.imported", metadata: metadata}) do
    metadata["file_path"] || "File imported"
  end

  defp build_event_description(%Event{
         type: "media_item.episodes_refreshed",
         metadata: metadata
       }) do
    count = metadata["episode_count"] || 0
    "#{count} episode#{if count != 1, do: "s", else: ""} added/updated"
  end

  defp build_event_description(%Event{type: type, metadata: metadata})
       when type in [
              "download.initiated",
              "download.completed",
              "download.failed",
              "download.cancelled",
              "download.paused",
              "download.resumed"
            ] do
    metadata["title"] || "Download event"
  end

  defp build_event_description(%Event{type: "job.executed", metadata: metadata}) do
    job_name = metadata["job_name"] || "Unknown job"
    duration = metadata["duration_ms"]
    items = metadata["items_processed"]

    parts = [job_name]

    if items, do: parts = parts ++ ["processed #{items} items"]
    if duration, do: parts = parts ++ ["in #{duration}ms"]

    Enum.join(parts, " - ")
  end

  defp build_event_description(%Event{type: "job.failed", metadata: metadata}) do
    job_name = metadata["job_name"] || "Unknown job"
    error = metadata["error_message"] || "Unknown error"
    "#{job_name} failed: #{error}"
  end

  defp build_event_description(%Event{metadata: metadata}) do
    # Fallback: try to extract a meaningful description from metadata
    cond do
      metadata["title"] -> metadata["title"]
      metadata["description"] -> metadata["description"]
      true -> "Event occurred"
    end
  end

  defp maybe_add_media_context(metadata, nil), do: metadata

  defp maybe_add_media_context(metadata, media_item) do
    Map.merge(metadata, %{
      "media_item_id" => media_item.id,
      "media_title" => media_item.title,
      "media_type" => media_item.type
    })
  end
end
