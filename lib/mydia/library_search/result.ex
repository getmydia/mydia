defmodule Mydia.LibrarySearch.Result do
  @moduledoc """
  A single library-search hit, normalized across all four entity types.

  Image fields carry raw provider *paths*, not URLs. Building URLs is a web-layer
  concern and lives in `MydiaWeb.Schema.Resolvers.SearchResolver`.

  Field usage by type:

  | Type | subtitle | season/episode_number | parent_id | images |
  | --- | --- | --- | --- | --- |
  | `:movie`, `:tv_show` | `nil` | `nil` | `nil` | poster, backdrop |
  | `:episode` | parent show title | set | parent show id | still, plus parent poster/backdrop |
  | `:collection` | `"4 items"` | `nil` | `nil` | poster |
  """

  @enforce_keys [:id, :type, :title, :score]
  defstruct [
    :id,
    :type,
    :title,
    :score,
    :year,
    :subtitle,
    :season_number,
    :episode_number,
    :parent_id,
    :poster_path,
    :backdrop_path,
    :still_path
  ]

  @type result_type :: :movie | :tv_show | :episode | :collection

  @type t :: %__MODULE__{
          id: binary(),
          type: result_type(),
          title: String.t(),
          score: float(),
          year: integer() | nil,
          subtitle: String.t() | nil,
          season_number: integer() | nil,
          episode_number: integer() | nil,
          parent_id: binary() | nil,
          poster_path: String.t() | nil,
          backdrop_path: String.t() | nil,
          still_path: String.t() | nil
        }
end
