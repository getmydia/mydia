defmodule Mydia.Library.Prune.Decision do
  @moduledoc """
  The proposed outcome for one eligible group: which file to keep, which to
  trash, and why.
  """

  alias Mydia.Library.MediaFile
  alias Mydia.Library.Prune.Group

  @enforce_keys [:group, :keeper, :losers, :ranker, :reason]
  defstruct [:group, :keeper, :losers, :ranker, :reason]

  @type t :: %__MODULE__{
          group: Group.t(),
          keeper: MediaFile.t(),
          losers: [MediaFile.t()],
          ranker: :profile | :fallback,
          reason: String.t()
        }
end
