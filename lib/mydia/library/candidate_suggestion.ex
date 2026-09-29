defmodule Mydia.Library.CandidateSuggestion do
  @moduledoc """
  One ranked import candidate offered by "Find file" for a movie or episode.

  `reasons` is what the dialog shows as badges: `:same_provider` (the file was
  parked from this same title), `{:title, similarity}`, `{:year, year}` and
  `{:episode, season, episode}`.
  """

  @enforce_keys [:candidate, :score, :reasons]
  defstruct [:candidate, :score, :reasons]

  @type reason ::
          :same_provider
          | {:title, float()}
          | {:year, integer()}
          | {:episode, integer(), integer()}

  @type t :: %__MODULE__{
          candidate: Mydia.Library.ImportCandidate.t(),
          score: float(),
          reasons: [reason()]
        }
end
