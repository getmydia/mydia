defmodule Mydia.Media.FranchiseEntry do
  @moduledoc """
  One movie in a franchise, joined against the library.

  `release_date` is carried alongside `year` because entries are ordered by full
  date, not by year alone.

  `vote_average` and `monitored` exist so the entry can be rendered by the shared
  media rail, which draws a star badge and an ownership dot from them.
  """

  @enforce_keys [:tmdb_id]
  defstruct [
    :tmdb_id,
    :title,
    :year,
    :release_date,
    :poster_path,
    :media_item_id,
    :vote_average,
    in_library?: false,
    monitored: false,
    current?: false
  ]

  @type t :: %__MODULE__{
          tmdb_id: integer(),
          title: String.t() | nil,
          year: integer() | nil,
          release_date: Date.t() | nil,
          poster_path: String.t() | nil,
          media_item_id: binary() | nil,
          vote_average: float() | nil,
          in_library?: boolean(),
          monitored: boolean(),
          current?: boolean()
        }
end
