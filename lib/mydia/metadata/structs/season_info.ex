defmodule Mydia.Metadata.Structs.SeasonInfo do
  @moduledoc """
  Represents basic season information from TMDB metadata.

  This is different from SeasonData which includes full episode details.
  SeasonInfo is used in the seasons list from the main media metadata response.
  """

  @enforce_keys [:season_number]
  defstruct [
    # Required fields
    :season_number,
    # Optional fields
    :name,
    :overview,
    :air_date,
    :episode_count,
    :poster_path
  ]

  @type t :: %__MODULE__{
          season_number: integer(),
          name: String.t() | nil,
          overview: String.t() | nil,
          air_date: String.t() | nil,
          episode_count: integer() | nil,
          poster_path: String.t() | nil
        }

  @doc """
  Creates a SeasonInfo struct from a raw API response map.

  ## Examples

      iex> from_api_response(%{"season_number" => 1, "name" => "Season 1", ...})
      %SeasonInfo{season_number: 1, name: "Season 1", ...}
  """
  def from_api_response(data) when is_map(data) do
    %__MODULE__{
      season_number: data["season_number"],
      name: data["name"],
      overview: data["overview"],
      air_date: data["air_date"],
      episode_count: data["episode_count"],
      poster_path: data["poster_path"]
    }
  end
end
