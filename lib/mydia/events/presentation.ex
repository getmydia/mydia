defmodule Mydia.Events.Presentation do
  @moduledoc """
  The single source of truth for how an event is presented.

  Every event type recorded anywhere in the application has exactly one entry
  here, giving it an icon, a color, a short title, and whether it belongs in
  the global activity feed. `detail/1` builds the contextual half of the label
  from the event's metadata.

  Both consumers render from this module: the global activity feed
  (`MydiaWeb.ActivityLive.Index`) composes `"title: detail"`, and the per-media
  timeline (`Mydia.Events.format_for_timeline/1`) puts title and detail in its
  two slots.

  `Mydia.Events.Event.changeset/2` validates `:type` against `known_types/0`,
  so a new event type cannot be recorded until it is registered here.
  """

  alias Mydia.Events.Event

  defstruct [:type, :icon, :color, :title, :detail, feed?: true]

  @type t :: %__MODULE__{
          type: String.t(),
          icon: String.t(),
          color: String.t() | nil,
          title: String.t(),
          detail: String.t() | nil,
          feed?: boolean()
        }

  # A `color` of nil means "derive from severity at render time". Only
  # plugin.http_request uses it, because its severity varies per outcome. It
  # still needs an entry here because every recorded type must be registered
  # (see `Event.changeset/2`), but nothing renders it through this module
  # today: the admin plugins logs modal's Network tab (`net_row/1` in
  # `MydiaWeb.AdminPluginsLive.Components`) renders its own columns straight
  # from `event.metadata` and derives its row class from `event.severity`
  # directly, without calling `for_event/1`.
  #
  # Entries are plain maps, not %__MODULE__{} structs, because Elixir cannot
  # construct a struct literal of the module currently being compiled inside
  # a module attribute (only inside a function body, where evaluation is
  # deferred until after compilation finishes). `for_event/1` converts the
  # matched entry into a real %__MODULE__{} struct at call time.
  @entries [
    # media_item.*
    %{
      type: "media_item.added",
      icon: "hero-plus-circle",
      color: "text-info",
      title: "Added to library"
    },
    %{
      type: "media_item.updated",
      icon: "hero-arrow-path",
      color: "text-info",
      title: "Updated"
    },
    %{
      type: "media_item.removed",
      icon: "hero-trash",
      color: "text-error",
      title: "Removed from library"
    },
    %{
      type: "media_item.monitoring_changed",
      icon: "hero-eye",
      color: "text-warning",
      title: "Monitoring changed"
    },
    %{
      type: "media_item.episodes_refreshed",
      icon: "hero-arrow-path",
      color: "text-info",
      title: "Episodes refreshed"
    },

    # media_file.*
    %{
      type: "media_file.imported",
      icon: "hero-document-check",
      color: "text-success",
      title: "File imported"
    },
    %{
      type: "media_file.upgraded",
      icon: "hero-arrow-up-circle",
      color: "text-success",
      title: "Quality upgraded"
    },
    %{
      type: "media_file.upgrade_rejected",
      icon: "hero-x-circle",
      color: "text-warning",
      title: "Upgrade rejected"
    },

    # download.*
    %{
      type: "download.initiated",
      icon: "hero-arrow-down-tray",
      color: "text-primary",
      title: "Download started"
    },
    %{
      type: "download.completed",
      icon: "hero-check-circle",
      color: "text-success",
      title: "Download completed"
    },
    %{
      type: "download.failed",
      icon: "hero-x-circle",
      color: "text-error",
      title: "Download failed"
    },
    %{
      type: "download.cancelled",
      icon: "hero-minus-circle",
      color: "text-warning",
      title: "Download cancelled"
    },
    %{
      type: "download.paused",
      icon: "hero-pause-circle",
      color: "text-warning",
      title: "Download paused"
    },
    %{
      type: "download.resumed",
      icon: "hero-play-circle",
      color: "text-info",
      title: "Download resumed"
    },
    %{
      type: "download.stalled",
      icon: "hero-exclamation-triangle",
      color: "text-warning",
      title: "Download stalled"
    },
    %{
      type: "download.unstalled",
      icon: "hero-arrow-path",
      color: "text-success",
      title: "Download recovered"
    },
    %{
      type: "download.cleared",
      icon: "hero-archive-box-x-mark",
      color: "text-base-content/60",
      title: "Download cleared"
    },

    # job.*
    %{
      type: "job.executed",
      icon: "hero-cog-6-tooth",
      color: "text-success",
      title: "Job executed"
    },
    %{
      type: "job.failed",
      icon: "hero-exclamation-triangle",
      color: "text-error",
      title: "Job failed"
    },

    # search.*
    %{
      type: "search.started",
      icon: "hero-magnifying-glass",
      color: "text-info",
      title: "Search started"
    },
    %{
      type: "search.completed",
      icon: "hero-magnifying-glass",
      color: "text-success",
      title: "Search completed"
    },
    %{
      type: "search.no_results",
      icon: "hero-magnifying-glass",
      color: "text-warning",
      title: "No results"
    },
    %{
      type: "search.filtered_out",
      icon: "hero-funnel",
      color: "text-warning",
      title: "All results filtered out"
    },
    %{
      type: "search.error",
      icon: "hero-exclamation-circle",
      color: "text-error",
      title: "Search failed"
    },
    %{
      type: "search.backoff_applied",
      icon: "hero-clock",
      color: "text-warning",
      title: "Search backoff applied"
    },
    %{
      type: "search.backoff_reset",
      icon: "hero-arrow-path",
      color: "text-success",
      title: "Search backoff cleared"
    },

    # plugin.*
    %{
      type: "plugin.http_request",
      icon: "hero-globe-alt",
      color: nil,
      title: "Plugin request",
      feed?: false
    },
    %{
      type: "plugin.update_available",
      icon: "hero-arrow-up-circle",
      color: "text-info",
      title: "Plugin update available"
    },

    # playback.*
    %{
      type: "playback.started",
      icon: "hero-play",
      color: "text-info",
      title: "Playback started"
    },
    %{
      type: "playback.progressed",
      icon: "hero-forward",
      color: "text-info",
      title: "Playback progressed"
    },
    %{
      type: "playback.paused",
      icon: "hero-pause",
      color: "text-info",
      title: "Playback paused"
    },
    %{
      type: "playback.finished",
      icon: "hero-check-circle",
      color: "text-success",
      title: "Playback finished"
    }
  ]

  @by_type Map.new(@entries, &{&1.type, &1})
  @known_types Enum.map(@entries, & &1.type)
  @feed_hidden_types @entries
                     |> Enum.reject(&Map.get(&1, :feed?, true))
                     |> Enum.map(& &1.type)

  @doc "Every registered event type. `Event.changeset/2` validates against this."
  @spec known_types() :: [String.t()]
  def known_types, do: @known_types

  @doc "Types that are recorded and viewable elsewhere, but excluded from the global feed."
  @spec feed_hidden_types() :: [String.t()]
  def feed_hidden_types, do: @feed_hidden_types

  @doc """
  Resolves an event to its presentation, with `:color` and `:detail` filled in.

  Unregistered types fall back to a humanized key plus severity-derived icon and
  color. That path is not dead code: rows already in the `events` table may
  carry types no longer recorded anywhere in `lib/`.
  """
  @spec for_event(Event.t()) :: t()
  def for_event(%Event{type: type, severity: severity} = event) do
    %__MODULE__{} =
      base =
      case Map.get(@by_type, type) do
        nil -> %__MODULE__{type: type, icon: severity_icon(severity), title: humanize_type(type)}
        entry -> struct!(__MODULE__, entry)
      end

    %__MODULE__{
      base
      | color: base.color || severity_color(severity),
        detail: detail(event)
    }
  end

  @doc """
  Builds the contextual half of an event's label from its metadata.

  Returns nil when there is nothing useful to say, which consumers render as
  title-only.
  """
  @spec detail(Event.t()) :: String.t() | nil
  def detail(%Event{type: "media_item.added", metadata: metadata}) do
    case media_type_label(metadata["media_type"]) do
      nil -> title_of(metadata)
      label -> "#{title_of(metadata)} (#{label})"
    end
  end

  def detail(%Event{type: "media_item.updated", metadata: metadata}) do
    base =
      case metadata["reason"] do
        nil -> title_of(metadata)
        reason -> "#{title_of(metadata)}, #{String.downcase(reason)}"
      end

    case changes_summary(metadata["changes"]) do
      nil -> base
      summary -> "#{base} (#{summary})"
    end
  end

  def detail(%Event{type: "media_item.removed", metadata: metadata}), do: title_of(metadata)

  def detail(%Event{type: "media_item.monitoring_changed", metadata: metadata}) do
    state = if metadata["monitored"], do: "enabled", else: "disabled"
    "#{title_of(metadata)}, monitoring #{state}"
  end

  def detail(%Event{type: "media_item.episodes_refreshed", metadata: metadata}) do
    count = metadata["episode_count"] || 0
    suffix = if count == 1, do: "episode", else: "episodes"
    "#{title_of(metadata)}, #{count} #{suffix}"
  end

  def detail(%Event{type: "media_file.imported", metadata: metadata}) do
    title = metadata["media_title"] || "Unknown"

    case metadata["resolution"] || metadata["file_path"] do
      nil -> title
      "unknown" -> title
      descriptor -> "#{title} #{descriptor}"
    end
  end

  def detail(%Event{type: "media_file.upgraded", metadata: metadata}) do
    base =
      "#{title_of(metadata)}, #{resolution_of(metadata, "old")} to #{resolution_of(metadata, "new")}"

    case metadata["delta"] do
      nil -> base
      delta -> "#{base} (score +#{delta})"
    end
  end

  def detail(%Event{type: "media_file.upgrade_rejected", metadata: metadata}) do
    base =
      "#{title_of(metadata)}, kept #{resolution_of(metadata, "old")} over #{resolution_of(metadata, "new")}"

    if metadata["blacklisted"], do: "#{base}, release blacklisted", else: base
  end

  @plain_download_types ~w(
    download.initiated download.completed download.cancelled
    download.paused download.resumed download.unstalled
  )

  def detail(%Event{type: type, metadata: metadata}) when type in @plain_download_types,
    do: title_of(metadata)

  def detail(%Event{type: "download.stalled", metadata: metadata}) do
    case metadata["message"] do
      nil -> title_of(metadata)
      message -> "#{title_of(metadata)} (#{message})"
    end
  end

  def detail(%Event{type: "download.cleared", metadata: metadata}) do
    case metadata["download_client"] do
      nil -> title_of(metadata)
      client -> "#{title_of(metadata)} (#{client})"
    end
  end

  def detail(%Event{type: "download.failed", metadata: metadata}) do
    subject = title_of(metadata) <> episode_part(metadata)
    error = metadata["error_message"] || "Unknown error"

    case metadata["selected_release"] do
      nil -> "#{subject} (#{error})"
      release -> "#{subject}: #{release} (#{error})"
    end
  end

  def detail(%Event{type: "job.executed", metadata: metadata}) do
    job = metadata["job_name"] || "Unknown job"

    [
      job,
      metadata["items_processed"] && "processed #{metadata["items_processed"]} items",
      metadata["duration_ms"] && "in #{metadata["duration_ms"]}ms"
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
  end

  def detail(%Event{type: "job.failed", metadata: metadata}) do
    job = metadata["job_name"] || "Unknown job"
    "#{job} (#{metadata["error_message"] || "Unknown error"})"
  end

  def detail(%Event{type: type, metadata: metadata})
      when type in ["search.started", "search.no_results"],
      do: search_subject(metadata)

  def detail(%Event{type: "search.completed", metadata: metadata}) do
    count = metadata["results_count"] || 0
    suffix = if count == 1, do: "result", else: "results"
    base = "#{search_subject(metadata)}, #{count} #{suffix}"

    case metadata["selected_release"] do
      nil -> base
      release -> "#{base}, selected #{release}"
    end
  end

  def detail(%Event{type: "search.filtered_out", metadata: metadata}) do
    "#{search_subject(metadata)}, #{metadata["results_count"] || 0} rejected"
  end

  def detail(%Event{type: "search.error", metadata: metadata}) do
    "#{search_subject(metadata)} (#{metadata["error_message"] || "Unknown error"})"
  end

  def detail(%Event{type: "search.backoff_applied", metadata: metadata}) do
    "#{search_subject(metadata)} (#{backoff_resource_type(metadata)}), " <>
      "#{backoff_reason(metadata["reason"])}, attempt ##{metadata["failure_count"] || 1}, " <>
      "next search #{next_eligible(metadata["next_eligible_at"])}"
  end

  def detail(%Event{type: "search.backoff_reset", metadata: metadata}) do
    count = metadata["previous_failure_count"] || 0
    suffix = if count == 1, do: "attempt", else: "attempts"

    "#{search_subject(metadata)} (#{backoff_resource_type(metadata)}), " <>
      "backoff cleared after #{count} failed #{suffix}"
  end

  def detail(%Event{type: "plugin.http_request", metadata: metadata}) do
    slug = metadata["slug"] || "unknown"
    method = metadata["method"] || "GET"
    host = metadata["host"] || "unknown host"

    call = "#{slug}: #{method} #{host}"

    case Enum.reject(
           [metadata["status"], metadata["duration_ms"] && "#{metadata["duration_ms"]}ms"],
           &is_nil/1
         ) do
      [] -> call
      parts -> "#{call} (#{Enum.join(parts, ", ")})"
    end
  end

  def detail(%Event{type: "plugin.update_available", metadata: metadata}) do
    slug = metadata["slug"] || "unknown"
    current = metadata["current_version"] || "unknown"
    latest = metadata["latest_version"] || "unknown"
    "#{slug} #{current} to #{latest}"
  end

  @playback_types ~w(playback.started playback.progressed playback.paused playback.finished)

  def detail(%Event{type: type, metadata: metadata}) when type in @playback_types do
    [
      metadata["completion_percentage"] && "#{metadata["completion_percentage"]}% watched",
      metadata["origin"] && "from #{metadata["origin"]}"
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  def detail(%Event{} = event) do
    metadata = event.metadata || %{}
    metadata["title"] || metadata["description"]
  end

  defp severity_icon(:error), do: "hero-exclamation-circle"
  defp severity_icon(:warning), do: "hero-exclamation-triangle"
  defp severity_icon(_), do: "hero-information-circle"

  defp severity_color(:error), do: "text-error"
  defp severity_color(:warning), do: "text-warning"
  defp severity_color(_), do: "text-info"

  defp humanize_type(type) do
    type
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  defp title_of(metadata), do: metadata["title"] || "Unknown"

  # A missing or unrecognized media_type (nil, or a deprecated type like
  # music/books) produces no parenthetical rather than guessing "TV show".
  defp media_type_label("movie"), do: "movie"
  defp media_type_label("tv_show"), do: "TV show"
  defp media_type_label(_), do: nil

  defp resolution_of(metadata, prefix), do: metadata["#{prefix}_resolution"] || "unknown"

  # Short summary of a media_item.updated changeset, for the one-line label.
  # The expandable per-field breakdown stays in the LiveView.
  defp changes_summary(nil), do: nil
  defp changes_summary(changes) when changes == %{}, do: nil

  defp changes_summary(changes) do
    metadata_fields =
      case Map.get(changes, "metadata_fields") do
        fields when is_list(fields) -> summarize_fields(fields)
        _ -> []
      end

    simple_fields =
      changes
      |> Map.take(["title", "original_title", "year"])
      |> Map.keys()

    case metadata_fields ++ simple_fields do
      [] -> nil
      parts -> Enum.join(parts, ", ")
    end
  end

  defp summarize_fields(fields) do
    names = fields |> Enum.take(3) |> Enum.map(&field_name/1)
    remaining = length(fields) - 3

    if remaining > 0 do
      ["#{Enum.join(names, ", ")} +#{remaining} more"]
    else
      [Enum.join(names, ", ")]
    end
  end

  defp field_name(%{"field" => field}), do: field
  defp field_name(field) when is_binary(field), do: field
  defp field_name(_), do: "field"

  # Renders " S01E02" or " S01" when the metadata carries season and episode.
  defp episode_part(metadata) do
    season = metadata["season_number"]
    episode = metadata["episode_number"]

    cond do
      season && episode ->
        " S#{pad(season)}E#{pad(episode)}"

      season ->
        " S#{pad(season)}"

      true ->
        ""
    end
  end

  defp pad(number), do: String.pad_leading("#{number}", 2, "0")

  defp search_subject(metadata), do: title_of(metadata) <> episode_part(metadata)

  defp backoff_reason("no_results"), do: "no results found"
  defp backoff_reason("all_filtered"), do: "all results filtered out"
  defp backoff_reason(reason) when is_binary(reason), do: reason
  defp backoff_reason(_), do: "search failed"

  defp backoff_resource_type(metadata) do
    cond do
      metadata["episode_id"] ->
        "episode"

      metadata["season_number"] && !metadata["episode_number"] ->
        "season #{metadata["season_number"]}"

      true ->
        "show"
    end
  end

  defp next_eligible(nil), do: "unknown"

  defp next_eligible(iso_string) when is_binary(iso_string) do
    case DateTime.from_iso8601(iso_string) do
      {:ok, dt, _offset} -> relative_future_time(dt)
      _ -> iso_string
    end
  end

  defp next_eligible(_), do: "unknown"

  defp relative_future_time(dt) do
    diff_seconds = DateTime.diff(dt, DateTime.utc_now())

    cond do
      diff_seconds <= 0 -> "now"
      diff_seconds < 60 -> "in #{pluralize_unit(diff_seconds, "second")}"
      diff_seconds < 3600 -> "in #{pluralize_unit(div(diff_seconds, 60), "minute")}"
      # A float always reads naturally as plural ("1.0 hours"), so no singular
      # branch is needed here.
      diff_seconds < 86_400 -> "in #{Float.round(diff_seconds / 3600, 1)} hours"
      true -> "in #{pluralize_unit(div(diff_seconds, 86_400), "day")}"
    end
  end

  defp pluralize_unit(1, unit), do: "1 #{unit}"
  defp pluralize_unit(count, unit), do: "#{count} #{unit}s"
end
