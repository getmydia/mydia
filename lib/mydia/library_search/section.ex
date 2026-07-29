defmodule Mydia.LibrarySearch.Section do
  @moduledoc """
  One grouped section of library-search results.

  `:total_count` is the true number of matching rows, not the length of
  `:results`, which is capped by the per-section limit. Section headers and
  "Show all" affordances in the player both depend on the honest count.
  """

  alias Mydia.LibrarySearch.Result

  @enforce_keys [:type, :results, :total_count]
  defstruct [:type, :results, :total_count]

  @type t :: %__MODULE__{
          type: Result.result_type(),
          results: [Result.t()],
          total_count: non_neg_integer()
        }
end
