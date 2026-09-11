defmodule MydiaWeb.LibrarySchema.MutationTypes do
  @moduledoc """
  The Library API's mutations.

  Every field declares an `action` that the schema's `middleware/3` turns into an
  `Authorize` step, exactly as queries do. Each resolver calls the context
  function the UI calls, so a change made here is the same change the UI makes.
  """

  use Absinthe.Schema.Notation

  object :library_mutations do
    @desc "Turn monitoring on or off for a movie or show"
    field :set_media_item_monitored, non_null(:media_item_payload) do
      meta(action: :manage_library)
      arg(:id, non_null(:id))
      arg(:monitored, non_null(:boolean))
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Monitoring.set_media_item_monitored/3)
    end

    @desc "Turn monitoring on or off for every episode of one season"
    field :set_season_monitored, non_null(:media_item_payload) do
      meta(action: :manage_library)
      arg(:media_item_id, non_null(:id))
      arg(:season, non_null(:integer))
      arg(:monitored, non_null(:boolean))
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Monitoring.set_season_monitored/3)
    end

    @desc "Turn monitoring on or off for one episode"
    field :set_episode_monitored, non_null(:episode_payload) do
      meta(action: :manage_library)
      arg(:id, non_null(:id))
      arg(:monitored, non_null(:boolean))
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Monitoring.set_episode_monitored/3)
    end

    @desc "Apply a monitoring preset to a show's episodes"
    field :apply_episode_monitoring, non_null(:media_item_payload) do
      meta(action: :manage_library)
      arg(:media_item_id, non_null(:id))
      arg(:preset, non_null(:episode_monitoring_preset))
      resolve(&MydiaWeb.LibrarySchema.Resolvers.Monitoring.apply_episode_monitoring/3)
    end
  end
end
