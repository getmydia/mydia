defmodule Mydia.Indexers.Structs.ScoreBreakdown do
  @moduledoc """
  Represents the detailed scoring breakdown for a ranked search result.

  This struct provides compile-time safety for release ranking score breakdowns,
  showing how each factor contributed to the final score.

  ## Fields

  All fields are required floats representing the score contribution:
  - `:quality` - Score from video quality (resolution, source, codec)
  - `:seeders` - Score from seeder count (logarithmic scale)
  - `:size` - Score from file size (bell curve preference)
  - `:age` - Score from release age (slight preference for newer)
  - `:tag_bonus` - Bonus points from preferred tags
  - `:total` - Final total score (sum of all components)
  """

  @enforce_keys [:quality, :seeders, :size, :age, :tag_bonus, :total]
  defstruct [:quality, :seeders, :size, :age, :tag_bonus, :total]

  @type t :: %__MODULE__{
          quality: float(),
          seeders: float(),
          size: float(),
          age: float(),
          tag_bonus: float(),
          total: float()
        }

  @doc """
  Creates a new ScoreBreakdown struct.

  ## Examples

      iex> new(quality: 480.0, seeders: 200.0, size: 50.0, age: 25.0, tag_bonus: 0.0, total: 755.0)
      %ScoreBreakdown{quality: 480.0, seeders: 200.0, size: 50.0, age: 25.0, tag_bonus: 0.0, total: 755.0}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
