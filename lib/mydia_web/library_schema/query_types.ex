defmodule MydiaWeb.LibrarySchema.QueryTypes do
  @moduledoc """
  Root query fields for the Library API.

  Every field declares `meta action:`, which `MydiaWeb.LibrarySchema.middleware/3`
  reads at compile time.
  """

  use Absinthe.Schema.Notation

  object :library_queries do
    @desc "Quality profiles available to assign"
    field :quality_profiles, non_null(list_of(non_null(:quality_profile))) do
      meta(action: :read_library)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Reference.quality_profiles/3)
    end

    @desc "Search a metadata provider for titles not yet in the library"
    field :lookup, non_null(list_of(non_null(:lookup_result))) do
      meta(action: :read_library)
      arg(:query, non_null(:string))
      arg(:type, non_null(:media_type))
      arg(:year, :integer)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Lookup.lookup/3)
    end

    @desc "One media item, by id or by an external id"
    field :media_item, :media_item do
      meta(action: :read_library)
      arg(:id, :id)
      arg(:type, :media_type)
      arg(:tmdb_id, :integer)
      arg(:tvdb_id, :integer)
      arg(:imdb_id, :string)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Library.media_item/3)
    end

    @desc "Media items changed recently, oldest first"
    field :media_items, non_null(:media_item_connection) do
      meta(action: :read_library)
      arg(:first, :integer, default_value: 50)
      arg(:after, :string)
      arg(:updated_since, :datetime)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Library.media_items/3)
    end
  end
end
