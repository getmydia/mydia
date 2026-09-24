defmodule Mydia.Library.Export.Row do
  @moduledoc """
  One media item in a library export. Field order here is the export's column
  order; `Mydia.Library.Export.columns/0` reads it from `@fields`.
  """

  @fields [
    :type,
    :title,
    :original_title,
    :year,
    :tmdb_id,
    :tvdb_id,
    :imdb_id,
    :metadata_source,
    :category,
    :monitored,
    :quality_profile,
    :library_path,
    :file_count,
    :size_bytes,
    :episode_count,
    :episodes_with_files,
    :added_at
  ]

  defstruct @fields

  @type t :: %__MODULE__{
          type: String.t(),
          title: String.t(),
          original_title: String.t() | nil,
          year: integer() | nil,
          tmdb_id: integer() | nil,
          tvdb_id: integer() | nil,
          imdb_id: String.t() | nil,
          metadata_source: String.t() | nil,
          category: String.t() | nil,
          monitored: boolean(),
          quality_profile: String.t() | nil,
          library_path: String.t() | nil,
          file_count: non_neg_integer(),
          size_bytes: non_neg_integer(),
          episode_count: non_neg_integer() | nil,
          episodes_with_files: non_neg_integer() | nil,
          added_at: DateTime.t()
        }

  @doc "Field names in export column order."
  @spec fields() :: [atom()]
  def fields, do: @fields
end
