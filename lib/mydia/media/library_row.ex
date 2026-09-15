defmodule Mydia.Media.LibraryRow do
  @moduledoc """
  One item in a library listing, with the per-item facts its card renders.

  Built by `Mydia.Media.LibraryListing`. `item` carries no associations: the
  status, resolutions, size, episode count and air dates that would otherwise
  need episodes, files and downloads preloaded are computed in SQL and stored
  here. `progress` is set only on rows that are rendered.
  """

  alias Mydia.Media.AvailabilityStatus
  alias Mydia.Media.MediaItem
  alias Mydia.Playback.Progress

  @enforce_keys [:id, :item, :status]
  defstruct [
    :id,
    :item,
    :status,
    :last_air_date,
    :next_air_date,
    :progress,
    resolutions: [],
    total_size: 0,
    episode_count: 0
  ]

  @type t :: %__MODULE__{
          id: binary(),
          item: MediaItem.t(),
          status: AvailabilityStatus.t(),
          resolutions: [String.t()],
          total_size: non_neg_integer(),
          episode_count: non_neg_integer(),
          last_air_date: Date.t() | nil,
          next_air_date: Date.t() | nil,
          progress: Progress.t() | nil
        }
end
