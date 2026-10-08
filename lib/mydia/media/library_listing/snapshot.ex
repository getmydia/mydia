defmodule Mydia.Media.LibraryListing.Snapshot do
  @moduledoc """
  One evaluation of a library listing: the order of every matching item, and
  the rows for the first few of them.

  `ids` is what later batches slice from, through `LibraryListing.rows/3`, so
  a batch costs one page of aggregates rather than the whole library. The
  figures (`visible_ids`, `total_size`, `description_match_start_id`) cover
  every match, not only `rows`.
  """

  alias Mydia.Media.LibraryRow

  defstruct ids: [],
            rows: [],
            visible_ids: MapSet.new(),
            total_size: 0,
            description_match_start_id: nil,
            empty?: true

  @type t :: %__MODULE__{
          ids: [binary()],
          rows: [LibraryRow.t()],
          visible_ids: MapSet.t(binary()),
          total_size: non_neg_integer(),
          description_match_start_id: binary() | nil,
          empty?: boolean()
        }
end
