defmodule Mydia.Config.Schema.MediaChangeset do
  @moduledoc """
  Changeset for the `media` section of `Mydia.Config.Schema`.

  `minimum_availability` says when automatic search may start looking for a
  movie; see `Mydia.Media.MinimumAvailability`.
  """

  import Ecto.Changeset

  alias Mydia.Config.Schema

  @minimum_availability_levels ~w(announced in_cinemas released)

  @doc """
  Valid `media.minimum_availability` levels, also accepted as a movie's own
  override (`Mydia.Media.MediaItem.minimum_availability`).
  """
  @spec minimum_availability_levels() :: [String.t()]
  def minimum_availability_levels, do: @minimum_availability_levels

  @spec changeset(Ecto.Schema.t() | Ecto.Changeset.t(), map()) :: Ecto.Changeset.t()
  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [
      :movies_path,
      :tv_path,
      :movies_auto_organize,
      :tv_auto_organize,
      :auto_search_on_add,
      :minimum_availability,
      :default_season_monitoring,
      :monitor_by_default,
      :season_refresh_threshold_hours,
      :completed_show_refresh_threshold_hours,
      :trash_retention_days
    ])
    |> validate_required([:minimum_availability])
    |> validate_inclusion(:minimum_availability, @minimum_availability_levels)
    # movies_path and tv_path are optional legacy fields
    |> validate_number(:season_refresh_threshold_hours, greater_than: 0)
    |> validate_number(:completed_show_refresh_threshold_hours, greater_than: 0)
    |> validate_inclusion(:default_season_monitoring, Schema.season_monitoring_values())
    # Required as well as non-negative: `validate_number/3` skips nil, and an
    # explicit null in the YAML or the overlay would reach
    # `Library.purge_old_trashed_media_files/1`, where `-nil` crashes the
    # daily `TrashCleanup` run rather than failing at config load.
    |> validate_required([:trash_retention_days])
    |> validate_number(:trash_retention_days, greater_than_or_equal_to: 0)
  end
end
