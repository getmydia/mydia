defmodule Mydia.Library.Structs.GroupedSeries do
  @moduledoc """
  Represents a TV series grouping in the import UI.

  This struct provides compile-time safety for series grouping data,
  containing all seasons and episodes for a TV series.

  ## Fields

  - `:title` - The series title
  - `:provider_id` - The metadata provider ID (e.g., TMDB ID)
  - `:year` - The series year (optional)
  - `:seasons` - List of GroupedSeason structs for this series
  """

  alias Mydia.Library.Structs.GroupedSeason

  @enforce_keys [:title, :provider_id, :seasons]
  defstruct [:title, :provider_id, :year, :seasons]

  @type t :: %__MODULE__{
          title: String.t(),
          provider_id: String.t(),
          year: integer() | nil,
          seasons: [GroupedSeason.t()]
        }

  @doc """
  Creates a new GroupedSeries struct.

  ## Examples

      iex> new(title: "Breaking Bad", provider_id: "1396", year: 2008, seasons: [])
      %GroupedSeries{title: "Breaking Bad", provider_id: "1396", year: 2008, seasons: []}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
