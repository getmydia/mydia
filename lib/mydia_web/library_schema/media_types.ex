defmodule MydiaWeb.LibrarySchema.MediaTypes do
  @moduledoc """
  Media types for the Library API.
  """

  use Absinthe.Schema.Notation

  @desc "Whether a media item is available, arriving, or absent"
  object :availability_status do
    field :state, non_null(:availability_state)
    field :monitored, non_null(:boolean)
    field :file_count, :integer
    field :downloaded, :integer
    field :total, :integer
  end

  @desc "One episode of a TV show"
  object :episode do
    field :id, non_null(:id)
    field :season_number, non_null(:integer)
    field :episode_number, non_null(:integer)
    field :title, :string
    field :air_date, :date
    field :monitored, non_null(:boolean)

    field :has_file, non_null(:boolean),
      description: "Whether any untrashed, non-extra file covers this episode"
  end

  @desc "A movie or TV show in the library"
  object :media_item do
    field :id, non_null(:id)
    field :type, non_null(:media_type)
    field :title, non_null(:string)
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string
    field :monitored, non_null(:boolean)
    field :quality_profile, :quality_profile
    field :status, non_null(:availability_status)
    field :added_at, non_null(:datetime)
    field :updated_at, non_null(:datetime)

    field :episodes, non_null(list_of(non_null(:episode))) do
      arg(:season, :integer)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Library.episodes/3)
    end
  end

  @desc "A metadata provider hit"
  object :lookup_result do
    field :provider, non_null(:metadata_provider)
    field :provider_id, non_null(:string)
    field :type, non_null(:media_type)
    field :title, non_null(:string)
    field :year, :integer
    field :overview, :string
    field :poster_url, :string
    field :imdb_id, :string

    field :in_library, :media_item,
      description: "The library item this hit corresponds to, if Mydia already has it"
  end

  @desc "One item in a mediaItems page"
  object :media_item_edge do
    field :node, non_null(:media_item)
    field :cursor, non_null(:string)
  end

  @desc "A page of media items"
  object :media_item_connection do
    field :edges, non_null(list_of(non_null(:media_item_edge)))
    field :page_info, non_null(:page_info)
  end
end
