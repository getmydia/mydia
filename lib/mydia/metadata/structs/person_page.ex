defmodule Mydia.Metadata.Structs.PersonPage do
  @moduledoc """
  One page of TMDB people: a person search or the popular people list.
  """

  alias Mydia.Metadata.Structs.PersonSearchResult

  @enforce_keys [:page, :total_pages]
  defstruct [:page, :total_pages, results: []]

  @type t :: %__MODULE__{
          results: [PersonSearchResult.t()],
          page: pos_integer(),
          total_pages: pos_integer()
        }

  @doc "Whether a later page exists."
  @spec more?(t()) :: boolean()
  def more?(%__MODULE__{page: page, total_pages: total}), do: page < total
end
