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
