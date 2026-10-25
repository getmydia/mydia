defmodule Mydia.Media.LibraryListing.Snapshot do
  @moduledoc """
  One evaluation of a library listing: the order of every matching item, and
  the rows for the first few of them.

  `ids` is what later batches slice from, through `LibraryListing.rows/3`, so
  a batch costs one page of aggregates rather than the whole library. The
  figures (`visible_ids`, `total_size`, `description_match_start_id`) cover
  every match, not only `rows`.

  `rows` start at `start` in `ids`. `letter_offsets` maps each initial (`"#"`,
  `"a"`..`"z"`) to its first index in `ids`, and is only filled for a title sort
  with no search.
  """

  alias Mydia.Media.LibraryRow

  defstruct ids: [],
            rows: [],
            start: 0,
            letter_offsets: %{},
            visible_ids: MapSet.new(),
            total_size: 0,
            description_match_start_id: nil,
            empty?: true

  @type t :: %__MODULE__{
          ids: [binary()],
          rows: [LibraryRow.t()],
          start: non_neg_integer(),
          letter_offsets: %{String.t() => non_neg_integer()},
          visible_ids: MapSet.t(binary()),
          total_size: non_neg_integer(),
          description_match_start_id: binary() | nil,
          empty?: boolean()
        }
end
