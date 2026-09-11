defmodule MydiaWeb.LibrarySchema.MutationTypes do
  @moduledoc """
  The Library API's mutations.

  Every field declares an `action` that the schema's `middleware/3` turns into an
  `Authorize` step, exactly as queries do. Each resolver calls the context
  function the UI calls, so a change made here is the same change the UI makes.
  """

  use Absinthe.Schema.Notation

  @desc "A movie to add"
  input_object :add_movie_input do
    field :tmdb_id, non_null(:integer)
    field :quality_profile_id, :id
    field :library_path_id, :id
    field :monitored, :boolean, default_value: true
    field :search_now, :boolean, default_value: false
  end

  @desc "A TV show to add. Give tvdbId or tmdbId; tvdbId wins when both are set."
  input_object :add_tv_show_input do
    field :tvdb_id, :integer
    field :tmdb_id, :integer
    field :quality_profile_id, :id
    field :library_path_id, :id
    field :monitored, :boolean, default_value: true
    field :season_monitoring, :season_monitoring, default_value: :all
    field :search_now, :boolean, default_value: false
  end

  @desc "A media item to remove"
  input_object :remove_media_item_input do
    field :id, non_null(:id)
    field :delete_files, :boolean, default_value: false
  end

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

    @desc "Add a movie by its TMDB id"
    field :add_movie, non_null(:add_media_payload) do
      meta(action: :manage_library)
      arg(:input, non_null(:add_movie_input))
      # Fetches the title from the metadata relay, like lookup.
      complexity(20)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.LibraryWrites.add_movie/3)
    end

    @desc "Add a TV show by its TVDB or TMDB id"
    field :add_tv_show, non_null(:add_media_payload) do
      meta(action: :manage_library)
      arg(:input, non_null(:add_tv_show_input))
      complexity(20)
      resolve(&MydiaWeb.LibrarySchema.Resolvers.LibraryWrites.add_tv_show/3)
    end

    @desc "Remove a movie or show from the library"
    field :remove_media_item, non_null(:remove_media_item_payload) do
      meta(action: :manage_library)
      arg(:input, non_null(:remove_media_item_input))
      resolve(&MydiaWeb.LibrarySchema.Resolvers.LibraryWrites.remove_media_item/3)
    end
  end
end
