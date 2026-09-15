defmodule Mydia.Media.AvailabilityStatus do
  @moduledoc """
  Availability of a media item or episode, held separately from whether it is monitored.

  `state` answers "do we have this?" and `monitored` answers "are we trying to get it?".
  Collapsing the two into a single `:not_monitored` atom is what hid the missing badge
  from unmonitored items, so they stay in separate fields and the presentation helpers
  all take the whole struct rather than a bare state atom.
  """

  @type state :: :missing | :partial | :downloaded | :downloading | :upcoming | :tba

  @type t :: %__MODULE__{
          state: state(),
          monitored: boolean(),
          file_count: non_neg_integer() | nil,
          downloaded: non_neg_integer() | nil,
          total: non_neg_integer() | nil
        }

  @enforce_keys [:state, :monitored]
  defstruct [:state, :monitored, :file_count, :downloaded, :total]

  @typedoc """
  Episode counts for one scope of a show: every episode, or only the monitored ones.

  `downloaded` counts episodes with at least one version file, `downloading` those
  with an active download, `upcoming` those whose air date is after today.
  """
  @type episode_counts :: %{
          total: non_neg_integer(),
          downloaded: non_neg_integer(),
          downloading: non_neg_integer(),
          upcoming: non_neg_integer()
        }

  @doc """
  Availability of a movie from its version file count and whether a download is active.

  `Mydia.Media.get_media_status/1` counts these from preloads and
  `Mydia.Media.LibraryListing` counts them in SQL. Both call this, so the two can
  never classify the same movie differently.
  """
  @spec for_movie(non_neg_integer(), boolean(), boolean()) :: t()
  def for_movie(file_count, downloading?, monitored) do
    state =
      cond do
        file_count > 0 -> :downloaded
        downloading? -> :downloading
        true -> :missing
      end

    %__MODULE__{state: state, monitored: monitored, file_count: file_count}
  end

  @doc """
  Availability of a show from its episode counts.

  Episodes are classified over the monitored ones when there are any, and over every
  episode when there are none, so the x/y counts always have a meaningful denominator.

  A monitored show with every episode unmonitored is not chasing anything, so it
  renders muted. A show with no episodes at all is a different case: nothing
  contradicts the show's own flag yet, so a freshly added show awaiting metadata
  stays un-muted.
  """
  @spec for_series(episode_counts(), episode_counts(), boolean()) :: t()
  def for_series(all, monitored, show_monitored) do
    scope = if monitored.total == 0, do: all, else: monitored

    state =
      cond do
        scope.total > 0 and scope.downloaded == scope.total -> :downloaded
        scope.downloading > 0 -> :downloading
        scope.total > 0 and scope.upcoming == scope.total -> :upcoming
        scope.downloaded > 0 -> :partial
        true -> :missing
      end

    %__MODULE__{
      state: state,
      monitored: show_monitored and (all.total == 0 or monitored.total > 0),
      downloaded: scope.downloaded,
      total: scope.total
    }
  end

  @colors %{
    downloaded: "badge-success",
    downloading: "badge-info",
    missing: "badge-error",
    partial: "badge-warning",
    upcoming: "badge-outline",
    tba: "badge-warning"
  }

  @icons %{
    downloaded: "hero-check-circle",
    downloading: "hero-arrow-down-tray",
    missing: "hero-exclamation-circle",
    partial: "hero-minus-circle",
    upcoming: "hero-clock",
    tba: "hero-question-mark-circle"
  }

  @labels %{
    downloaded: "Downloaded",
    downloading: "Downloading",
    missing: "Missing",
    partial: "Partial",
    upcoming: "Upcoming",
    tba: "TBA"
  }

  @muted "badge-outline opacity-60"

  @doc """
  DaisyUI badge classes for the status.

  An unmonitored item keeps the hue of its state and drops to a faded outline, so
  "missing" still reads as missing without implying anything is chasing it.
  """
  @spec color(t()) :: String.t()
  def color(%__MODULE__{state: state, monitored: true}), do: Map.fetch!(@colors, state)

  def color(%__MODULE__{state: :upcoming, monitored: false}), do: @muted

  def color(%__MODULE__{state: state, monitored: false}),
    do: Map.fetch!(@colors, state) <> " " <> @muted

  @doc """
  HeroIcon name for the status. Monitoring does not change the icon.
  """
  @spec icon(t()) :: String.t()
  def icon(%__MODULE__{state: state}), do: Map.fetch!(@icons, state)

  @doc """
  Human-readable label, used as the badge tooltip.

  Unmonitored items get a suffix so the faded badge explains itself.
  """
  @spec label(t()) :: String.t()
  def label(%__MODULE__{state: state, monitored: true}), do: Map.fetch!(@labels, state)

  def label(%__MODULE__{state: state, monitored: false}),
    do: Map.fetch!(@labels, state) <> " · Not monitored"
end
