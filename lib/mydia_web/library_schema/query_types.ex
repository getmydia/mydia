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

    @desc "Library paths available to add media into"
    field :library_paths, non_null(list_of(non_null(:library_path))) do
      meta(action: :read_library)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Reference.library_paths/3)
    end

    @desc "Search a metadata provider for titles not yet in the library"
    field :lookup, non_null(list_of(non_null(:lookup_result))) do
      meta(action: :read_library)
      arg(:query, non_null(:string))
      arg(:type, non_null(:media_type))
      arg(:year, :integer)

      # One relay round trip per call, independent of how many results come back.
      complexity(20)

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

      arg(:updated_since, :datetime,
        description: "Only items updated at or after this instant (inclusive)"
      )

      # Absinthe defaults to 1 + child complexity; explicitly account for page
      # size, matching the resolver's default of 50 and cap of 200. The floor of
      # 1 matters because analysis runs before the resolver rejects a bad
      # `first`: a zero or negative cost would offset expensive siblings.
      complexity(fn args, child_complexity ->
        MydiaWeb.LibrarySchema.Paging.cost(args, 50, 200, child_complexity)
      end)

      resolve(&MydiaWeb.LibrarySchema.Resolvers.Library.media_items/3)
    end

    @desc "The download queue and history. Contacts every configured client."
    field :downloads, non_null(list_of(non_null(:download))) do
      meta(action: :read_downloads)
      arg(:filter, :download_filter, default_value: :active)

      # Every configured client is contacted, so cost is per call, not per row.
      complexity(50)

      resolve(&MydiaWeb.LibrarySchema.Resolvers.Downloads.downloads/3)
    end

    @desc "Library activity, oldest first. Best-effort: the docs explain the limits."
    field :events, non_null(:event_connection) do
      meta(action: :read_events)
      arg(:first, :integer, default_value: 100)
      arg(:after, :string)
      arg(:types, list_of(non_null(:string)), description: "Defaults to every published type")

      complexity(fn args, child_complexity ->
        MydiaWeb.LibrarySchema.Paging.cost(args, 100, 200, child_complexity)
      end)

      resolve(&MydiaWeb.LibrarySchema.Resolvers.Events.events/3)
    end
  end
end
