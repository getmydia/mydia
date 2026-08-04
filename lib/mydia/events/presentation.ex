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
  # plugin.http_request uses it, because its severity varies per outcome.
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
end
