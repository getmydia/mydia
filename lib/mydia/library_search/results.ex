defmodule Mydia.LibrarySearch.Results do
  @moduledoc """
  The full result of a library search: the non-empty sections, in display order,
  plus the sum of their honest totals.
  """

  alias Mydia.LibrarySearch.Section

  @enforce_keys [:sections, :total_count]
  defstruct [:sections, :total_count]

  @type t :: %__MODULE__{sections: [Section.t()], total_count: non_neg_integer()}
end
