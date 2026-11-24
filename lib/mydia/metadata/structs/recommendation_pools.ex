defmodule Mydia.Metadata.Structs.RecommendationPools do
  @moduledoc """
  TMDB's two related-title pools for one movie or show, as one details response
  carries them.

  `recommendations` is TMDB's curated list and what the rail shows.
  `similar` (genre and keyword overlap) is a weaker signal, kept only to top up
  a rail that a restricted viewer's filter has thinned. Each pool holds at
  most TMDB's first page of twenty.
  """

  alias Mydia.Metadata.Structs.SearchResult

  defstruct recommendations: [], similar: []

  @type t :: %__MODULE__{
          recommendations: [SearchResult.t()],
          similar: [SearchResult.t()]
        }
end
