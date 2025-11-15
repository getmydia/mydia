defmodule Mydia.Library.Structs.GroupedSeason do
  @moduledoc """
  Represents a season grouping within a TV series in the import UI.

  This struct provides compile-time safety for season grouping data,
  containing all episodes for a specific season.

  ## Fields

  - `:season_number` - The season number (0 for specials)
  - `:episodes` - List of GroupedEpisode structs for this season
  """

  alias Mydia.Library.Structs.GroupedEpisode

  @enforce_keys [:season_number, :episodes]
  defstruct [:season_number, :episodes]

  @type t :: %__MODULE__{
          season_number: integer(),
          episodes: [GroupedEpisode.t()]
        }

  @doc """
  Creates a new GroupedSeason struct.

  ## Examples

      iex> new(season_number: 1, episodes: [])
      %GroupedSeason{season_number: 1, episodes: []}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
