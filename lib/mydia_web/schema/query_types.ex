defmodule MydiaWeb.Schema.QueryTypes do
  @moduledoc """
  GraphQL query type definitions.
  """

  use Absinthe.Schema.Notation

  alias MydiaWeb.Schema.Resolvers.BrowseResolver
  alias MydiaWeb.Schema.Resolvers.DiscoveryResolver
  alias MydiaWeb.Schema.Resolvers.SearchResolver
  alias MydiaWeb.Schema.Resolvers.ApiKeyResolver
  alias MydiaWeb.Schema.Resolvers.StreamingResolver
  alias MydiaWeb.Schema.Resolvers.CollectionResolver
  alias MydiaWeb.Schema.Resolvers.SubtitleResolver
  alias MydiaWeb.Schema.Resolvers.SubtitleSearchResolver

  # Node interface for global node resolution with hierarchical navigation
  interface :node do
    description("A node that can be fetched by global ID with hierarchical navigation")

    field :id, non_null(:id), description: "Global node ID"
    field :parent, :node, description: "Parent node in the hierarchy"

    field :children, :node_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
    end

    field :ancestors, list_of(:node), description: "Full path from root to this node"
    field :is_playable, non_null(:boolean), description: "Whether this node can be played"

    resolve_type(fn
      %{type: "movie"}, _ -> :movie
      %{type: "tv_show"}, _ -> :tv_show
      %{season_number: _, episode_number: _}, _ -> :episode
      %{season_number: _, episode_count: _}, _ -> :season
      %{path: _, monitored: _}, _ -> :library_path
      _, _ -> nil
    end)
  end

  # Connection type for node children pagination
  @desc "Edge for node connection"
  object :node_edge do
    field :node, non_null(:node)
    field :cursor, non_null(:string)
  end

  @desc "Connection for paginated node children"
  object :node_connection do
    field :edges, non_null(list_of(non_null(:node_edge)))
    field :page_info, non_null(:page_info)
    field :total_count, non_null(:integer)
  end

  # Browse queries - for navigating the library
  object :browse_queries do
    @desc "Get any node by its global ID"
    field :node, :node do
      arg(:id, non_null(:id))
      resolve(&BrowseResolver.get_node/3)
    end

    @desc "List all library paths"
    field :libraries, list_of(:library_path) do
      resolve(&BrowseResolver.list_libraries/3)
    end

    @desc "Get a movie by ID"
    field :movie, :movie do
      arg(:id, non_null(:id))
      resolve(&BrowseResolver.get_movie/3)
    end

    @desc "Get a TV show by ID"
    field :tv_show, :tv_show do
      arg(:id, non_null(:id))
      resolve(&BrowseResolver.get_tv_show/3)
    end

    @desc "Get an episode by ID"
    field :episode, :episode do
      arg(:id, non_null(:id))
      resolve(&BrowseResolver.get_episode/3)
    end

    @desc "List all movies with pagination"
    field :movies, :movie_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      arg(:sort, :sort_input)
      arg(:category, :media_category)
      resolve(&BrowseResolver.list_movies/3)
    end

    @desc "List all TV shows with pagination"
    field :tv_shows, :tv_show_connection do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      arg(:sort, :sort_input)
      arg(:category, :media_category)
      resolve(&BrowseResolver.list_tv_shows/3)
    end

    @desc "Get episodes for a specific season of a TV show"
    field :season_episodes, list_of(:episode) do
      arg(:show_id, non_null(:id))
      arg(:season_number, non_null(:integer))
      resolve(&BrowseResolver.list_season_episodes/3)
    end
  end

  # Remote access queries
  object :remote_access_queries do
    @desc "Get remote access / P2P connection status"
    field :remote_access_status, :remote_access_status do
      resolve(&MydiaWeb.Schema.Resolvers.RemoteAccessResolver.status/3)
    end
  end

  # Streaming queries - for candidate-based streaming decisions
  object :streaming_queries do
    @desc "Get streaming candidates for a media item"
    field :streaming_candidates, :streaming_candidates_result do
      arg(:content_type, non_null(:string))
      arg(:id, non_null(:id))
      resolve(&StreamingResolver.streaming_candidates/3)
    end
  end

  # Discovery queries - for home screen rails
  object :discovery_queries do
    @desc "Get items the user is currently watching (in-progress)"
    field :continue_watching, list_of(:continue_watching_item) do
      arg(:first, :integer, default_value: 10)
      arg(:after, :string)
      resolve(&DiscoveryResolver.continue_watching/3)
    end

    @desc "Get recently added content"
    field :recently_added, list_of(:recently_added_item) do
      arg(:first, :integer, default_value: 20)
      arg(:after, :string)
      arg(:types, list_of(:media_type))
      resolve(&DiscoveryResolver.recently_added/3)
    end

    @desc "Get next episodes to watch across all TV shows"
    field :up_next, list_of(:up_next_item) do
      deprecate("Merged into continueWatching, which now carries next episodes as well")
      arg(:first, :integer, default_value: 10)
      arg(:after, :string)
      resolve(&DiscoveryResolver.up_next/3)
    end

    @desc "Get the user's favorite items"
    field :favorites, list_of(:recently_added_item) do
      arg(:first, :integer, default_value: 50)
      arg(:after, :string)
      arg(:types, list_of(:media_type))
      arg(:category, :media_category)
      arg(:sort, :sort_input)
      resolve(&DiscoveryResolver.favorites/3)
    end

    @desc "Get unwatched items with files"
    field :unwatched, list_of(:recently_added_item) do
      arg(:first, :integer, default_value: 50)
      arg(:after, :string)
      arg(:types, list_of(:media_type))
      arg(:category, :media_category)
      arg(:sort, :sort_input)
      resolve(&DiscoveryResolver.unwatched/3)
    end
  end

  # Search queries
  object :search_queries do
    @desc "Search the library across movies, TV shows, episodes, and collections"
    field :search, :search_results do
      arg(:query, non_null(:string))
      arg(:types, list_of(:search_result_type))
      arg(:first, :integer, default_value: 20)
      resolve(&SearchResolver.search/3)
    end
  end

  # API key queries
  object :api_key_queries do
    @desc "List all API keys for the current user"
    field :api_keys, list_of(:api_key) do
      resolve(&ApiKeyResolver.list_api_keys/3)
    end
  end

  # Device queries
  object :device_queries do
    @desc "List all devices for the current user"
    field :devices, list_of(:remote_device) do
      resolve(&MydiaWeb.Schema.Resolvers.DeviceResolver.list_devices/3)
    end
  end

  # Discovery item types
  @desc "An item in the continue watching rail"
  object :continue_watching_item do
    field :id, non_null(:id)
    field :type, non_null(:media_type)
    field :title, non_null(:string)
    field :artwork, :artwork
    field :progress, non_null(:progress)

    @desc "Why this item is on the rail: continue for a resume point, next for the successor of a finished episode"
    field :state, :string
    @desc "Playable files for this item, used to start playback straight from the rail"
    field :files, list_of(:media_file)

    @desc "For episodes, includes show context"
    field :show_id, :id
    field :show_title, :string
    field :season_number, :integer
    field :episode_number, :integer
  end

  @desc "An item in the recently added rail"
  object :recently_added_item do
    field :id, non_null(:id)
    field :type, non_null(:media_type)
    field :title, non_null(:string)
    field :year, :integer
    field :artwork, :artwork
    field :added_at, non_null(:datetime)

    @desc "Episodes whose first file arrived inside the recently-added window. Null for movies and for unwindowed lists."
    field :new_episode_count, :integer

    @desc "Season of the newest arrived episode. Null for movies and for unmatched files."
    field :latest_season_number, :integer

    @desc "Number of the newest arrived episode. Null for movies and for unmatched files."
    field :latest_episode_number, :integer

    @desc "Rolled-up watch state"
    field :watch_status, :watch_status do
      resolve(&MydiaWeb.Schema.Resolvers.MediaResolver.resolve_recently_added_watch_status/3)
    end
  end

  @desc "An item in the up next rail (next episode to watch)"
  object :up_next_item do
    field :episode, non_null(:episode)
    field :show, non_null(:tv_show)
    field :progress_state, non_null(:string), description: "One of: continue, next, start"
  end

  # Collection types
  @desc "A user-created collection of media items"
  object :collection do
    field :id, non_null(:id)
    field :name, non_null(:string)
    field :description, :string
    field :type, non_null(:string)
    field :visibility, non_null(:string)
    field :item_count, non_null(:integer)
    field :poster_paths, list_of(:string)
  end

  # Collection queries
  object :collection_queries do
    @desc "List user's collections (excluding system collections)"
    field :collections, list_of(:collection) do
      arg(:first, :integer, default_value: 50)
      resolve(&CollectionResolver.list_collections/3)
    end

    @desc "Get a single collection by ID"
    field :collection, :collection do
      arg(:id, non_null(:id))
      resolve(&CollectionResolver.collection/3)
    end

    @desc "Get items in a collection"
    field :collection_items, list_of(:recently_added_item) do
      arg(:collection_id, non_null(:id))
      arg(:first, :integer, default_value: 50)
      resolve(&CollectionResolver.collection_items/3)
    end
  end

  object :subtitle_queries do
    @desc "Search every enabled subtitle provider for a media file"
    field :subtitle_search, non_null(:subtitle_search_payload) do
      arg(:media_file_id, non_null(:id))

      @desc ~s|ISO 639-1 codes, for example ["en", "es"]|
      arg(:languages, non_null(list_of(non_null(:string))))

      resolve(&SubtitleSearchResolver.search/3)
    end

    @desc """
    Fetch one subtitle track's body directly, without resolving every track
    on the media file. There is no root `mediaFile(id:)` query and
    `MediaFile` does not implement `Node`, so this field takes the media file
    id and track id together rather than nesting through a movie or episode.
    """
    field :subtitle_content, :string do
      arg(:media_file_id, non_null(:id))
      arg(:track_id, non_null(:string))
      arg(:format, :subtitle_format, default_value: :vtt)

      resolve(&SubtitleResolver.subtitle_content/3)
    end
  end
end
