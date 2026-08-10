defmodule Mydia.Indexers.Structs.ScoreBreakdown do
  @moduledoc """
  Represents the detailed scoring breakdown for a ranked search result.

  This struct provides compile-time safety for release ranking score breakdowns,
  showing how each factor contributed to the final score.

  ## Fields

  All base fields are required floats representing the score contribution:
  - `:quality` - Score from video quality (resolution, source, codec)
  - `:seeders` - Score from seeder count (logarithmic scale)
  - `:size` - Score from file size (bell curve preference)
  - `:age` - Score from release age (slight preference for newer)
  - `:title_match` - Score from title matching relevance to search query
  - `:tag_bonus` - Bonus points from preferred tags
  - `:custom_format_score` - Summed score of every matching custom format. A
    separate sort axis, deliberately NOT folded into `:total`.
  - `:total` - Final total score (sum of all components minus penalties)

  Penalty fields are optional floats `<= 0.0` (default `0.0`) recording the
  soft-penalty contributions subtracted from `:total`:
  - `:size_penalty` - Penalty for being outside the configured size range
  - `:seeder_penalty` - Penalty for low seeders / poor ratio
  - `:identity_penalty` - Penalty for episode/season identity mismatch or absence
  """

  @enforce_keys [
    :quality,
    :seeders,
    :size,
    :age,
    :title_match,
    :tag_bonus,
    :custom_format_score,
    :total
  ]
  defstruct [
    :quality,
    :seeders,
    :size,
    :age,
    :title_match,
    :tag_bonus,
    :custom_format_score,
    :total,
    size_penalty: 0.0,
    seeder_penalty: 0.0,
    identity_penalty: 0.0
  ]

  @type t :: %__MODULE__{
          quality: float(),
          seeders: float(),
          size: float(),
          age: float(),
          title_match: float(),
          tag_bonus: float(),
          custom_format_score: integer(),
          total: float(),
          size_penalty: float(),
          seeder_penalty: float(),
          identity_penalty: float()
        }

  @doc """
  Creates a new ScoreBreakdown struct.

  ## Examples

      iex> new(quality: 480.0, seeders: 200.0, size: 50.0, age: 25.0, title_match: 100.0, tag_bonus: 0.0, total: 855.0)
      %ScoreBreakdown{quality: 480.0, seeders: 200.0, size: 50.0, age: 25.0, title_match: 100.0, tag_bonus: 0.0, total: 855.0}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
