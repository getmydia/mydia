defmodule MydiaWeb.Schema.MediaTypes do
  @moduledoc """
  GraphQL types for media content (movies, TV shows, episodes).
  """

  use Absinthe.Schema.Notation

  alias MydiaWeb.Schema.Resolvers.MediaResolver

  @desc "A cast member (actor) on a movie or TV show"
  object :cast_member do
    field :name, non_null(:string)
    field :character, :string
    field :profile_url, :string
  end

  @desc "A movie"
  object :movie do
    interface(:node)

    field :id, non_null(:id)

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :title, non_null(:string)
    field :original_title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string

    field :category, :media_category do
      resolve(&MediaResolver.resolve_category/3)
    end

    field :monitored, non_null(:boolean)
    field :added_at, non_null(:datetime)

    @desc "Movie overview/synopsis"
    field :overview, :string do
      resolve(&MediaResolver.resolve_overview/3)
    end

    @desc "Movie runtime in minutes"
    field :runtime, :integer do
      resolve(&MediaResolver.resolve_runtime/3)
    end

    @desc "Genres list"
    field :genres, list_of(:string) do
      resolve(&MediaResolver.resolve_genres/3)
    end

    @desc "Content rating (e.g., PG-13, R)"
    field :content_rating, :string do
      resolve(&MediaResolver.resolve_content_rating/3)
    end

    @desc "Watch-page URL for the first available YouTube trailer"
    field :trailer_url, :string do
      resolve(&MediaResolver.resolve_trailer_url/3)
    end

    @desc "Cast members"
    field :cast, list_of(:cast_member) do
      resolve(&MediaResolver.resolve_cast/3)
    end

    @desc "Average rating (0-10)"
    field :rating, :float do
      resolve(&MediaResolver.resolve_rating/3)
    end

    @desc "Artwork images"
    field :artwork, :artwork do
      resolve(&MediaResolver.resolve_artwork/3)
    end

    @desc "Available video files"
    field :files, list_of(:media_file) do
      resolve(&MediaResolver.resolve_movie_files/3)
    end

    @desc "User playback progress"
    field :progress, :progress do
      resolve(&MediaResolver.resolve_progress/3)
    end

    @desc "Whether this item is in user favorites"
    field :is_favorite, non_null(:boolean) do
      resolve(&MediaResolver.resolve_is_favorite/3)
    end
  end

  @desc "The episode this user should play next, with the state that selected it"
  object :show_next_up do
    field :episode, non_null(:episode)

    @desc "One of: continue, next, start"
    field :progress_state, non_null(:string)
  end

  @desc "A TV show"
  object :tv_show do
    interface(:node)

    field :id, non_null(:id)

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :title, non_null(:string)
    field :original_title, :string
    field :year, :integer
    field :tmdb_id, :integer
    field :tvdb_id, :integer
    field :imdb_id, :string

    field :category, :media_category do
      resolve(&MediaResolver.resolve_category/3)
    end

    field :monitored, non_null(:boolean)
    field :added_at, non_null(:datetime)

    @desc "Show overview/synopsis"
    field :overview, :string do
      resolve(&MediaResolver.resolve_overview/3)
    end

    @desc "Show status (Continuing, Ended, etc.)"
    field :status, :string do
      resolve(&MediaResolver.resolve_status/3)
    end

    @desc "Genres list"
    field :genres, list_of(:string) do
      resolve(&MediaResolver.resolve_genres/3)
    end

    @desc "Content rating"
    field :content_rating, :string do
      resolve(&MediaResolver.resolve_content_rating/3)
    end

    @desc "Watch-page URL for the first available YouTube trailer"
    field :trailer_url, :string do
      resolve(&MediaResolver.resolve_trailer_url/3)
    end

    @desc "Cast members"
    field :cast, list_of(:cast_member) do
      resolve(&MediaResolver.resolve_cast/3)
    end

    @desc "Average rating (0-10)"
    field :rating, :float do
      resolve(&MediaResolver.resolve_rating/3)
    end

    @desc "Artwork images"
    field :artwork, :artwork do
      resolve(&MediaResolver.resolve_artwork/3)
    end

    @desc "List of seasons"
    field :seasons, list_of(:season) do
      resolve(&MediaResolver.resolve_seasons/3)
    end

    @desc "Total number of seasons"
    field :season_count, :integer do
      resolve(&MediaResolver.resolve_season_count/3)
    end

    @desc "Total number of episodes"
    field :episode_count, :integer do
      resolve(&MediaResolver.resolve_episode_count/3)
    end

    @desc "Next episode to watch for the current user"
    field :next_episode, :episode do
      resolve(&MediaResolver.resolve_next_episode/3)
    end

    @desc "Next episode to watch, with the state that selected it"
    field :next_up, :show_next_up do
      resolve(&MediaResolver.resolve_next_up/3)
    end

    @desc "Whether this item is in user favorites"
    field :is_favorite, non_null(:boolean) do
      resolve(&MediaResolver.resolve_is_favorite/3)
    end

    @desc "Metadata provider used to fetch this show's data (tvdb or tmdb)"
    field :metadata_source, :string do
      resolve(fn parent, _args, _res ->
        {:ok, parent.metadata_source && to_string(parent.metadata_source)}
      end)
    end
  end

  @desc "A season of a TV show"
  object :season do
    interface(:node)

    field :id, non_null(:id) do
      description("Season global ID (season:<show_id>:<season_number>)")

      resolve(fn season, _args, _info ->
        alias MydiaWeb.Schema.Resolvers.NodeId
        show_id = season._media_item_id
        season_number = season.season_number
        {:ok, NodeId.encode(:season, show_id, season_number)}
      end)
    end

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :season_number, non_null(:integer)
    field :episode_count, non_null(:integer)
    field :aired_episode_count, :integer
    field :has_files, non_null(:boolean)

    @desc "Episodes in this season"
    field :episodes, list_of(:episode) do
      resolve(&MediaResolver.resolve_season_episodes/3)
    end
  end

  @desc "A TV episode"
  object :episode do
    interface(:node)

    field :id, non_null(:id)

    # Node interface fields
    field :parent, :node do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_parent/3)
    end

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_children/3)
    end

    field :ancestors, list_of(:node) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_ancestors/3)
    end

    field :is_playable, non_null(:boolean) do
      resolve(&MydiaWeb.Schema.Resolvers.BrowseResolver.resolve_is_playable/3)
    end

    field :season_number, non_null(:integer)
    field :episode_number, non_null(:integer)
    field :title, :string
    field :air_date, :date
    field :monitored, non_null(:boolean)

    @desc "Episode overview/synopsis"
    field :overview, :string do
      resolve(&MediaResolver.resolve_episode_overview/3)
    end

    @desc "Episode runtime in minutes"
    field :runtime, :integer do
      resolve(&MediaResolver.resolve_episode_runtime/3)
    end

    @desc "Episode thumbnail image"
    field :thumbnail_url, :string do
      resolve(&MediaResolver.resolve_episode_thumbnail/3)
    end

    @desc "Available video files"
    field :files, list_of(:media_file) do
      resolve(&MediaResolver.resolve_episode_files/3)
    end

    @desc "User playback progress"
    field :progress, :progress do
      resolve(&MediaResolver.resolve_episode_progress/3)
    end

    @desc "Whether this episode has at least one file"
    field :has_file, non_null(:boolean) do
      resolve(&MediaResolver.resolve_has_file/3)
    end

    @desc "Parent TV show info (for context when showing episodes)"
    field :show, :tv_show do
      resolve(&MediaResolver.resolve_parent_show/3)
    end
  end

  # Connection types for pagination
  @desc "Edge for movie connection"
  object :movie_edge do
    field :node, non_null(:movie)
    field :cursor, non_null(:string)
  end

  @desc "Connection for paginated movies"
  object :movie_connection do
    field :edges, non_null(list_of(non_null(:movie_edge)))
    field :page_info, non_null(:page_info)
    field :total_count, non_null(:integer)
  end

  @desc "Edge for TV show connection"
  object :tv_show_edge do
    field :node, non_null(:tv_show)
    field :cursor, non_null(:string)
  end

  @desc "Connection for paginated TV shows"
  object :tv_show_connection do
    field :edges, non_null(list_of(non_null(:tv_show_edge)))
    field :page_info, non_null(:page_info)
    field :total_count, non_null(:integer)
  end
end
