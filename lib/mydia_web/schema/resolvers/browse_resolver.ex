defmodule MydiaWeb.Schema.Resolvers.BrowseResolver do
  @moduledoc """
  Resolvers for browse-related GraphQL queries.
  """

  alias Mydia.{Media, Settings}
  alias MydiaWeb.Schema.Resolvers.NodeId

  @doc """
  Resolves a node by its global ID.

  Supports: movies, TV shows, episodes, and library paths.
  """
  def get_node(_parent, %{id: node_id}, _info) do
    case NodeId.decode(node_id) do
      {:movie, id} ->
        get_movie(nil, %{id: id}, nil)

      {:tv_show, id} ->
        get_tv_show(nil, %{id: id}, nil)

      {:episode, id} ->
        get_episode(nil, %{id: id}, nil)

      {:library_path, id} ->
        get_library_path(nil, %{id: id}, nil)

      {:season, show_id, season_number} ->
        get_season(nil, %{show_id: show_id, season_number: season_number}, nil)

      {:error, :invalid_node_id} ->
        {:error, "Invalid node ID"}
    end
  end

  def get_movie(_parent, %{id: id}, _info) do
    case NodeId.decode(id) do
      {:tmdb, tmdb_id} ->
        # Fetch from relay
        case Mydia.Metadata.fetch_by_id_cached(
               Mydia.Metadata.default_relay_config(),
               to_string(tmdb_id),
               media_type: :movie
             ) do
          {:ok, metadata} ->
            {:ok, map_external_to_virtual_item(metadata, :movie)}

          _ ->
            {:error, "Movie not found"}
        end

      _ ->
        media_item = Media.get_media_item!(id)

        case media_item.type do
          "movie" -> {:ok, Map.put(media_item, :added_at, media_item.inserted_at)}
          _ -> {:error, "Not a movie"}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, "Movie not found"}
  end

  def get_tv_show(_parent, %{id: id}, _info) do
    case NodeId.decode(id) do
      {:tmdb, tmdb_id} ->
        case Mydia.Metadata.fetch_by_id_cached(
               Mydia.Metadata.default_relay_config(),
               to_string(tmdb_id),
               media_type: :tv_show
             ) do
          {:ok, metadata} ->
            {:ok, map_external_to_virtual_item(metadata, :tv_show)}

          _ ->
            {:error, "TV show not found"}
        end

      {:tvdb, tvdb_id} ->
        case Mydia.Metadata.fetch_by_id_cached(
               Mydia.Metadata.default_relay_config(),
               to_string(tvdb_id),
               media_type: :tv_show
             ) do
          {:ok, metadata} ->
            {:ok, map_external_to_virtual_item(metadata, :tv_show)}

          _ ->
            {:error, "TV show not found"}
        end

      _ ->
        media_item = Media.get_media_item!(id)

        case media_item.type do
          "tv_show" -> {:ok, Map.put(media_item, :added_at, media_item.inserted_at)}
          _ -> {:error, "Not a TV show"}
        end
    end
  rescue
    Ecto.NoResultsError -> {:error, "TV show not found"}
  end

  def get_episode(_parent, %{id: id}, _info) do
    case NodeId.decode(id) do
      {:tmdb_episode, tmdb_id, season_number, episode_number} ->
        # Fetch show first to ensure it exists and get its metadata if needed
        # But we can also just fetch the episode directly from relay if supported
        case Mydia.Metadata.fetch_season_cached(
               Mydia.Metadata.default_relay_config(),
               to_string(tmdb_id),
               season_number
             ) do
          {:ok, %{episodes: episodes}} ->
            case Enum.find(episodes, &(&1.episode_number == episode_number)) do
              nil -> {:error, "Episode not found"}
              episode -> {:ok, map_external_to_virtual_episode(episode, tmdb_id, season_number)}
            end

          _ ->
            {:error, "Episode not found"}
        end

      _ ->
        episode = Media.get_episode!(id)
        {:ok, episode}
    end
  rescue
    Ecto.NoResultsError -> {:error, "Episode not found"}
  end

  def list_movies(_parent, args, _info) do
    first = Map.get(args, :first, 20)
    after_cursor = Map.get(args, :after)
    sort = Map.get(args, :sort, %{field: :title, direction: :asc})
    category = Map.get(args, :category)

    # Build query options
    opts = [
      type: "movie",
      preload: [:quality_profile],
      has_files: true
    ]

    opts = if category, do: Keyword.put(opts, :category, to_string(category)), else: opts

    # Get all movies for now (pagination will be implemented properly later)
    all_movies = Media.list_media_items(opts)

    # Sort
    sorted_movies = sort_items(all_movies, sort)

    # Apply cursor pagination
    {movies, page_info} = paginate(sorted_movies, first, after_cursor)

    # Map to include added_at field
    edges =
      movies
      |> Enum.with_index()
      |> Enum.map(fn {movie, idx} ->
        %{
          node: Map.put(movie, :added_at, movie.inserted_at),
          cursor: encode_cursor(idx)
        }
      end)

    {:ok,
     %{
       edges: edges,
       page_info: page_info,
       total_count: length(all_movies)
     }}
  end

  def list_tv_shows(_parent, args, _info) do
    first = Map.get(args, :first, 20)
    after_cursor = Map.get(args, :after)
    sort = Map.get(args, :sort, %{field: :title, direction: :asc})
    category = Map.get(args, :category)

    # Build query options
    opts = [
      type: "tv_show",
      preload: [:quality_profile],
      has_files: true
    ]

    opts = if category, do: Keyword.put(opts, :category, to_string(category)), else: opts

    # Get all TV shows
    all_shows = Media.list_media_items(opts)

    # Sort
    sorted_shows = sort_items(all_shows, sort)

    # Apply cursor pagination
    {shows, page_info} = paginate(sorted_shows, first, after_cursor)

    # Map to include added_at field
    edges =
      shows
      |> Enum.with_index()
      |> Enum.map(fn {show, idx} ->
        %{
          node: Map.put(show, :added_at, show.inserted_at),
          cursor: encode_cursor(idx)
        }
      end)

    {:ok,
     %{
       edges: edges,
       page_info: page_info,
       total_count: length(all_shows)
     }}
  end

  def list_season_episodes(_parent, %{show_id: show_id, season_number: season_number}, _info) do
    case NodeId.decode(show_id) do
      {:tmdb, tmdb_id} ->
        # Fetch from relay
        case Mydia.Metadata.fetch_season_cached(
               Mydia.Metadata.default_relay_config(),
               to_string(tmdb_id),
               season_number
             ) do
          {:ok, %{episodes: episodes}} ->
            {:ok,
             Enum.map(episodes, &map_external_to_virtual_episode(&1, tmdb_id, season_number))}

          _ ->
            {:error, "Season not found"}
        end

      _ ->
        episodes =
          Media.list_episodes(show_id)
          |> Enum.filter(&(&1.season_number == season_number))
          |> Enum.sort_by(& &1.episode_number)

        {:ok, episodes}
    end
  end

  # Helper functions

  defp sort_items(items, %{field: field, direction: direction}) do
    sorter =
      case field do
        :title -> & &1.title
        :year -> & &1.year
        :added_at -> & &1.inserted_at
        :rating -> &get_rating/1
        _ -> & &1.title
      end

    sorted = Enum.sort_by(items, sorter)

    if direction == :desc do
      Enum.reverse(sorted)
    else
      sorted
    end
  end

  defp sort_items(items, _), do: Enum.sort_by(items, & &1.title)

  defp get_rating(%{metadata: nil}), do: 0
  defp get_rating(%{metadata: %{vote_average: rating}}) when is_number(rating), do: rating
  defp get_rating(_), do: 0

  defp paginate(items, first, nil) do
    # No cursor - start from beginning
    paginated = Enum.take(items, first)

    page_info = %{
      has_next_page: length(items) > first,
      has_previous_page: false,
      start_cursor: if(length(paginated) > 0, do: encode_cursor(0), else: nil),
      end_cursor: if(length(paginated) > 0, do: encode_cursor(length(paginated) - 1), else: nil)
    }

    {paginated, page_info}
  end

  defp paginate(items, first, after_cursor) do
    # Decode cursor to get offset
    offset = decode_cursor(after_cursor) + 1

    # Skip to after the cursor
    remaining = Enum.drop(items, offset)
    paginated = Enum.take(remaining, first)

    page_info = %{
      has_next_page: length(remaining) > first,
      has_previous_page: offset > 0,
      start_cursor: if(length(paginated) > 0, do: encode_cursor(offset), else: nil),
      end_cursor:
        if(length(paginated) > 0, do: encode_cursor(offset + length(paginated) - 1), else: nil)
    }

    {paginated, page_info}
  end

  defp map_external_to_virtual_item(metadata, type) do
    %{
      id: "tmdb:#{metadata.provider_id}",
      type: to_string(type),
      title: metadata.title,
      original_title: metadata.original_title,
      year: metadata.year,
      tmdb_id: metadata.tmdb_id,
      imdb_id: metadata.imdb_id,
      overview: metadata.overview,
      runtime: metadata.runtime,
      genres: metadata.genres,
      content_rating: metadata.content_rating,
      rating: metadata.vote_average,
      monitored: false,
      added_at: nil,
      metadata: metadata,
      is_favorite: false,
      files: [],
      playback_progress: []
    }
  end

  defp map_external_to_virtual_episode(episode, tmdb_id, season_number) do
    %{
      id: "tmdb:#{tmdb_id}:#{season_number}:#{episode.episode_number}",
      show_id: "tmdb:#{tmdb_id}",
      season_number: season_number,
      episode_number: episode.episode_number,
      title: episode.name,
      overview: episode.overview,
      air_date: episode.air_date,
      runtime: episode.runtime,
      monitored: false,
      metadata: episode,
      files: [],
      playback_progress: []
    }
  end

  defp encode_cursor(offset) do
    Base.encode64("cursor:#{offset}")
  end

  defp decode_cursor(cursor) do
    case Base.decode64(cursor) do
      {:ok, "cursor:" <> offset_str} ->
        String.to_integer(offset_str)

      _ ->
        0
    end
  end

  @doc """
  Gets a library path by ID.
  """
  def get_library_path(_parent, %{id: id}, _info) do
    library_path = Settings.get_library_path!(id)
    {:ok, library_path}
  rescue
    Ecto.NoResultsError -> {:error, "Library path not found"}
  end

  @doc """
  Gets a season by show_id and season_number.

  Returns a virtual Season struct with episode information.
  """
  def get_season(_parent, %{show_id: show_id, season_number: season_number}, _info) do
    # Verify the show exists
    _show = Media.get_media_item!(show_id)

    # Get episodes for this season
    episodes =
      Media.list_episodes(show_id)
      |> Enum.filter(&(&1.season_number == season_number))

    if episodes == [] do
      {:error, "Season not found"}
    else
      alias Mydia.Library

      # Check if any episode has files
      has_files =
        Enum.any?(episodes, fn ep ->
          files = Library.get_media_files_for_episode(ep.id)
          length(files) > 0
        end)

      # Count aired episodes
      today = Date.utc_today()

      aired_count =
        Enum.count(episodes, fn ep ->
          ep.air_date != nil and Date.compare(ep.air_date, today) != :gt
        end)

      season = %{
        season_number: season_number,
        episode_count: length(episodes),
        aired_episode_count: aired_count,
        has_files: has_files,
        _episodes: episodes,
        _media_item_id: show_id
      }

      {:ok, season}
    end
  rescue
    Ecto.NoResultsError -> {:error, "TV show not found"}
  end

  @doc """
  Lists all library paths accessible to the user.
  """
  def list_libraries(_parent, _args, _info) do
    libraries = Settings.list_library_paths()
    {:ok, libraries}
  end

  # Hierarchical navigation resolvers for Node interface

  @doc """
  Resolves the parent node in the hierarchy.

  Hierarchy:
  - Episode → Season → TvShow → nil
  - Season → TvShow → nil
  - Movie → nil
  - TvShow → nil
  - LibraryPath → nil
  """
  def resolve_parent(parent, _args, _info) do
    case determine_node_type(parent) do
      :episode ->
        # Episode → Season
        season_number = parent.season_number
        media_item_id = parent.media_item_id

        get_season(nil, %{show_id: media_item_id, season_number: season_number}, nil)

      :season ->
        # Season → TvShow
        show_id = parent._media_item_id
        get_tv_show(nil, %{id: show_id}, nil)

      _ ->
        # Movies, TvShows, and LibraryPaths have no parent
        {:ok, nil}
    end
  end

  @doc """
  Resolves child nodes with cursor pagination.

  Children:
  - TvShow → Seasons
  - Season → Episodes
  - Movie → []
  - Episode → []
  - LibraryPath → [] (for now, could be shows/movies in the future)
  """
  def resolve_children(parent, args, _info) do
    first = Map.get(args, :first, 20)
    after_cursor = Map.get(args, :after)

    children =
      case determine_node_type(parent) do
        :tv_show ->
          # Get all seasons
          case resolve_seasons_as_list(parent) do
            {:ok, seasons} -> seasons
            _ -> []
          end

        :season ->
          # Get all episodes in this season
          case resolve_episodes_as_list(parent) do
            {:ok, episodes} -> episodes
            _ -> []
          end

        _ ->
          # Movies, Episodes, and LibraryPaths have no children
          []
      end

    # Apply cursor pagination
    {paginated_children, page_info} = paginate(children, first, after_cursor)

    edges =
      paginated_children
      |> Enum.with_index()
      |> Enum.map(fn {child, idx} ->
        %{
          node: child,
          cursor: encode_cursor(idx)
        }
      end)

    {:ok,
     %{
       edges: edges,
       page_info: page_info,
       total_count: length(children)
     }}
  end

  @doc """
  Resolves ancestors - full path from root to this node.

  Examples:
  - Episode: [TvShow, Season, Episode]
  - Season: [TvShow, Season]
  - TvShow: [TvShow]
  - Movie: [Movie]
  """
  def resolve_ancestors(node, _args, _info) do
    ancestors = build_ancestor_path(node, [])
    {:ok, ancestors}
  end

  @doc """
  Resolves whether this node can be played.

  Playable nodes:
  - Movies with files
  - Episodes with files
  """
  def resolve_is_playable(parent, _args, _info) do
    alias Mydia.Library

    playable =
      case determine_node_type(parent) do
        :movie ->
          files = Library.get_media_files_for_item(parent.id)
          length(files) > 0

        :episode ->
          files = Library.get_media_files_for_episode(parent.id)
          length(files) > 0

        _ ->
          false
      end

    {:ok, playable}
  end

  # Private helper functions

  defp determine_node_type(%{type: "movie"}), do: :movie
  defp determine_node_type(%{type: "tv_show"}), do: :tv_show
  defp determine_node_type(%{season_number: _, episode_number: _}), do: :episode
  defp determine_node_type(%{season_number: _, episode_count: _}), do: :season
  defp determine_node_type(%{path: _, monitored: _}), do: :library_path
  defp determine_node_type(_), do: :unknown

  defp resolve_seasons_as_list(parent) do
    alias MydiaWeb.Schema.Resolvers.MediaResolver
    MediaResolver.resolve_seasons(parent, %{}, %{})
  end

  defp resolve_episodes_as_list(%{_episodes: episodes}) when is_list(episodes) do
    {:ok, Enum.sort_by(episodes, & &1.episode_number)}
  end

  defp resolve_episodes_as_list(%{season_number: season_number, _media_item_id: media_item_id}) do
    episodes =
      Media.list_episodes(media_item_id)
      |> Enum.filter(&(&1.season_number == season_number))
      |> Enum.sort_by(& &1.episode_number)

    {:ok, episodes}
  end

  defp build_ancestor_path(node, acc) do
    updated_acc = [node | acc]

    case resolve_parent(node, %{}, %{}) do
      {:ok, nil} ->
        # No parent, reverse to get root → node order
        Enum.reverse(updated_acc)

      {:ok, parent} ->
        # Continue building path
        build_ancestor_path(parent, updated_acc)

      _ ->
        Enum.reverse(updated_acc)
    end
  end
end
