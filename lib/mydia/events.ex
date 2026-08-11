defmodule Mydia.Events do
  @moduledoc """
  The Events context handles event tracking for user actions and system operations.

  Events provide an audit trail, activity feed, and foundation for analytics.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Events.Event
  alias Mydia.Events.Presentation
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
    - `:exclude_types` - Filter out a list of event types
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
    |> order_by([e], desc: e.inserted_at, desc: e.id)
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
    |> filter_by_exclude_types(opts[:exclude_types])
    |> filter_by_actor(opts[:actor_type], opts[:actor_id])
    |> filter_by_resource(opts[:resource_type], opts[:resource_id])
    |> filter_by_severity(opts[:severity])
    |> filter_by_date_range(opts[:since], opts[:until])
  end

  defp filter_by_category(query, nil), do: query
  defp filter_by_category(query, category), do: where(query, [e], e.category == ^category)

  defp filter_by_type(query, nil), do: query
  defp filter_by_type(query, type), do: where(query, [e], e.type == ^type)

  defp filter_by_exclude_types(query, nil), do: query
  defp filter_by_exclude_types(query, []), do: query

  defp filter_by_exclude_types(query, types) when is_list(types) do
    if Enum.all?(types, &is_binary/1) do
      where(query, [e], e.type not in ^types)
    else
      raise ArgumentError,
            "expected :exclude_types to be a list of strings, got: #{inspect(types)}"
    end
  end

  defp filter_by_exclude_types(_query, other),
    do:
      raise(
        ArgumentError,
        "expected :exclude_types to be a list of strings, got: #{inspect(other)}"
      )

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

  @doc "Subscribes the calling process to the global event feed (`{:event_created, event}`)."
  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: PubSub.subscribe(@pubsub_name, @events_topic)

  @doc "Unsubscribes the calling process from the global event feed."
  @spec unsubscribe() :: :ok
  def unsubscribe, do: PubSub.unsubscribe(@pubsub_name, @events_topic)

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
    - `reason` - A description of what was updated (e.g., "Metadata refreshed", "Settings updated")
    - `changes` - Optional map of changes that were made (field => %{old: x, new: y})

  ## Examples

      iex> media_item_updated(media_item, :job, "metadata_refresh", "Metadata refreshed")
      :ok

      iex> media_item_updated(media_item, :system, "enricher", "Metadata enriched", %{year: %{old: nil, new: 2024}})
      :ok
  """
  def media_item_updated(media_item, actor_type, actor_id, reason \\ "Updated", changes \\ %{}) do
    metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "reason" => reason
      }
      |> maybe_add_changes(changes)

    create_event_async(%{
      category: "media",
      type: "media_item.updated",
      actor_type: actor_type,
      actor_id: actor_id,
      resource_type: "media_item",
      resource_id: media_item.id,
      metadata: metadata
    })
  end

  defp maybe_add_changes(metadata, changes) when changes == %{}, do: metadata

  defp maybe_add_changes(metadata, changes) do
    # Convert the changes map to a JSON-serializable format with string keys
    serialized_changes =
      changes
      |> Enum.map(fn {field, value} ->
        {to_string(field), serialize_change_value(value)}
      end)
      |> Map.new()

    Map.put(metadata, "changes", serialized_changes)
  end

  defp serialize_change_value(value) when is_map(value) do
    value
    |> Enum.map(fn {k, v} -> {to_string(k), v} end)
    |> Map.new()
  end

  defp serialize_change_value(value) when is_list(value) do
    Enum.map(value, fn
      {label, change} when is_map(change) ->
        %{"field" => label, "old" => change.old, "new" => change.new}

      other ->
        other
    end)
  end

  defp serialize_change_value(value), do: value

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
  Records a media_file.upgraded event — Task 10's activity-trail record for
  the moment `Mydia.Upgrades.finalize_upgrade/1` actually replaces a file
  with a genuinely better one.

  ## Parameters
    - `new_file` - The `MediaFile` that won the comparison and stays.
    - `old_file` - The `MediaFile` that was trashed.
    - `media_item` - The top-level `MediaItem` both files were scored
      against (the movie itself, or the show for an episode).
    - `comparison` - `%{old_score:, new_score:, delta:, old_breakdown:,
      new_breakdown:, breakdown_delta:}`, as built by
      `Mydia.Upgrades.finalize_upgrade/1`.

  ## Examples

      iex> file_upgraded(new_file, old_file, media_item, comparison)
      :ok
  """
  def file_upgraded(new_file, old_file, media_item, comparison) do
    {resource_type, resource_id} = upgrade_resource(new_file, media_item)

    create_event_async(%{
      category: "media",
      type: "media_file.upgraded",
      actor_type: :job,
      actor_id: "upgrade_finalize",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :info,
      metadata: upgrade_metadata(new_file, old_file, media_item, comparison)
    })
  end

  @doc """
  Records a media_file.upgrade_rejected event — the counterpart to
  `file_upgraded/4` for when the candidate release did not actually deliver
  the quality it claimed. The originating release is blacklisted separately
  by `Mydia.Upgrades.finalize_upgrade/1`; this only records the trail.

  Takes the same shape as `file_upgraded/4`, except `new_file` is the file
  that got trashed here and `old_file` is the one that survived.

  `blacklisted?` distinguishes the two very different things a rejection can
  mean. A single-release rejection means the release lied and was blacklisted.
  A season-pack rejection usually means only that *this* episode was already
  good enough, so the pack is left grabbable - recording that here keeps the
  activity feed from labelling an honest release a liar.

  ## Examples

      iex> upgrade_rejected(new_file, old_file, media_item, comparison, true)
      :ok
  """
  def upgrade_rejected(new_file, old_file, media_item, comparison, blacklisted? \\ true) do
    {resource_type, resource_id} = upgrade_resource(new_file, media_item)

    metadata =
      new_file
      |> upgrade_metadata(old_file, media_item, comparison)
      |> Map.put("blacklisted", blacklisted?)

    create_event_async(%{
      category: "media",
      type: "media_file.upgrade_rejected",
      actor_type: :job,
      actor_id: "upgrade_finalize",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :warning,
      metadata: metadata
    })
  end

  # Episode-scoped upgrades point the event at the episode resource (mirrors
  # resource_type_for_search/1 below), so the activity timeline can navigate
  # straight to it; movie-scoped upgrades fall back to the media_item.
  defp upgrade_resource(%{episode_id: episode_id}, _media_item) when not is_nil(episode_id),
    do: {"episode", episode_id}

  defp upgrade_resource(_new_file, media_item), do: {"media_item", media_item.id}

  defp upgrade_metadata(new_file, old_file, media_item, comparison) do
    %{
      "title" => media_item.title,
      "media_type" => media_item.type,
      "new_file_id" => new_file.id,
      "old_file_id" => old_file.id,
      "new_resolution" => new_file.resolution,
      "old_resolution" => old_file.resolution,
      "new_codec" => new_file.codec,
      "old_codec" => old_file.codec,
      "old_score" => comparison.old_score,
      "new_score" => comparison.new_score,
      "delta" => comparison.delta,
      "old_breakdown" => stringify_breakdown(comparison.old_breakdown),
      "new_breakdown" => stringify_breakdown(comparison.new_breakdown),
      "breakdown_delta" => stringify_breakdown(comparison.breakdown_delta)
    }
  end

  # QualityProfile.score_media_file/2's breakdown map uses atom keys; every
  # other event helper in this module writes string-keyed metadata, so this
  # keeps that convention rather than relying on Jason's atom-key encoding.
  defp stringify_breakdown(breakdown) when is_map(breakdown) do
    Map.new(breakdown, fn {dimension, value} -> {to_string(dimension), value} end)
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
      |> maybe_add_failure_classification(opts)

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
  Records a download.stalled event — a recoverable *soft* stall detected by the
  `DownloadMonitor`. Unlike `download_failed/3` this is a warning: the download
  keeps occupying its episode and may auto-clear on resumed progress.

  ## Parameters
    - `download` - The Download struct
    - `message` - The stall message describing the soft-stall
    - `opts` - Additional options (e.g., media_item for context)
  """
  def download_stalled(download, message, opts \\ []) do
    media_item = opts[:media_item]

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
        "message" => message,
        "download_id" => download.id
      }
      |> maybe_add_media_context(media_item)

    create_event_async(%{
      category: "downloads",
      type: "download.stalled",
      actor_type: :system,
      actor_id: "download_monitor",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :warning,
      metadata: metadata
    })
  end

  @doc """
  Records a download.unstalled event — a soft-stall that recovered (the client
  reported progress, or an observation-gap reset cleared the stall). Ensures a
  recovered stall does not leave a `download.stalled` event as the last word.

  ## Parameters
    - `download` - The Download struct
    - `opts` - Additional options (e.g., media_item for context)
  """
  def download_unstalled(download, opts \\ []) do
    media_item = opts[:media_item]

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
      type: "download.unstalled",
      actor_type: :system,
      actor_id: "download_monitor",
      resource_type: resource_type,
      resource_id: resource_id,
      severity: :info,
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
  Records that Mydia declined to auto-reject a download because the media item
  had already hit `downloads.auto_reject_limit`.

  When the cap trips, the likely truth is that our own content detection is
  wrong and the torrent is fine, so the download is left alone to finish and
  import. This event is the operator's record that the detector misfired.
  """
  def download_auto_reject_suppressed(download, opts \\ []) do
    media_item = opts[:media_item]

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
      type: "download.auto_reject_suppressed",
      actor_type: :system,
      actor_id: "download_monitor",
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: metadata
    })
  end

  @doc """
  Records a download.cleared event.

  This event is recorded when a user explicitly clears a completed download
  from the Completed tab.

  ## Parameters
    - `download` - The Download struct
    - `actor_type` - :user or :system
    - `actor_id` - The ID of the actor
    - `opts` - Additional options (e.g., media_item for context)

  ## Examples

      iex> download_cleared(download, :user, user_id)
      :ok
  """
  def download_cleared(download, actor_type, actor_id, opts \\ []) do
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
      type: "download.cleared",
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
        title: "Added to library",
        description: "Breaking Bad (TV show)"
      }
  """
  def format_for_timeline(%Event{} = event) do
    presentation = Presentation.for_event(event)

    %{
      icon: presentation.icon,
      color: presentation.color,
      title: presentation.title,
      description: presentation.detail || "Event occurred"
    }
  end

  defp maybe_add_media_context(metadata, nil), do: metadata

  defp maybe_add_media_context(metadata, media_item) do
    Map.merge(metadata, %{
      "media_item_id" => media_item.id,
      "media_title" => media_item.title,
      "media_type" => media_item.type
    })
  end

  # The download client's own account of *why* a download failed (#237).
  #
  # Written only when the caller supplies it, so the DownloadMonitor paths
  # that detect a Mydia-side failure (missing from client, stuck import,
  # escalated stall) keep emitting exactly the metadata they always have.
  #
  # The caller passes an already-rendered slug rather than a category atom,
  # so this module stays independent of `FailureCategory` and the slug is
  # guaranteed to be the same string written to
  # `release_blacklist.failure_reason` beside it.
  defp maybe_add_failure_classification(metadata, opts) do
    metadata
    |> maybe_put_metadata("failure_category", opts[:failure_category])
    |> maybe_put_metadata("failure_detail", opts[:failure_detail])
  end

  defp maybe_put_metadata(metadata, _key, nil), do: metadata
  defp maybe_put_metadata(metadata, _key, ""), do: metadata
  defp maybe_put_metadata(metadata, key, value), do: Map.put(metadata, key, value)

  ## Search Event Helpers

  @doc """
  Records a search.completed event when a search finds results and initiates a download.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `metadata` - Search result metadata including:
      - `query` - The search query used
      - `results_count` - Total results found
      - `selected_release` - The release that was selected
      - `score` - The ranking score of the selected release
      - `breakdown` - Score breakdown details
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode search

  ## Examples

      iex> search_completed(media_item, %{
      ...>   "query" => "Breaking Bad S01E01",
      ...>   "results_count" => 15,
      ...>   "selected_release" => "Breaking.Bad.S01E01.1080p.BluRay",
      ...>   "score" => 850,
      ...>   "breakdown" => %{"quality" => 200, "seeders" => 150}
      ...> })
      :ok
  """
  def search_completed(media_item, metadata, opts \\ []) do
    episode = opts[:episode]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "search",
      type: "search.completed",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :info,
      metadata: base_metadata
    })
  end

  @doc """
  Records a search.no_results event when a search returns no results from indexers.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `metadata` - Search metadata including:
      - `query` - The search query used
      - `indexers_searched` - Number of indexers queried
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode search

  ## Examples

      iex> search_no_results(media_item, %{"query" => "Breaking Bad S01E01", "indexers_searched" => 3})
      :ok
  """
  def search_no_results(media_item, metadata, opts \\ []) do
    episode = opts[:episode]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "search",
      type: "search.no_results",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :warning,
      metadata: base_metadata
    })
  end

  @doc """
  Records a search.filtered_out event when results exist but all were filtered/rejected.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `metadata` - Search metadata including:
      - `query` - The search query used
      - `results_count` - Total results before filtering
      - `filter_stats` - Breakdown of why results were filtered
      - `top_rejections` - Sample of top rejected releases with reasons
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode search

  ## Examples

      iex> search_filtered_out(media_item, %{
      ...>   "query" => "Breaking Bad S01E01",
      ...>   "results_count" => 10,
      ...>   "filter_stats" => %{
      ...>     "low_seeders" => 5,
      ...>     "wrong_quality" => 3,
      ...>     "blocked_tags" => 2
      ...>   },
      ...>   "top_rejections" => [
      ...>     %{"title" => "Some.Release", "reason" => "low_seeders", "value" => 1}
      ...>   ]
      ...> })
      :ok
  """
  def search_filtered_out(media_item, metadata, opts \\ []) do
    episode = opts[:episode]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "search",
      type: "search.filtered_out",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :warning,
      metadata: base_metadata
    })
  end

  @doc """
  Records a search.error event when a search encounters an error.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `error_message` - Description of the error
    - `metadata` - Additional metadata (optional)
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode search

  ## Examples

      iex> search_error(media_item, "Connection timeout", %{"query" => "Breaking Bad S01E01"})
      :ok
  """
  def search_error(media_item, error_message, metadata \\ %{}, opts \\ []) do
    episode = opts[:episode]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "error_message" => error_message
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "search",
      type: "search.error",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :error,
      metadata: base_metadata
    })
  end

  @doc """
  Records a download.initiation_failed event when a download cannot be initiated.

  This is different from `download_failed/3` which is for downloads that were
  started but then failed during transfer.

  ## Parameters
    - `media_item` - The MediaItem the download was for
    - `reason` - The failure reason atom (e.g., :no_clients_configured, :duplicate_download)
    - `metadata` - Additional metadata including:
      - `selected_release` - The release that was selected
      - `query` - The search query used
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode download

  ## Examples

      iex> download_initiation_failed(media_item, :no_clients_configured, %{"selected_release" => "Movie.2024.1080p"})
      :ok
  """
  def download_initiation_failed(media_item, reason, metadata \\ %{}, opts \\ []) do
    episode = opts[:episode]

    error_message = format_download_error(reason)

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "error_reason" => format_download_error(reason),
        "error_message" => error_message
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "downloads",
      type: "download.failed",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :error,
      metadata: base_metadata
    })
  end

  defp format_download_error(:no_clients_configured), do: "No download clients configured"
  defp format_download_error(:duplicate_download), do: "Download already exists"
  # Covers episodes, season packs and movies alike, so the wording stays
  # media-type-agnostic.
  defp format_download_error(:already_have_files), do: "Files already exist"
  defp format_download_error(:no_suitable_client), do: "No suitable download client found"
  defp format_download_error(:client_error), do: "Download client error"

  defp format_download_error({:client_error, %Mydia.Downloads.Client.Error{} = error}),
    do: Mydia.Downloads.Client.Error.message(error)

  defp format_download_error({:client_error, reason}) when is_binary(reason), do: reason

  defp format_download_error({:client_error, reason}),
    do: "Download client error: #{inspect(reason)}"

  defp format_download_error(reason) when is_binary(reason), do: reason
  defp format_download_error(reason), do: inspect(reason)

  @doc """
  Records a search.started event when a search begins.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `metadata` - Search metadata including:
      - `query` - The search query used
      - `mode` - The search mode (e.g., "specific", "season", "show", "all_monitored")
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is a TV show episode search

  ## Examples

      iex> search_started(media_item, %{"query" => "Breaking Bad S01E01", "mode" => "specific"})
      :ok
  """
  def search_started(media_item, metadata, opts \\ []) do
    episode = opts[:episode]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type
      }
      |> Map.merge(metadata)
      |> maybe_add_episode_context(episode)

    create_event_async(%{
      category: "search",
      type: "search.started",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_search(episode),
      resource_id: resource_id_for_search(media_item, episode),
      severity: :info,
      metadata: base_metadata
    })
  end

  # Helper to determine actor_id based on media type
  defp search_actor_id(%{type: "movie"}), do: "movie_search"
  defp search_actor_id(%{type: "tv_show"}), do: "tv_show_search"
  defp search_actor_id(_), do: "search"

  # Helper to determine resource type based on episode presence
  defp resource_type_for_search(nil), do: "media_item"
  defp resource_type_for_search(_episode), do: "episode"

  # Helper to determine resource id based on episode presence
  defp resource_id_for_search(media_item, nil), do: media_item.id
  defp resource_id_for_search(_media_item, episode), do: episode.id

  # Helper to add episode context to metadata
  defp maybe_add_episode_context(metadata, nil), do: metadata

  defp maybe_add_episode_context(metadata, episode) do
    Map.merge(metadata, %{
      "episode_id" => episode.id,
      "season_number" => episode.season_number,
      "episode_number" => episode.episode_number
    })
  end

  ## Search Backoff Event Helpers

  @doc """
  Records a search.backoff_applied event when exponential backoff is applied to a resource.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `reason` - The reason for backoff (e.g., "no_results", "all_filtered")
    - `backoff_info` - Map with backoff details from Search.get_backoff_info/3
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is an episode-level backoff
      - `:season_number` - The season number if this is a season-level backoff

  ## Examples

      iex> search_backoff_applied(media_item, "no_results", %{failure_count: 1, next_eligible_at: ~U[...]})
      :ok
  """
  def search_backoff_applied(media_item, reason, backoff_info, opts \\ []) do
    episode = opts[:episode]
    season_number = opts[:season_number]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "reason" => reason,
        "failure_count" => backoff_info[:failure_count],
        "next_eligible_at" => format_datetime(backoff_info[:next_eligible_at]),
        "backoff_duration_seconds" => backoff_info[:backoff_duration_seconds]
      }
      |> maybe_add_episode_context(episode)
      |> maybe_add_season_context(season_number)

    create_event_async(%{
      category: "search",
      type: "search.backoff_applied",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_backoff(episode, season_number),
      resource_id: resource_id_for_backoff(media_item, episode),
      severity: :info,
      metadata: base_metadata
    })
  end

  @doc """
  Records a search.backoff_reset event when backoff is cleared after a successful download.

  ## Parameters
    - `media_item` - The MediaItem being searched for
    - `previous_count` - The failure count before reset
    - `opts` - Optional parameters:
      - `:episode` - The Episode if this is an episode-level reset
      - `:season_number` - The season number if this is a season-level reset

  ## Examples

      iex> search_backoff_reset(media_item, 3)
      :ok
  """
  def search_backoff_reset(media_item, previous_count, opts \\ []) do
    episode = opts[:episode]
    season_number = opts[:season_number]

    base_metadata =
      %{
        "title" => media_item.title,
        "media_type" => media_item.type,
        "previous_failure_count" => previous_count
      }
      |> maybe_add_episode_context(episode)
      |> maybe_add_season_context(season_number)

    create_event_async(%{
      category: "search",
      type: "search.backoff_reset",
      actor_type: :job,
      actor_id: search_actor_id(media_item),
      resource_type: resource_type_for_backoff(episode, season_number),
      resource_id: resource_id_for_backoff(media_item, episode),
      severity: :info,
      metadata: base_metadata
    })
  end

  # Helper to add season context to metadata
  defp maybe_add_season_context(metadata, nil), do: metadata

  defp maybe_add_season_context(metadata, season_number) do
    Map.put(metadata, "season_number", season_number)
  end

  # Helper to determine resource type for backoff events
  defp resource_type_for_backoff(episode, _season_number) when not is_nil(episode), do: "episode"

  defp resource_type_for_backoff(_episode, season_number) when not is_nil(season_number),
    do: "season"

  defp resource_type_for_backoff(_episode, _season_number), do: "media_item"

  # Helper to determine resource id for backoff events
  defp resource_id_for_backoff(_media_item, episode) when not is_nil(episode), do: episode.id
  defp resource_id_for_backoff(media_item, _episode), do: media_item.id

  # Helper to format datetime for metadata
  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)

  ## Playback Event Helpers (U1)

  @playback_actions ~w(started progressed paused finished unwatched)

  @doc """
  Records a `playback.<action>` event for a user's watch activity.

  `action` is one of `"started"`, `"progressed"`, `"paused"`, `"finished"`, or `"unwatched"`.
  `content_id` is the keyword tuple used throughout `Mydia.Playback`
  (`[media_item_id: id]` or `[episode_id: id]`); the user rides in the event
  envelope as `actor_id`. `meta` is a string-key map carrying playback context
  including `"origin"` (`"player"`, `"sync:<provider>"`, or `"plugin:<slug>"`),
  which the plugin dispatcher reads to suppress echo delivery (R14).

  Emission is throttled by the caller (`Mydia.Playback`, R19); this function
  always emits.

  ## Examples

      iex> playback_event("finished", user_id, [episode_id: id], %{"origin" => "player"})
      :ok
  """
  def playback_event(action, user_id, content_id, meta \\ %{})
      when action in @playback_actions and is_list(content_id) and is_map(meta) do
    {resource_type, resource_id, ids} = playback_resource(content_id)

    create_event_async(%{
      category: "playback",
      type: "playback.#{action}",
      actor_type: :user,
      actor_id: user_id,
      resource_type: resource_type,
      resource_id: resource_id,
      metadata: Map.merge(ids, meta)
    })
  end

  defp playback_resource(media_item_id: id),
    do: {"media_item", id, %{"media_item_id" => id}}

  defp playback_resource(episode_id: id),
    do: {"episode", id, %{"episode_id" => id}}
end
