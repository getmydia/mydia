defmodule Mydia.Media.FranchiseEntry do
  @moduledoc """
  One movie in a franchise, joined against the library.

  `release_date` is carried alongside `year` because entries are ordered by full
  date, not by year alone.
  """

  @enforce_keys [:tmdb_id]
  defstruct [
    :tmdb_id,
    :title,
    :year,
    :release_date,
    :poster_path,
    :media_item_id,
    in_library?: false,
    current?: false
  ]

  @type t :: %__MODULE__{
          tmdb_id: integer(),
          title: String.t() | nil,
          year: integer() | nil,
          release_date: Date.t() | nil,
          poster_path: String.t() | nil,
          media_item_id: binary() | nil,
          in_library?: boolean(),
          current?: boolean()
        }
end
