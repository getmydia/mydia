defmodule Mydia.Indexers.Structs.RankedResult do
  @moduledoc """
  Represents a search result with its quality ranking score.

  This struct provides compile-time safety for ranked search results,
  combining the original search result with its calculated score and breakdown.

  ## Fields

  All fields are required:
  - `:result` - The original SearchResult struct
  - `:score` - The final calculated score (sum from breakdown)
  - `:breakdown` - Detailed ScoreBreakdown showing how the score was calculated
  """

  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.ScoreBreakdown

  @enforce_keys [:result, :score, :breakdown]
  defstruct [:result, :score, :breakdown]

  @type t :: %__MODULE__{
          result: SearchResult.t(),
          score: float(),
          breakdown: ScoreBreakdown.t()
        }

  @doc """
  Creates a new RankedResult struct.

  ## Examples

      iex> new(result: %SearchResult{}, score: 850.5, breakdown: %ScoreBreakdown{})
      %RankedResult{result: %SearchResult{}, score: 850.5, breakdown: %ScoreBreakdown{}}
  """
  def new(attrs) when is_map(attrs) or is_list(attrs) do
    struct!(__MODULE__, attrs)
  end
end
