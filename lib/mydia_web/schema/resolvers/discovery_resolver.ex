defmodule MydiaWeb.Schema.Resolvers.DiscoveryResolver do
  @moduledoc """
  Resolvers for discovery-related GraphQL queries (home screen rails).
  """

  alias Mydia.{Library, Media, Playback}
  alias MydiaWeb.Schema.Resolvers.MediaHelpers

  @spec continue_watching(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def continue_watching(_parent, args, %{context: context}) do
    first = Map.get(args, :first, 10)
    after_cursor = Map.get(args, :after)

    case context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        # Get in-progress items (watched = false, has position)
        progress_list =
          Playback.list_user_progress(user.id, watched: false, limit: first * 3)
          |> Enum.filter(&(&1.position_seconds > 0 && (&1.completion_percentage || 0) < 90))

        all_items =
          progress_list
          |> Enum.map(&build_continue_watching_item(&1, user.id))
          |> Enum.reject(&is_nil/1)

        # Apply cursor pagination
        items = paginate_simple(all_items, first, after_cursor)

        {:ok, items}
    end
  end

  @spec recently_added(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def recently_added(_parent, args, _info) do
    first = Map.get(args, :first, 20)
    after_cursor = Map.get(args, :after)
    types = Map.get(args, :types)

    # Filter to items added in last 30 days
    thirty_days_ago = DateTime.utc_now() |> DateTime.add(-30, :day)

    # Build query options
    opts = [preload: [], added_since: thirty_days_ago, has_files: true]

    opts =
      if types do
        type_filter =
          cond do
            :movie in types and :tv_show in types -> nil
            :movie in types -> "movie"
            :tv_show in types -> "tv_show"
            true -> nil
          end

        if type_filter, do: Keyword.put(opts, :type, type_filter), else: opts
      else
        opts
      end

    # Get recently added items (sorted by most recent first)
    all_items =
      Media.list_media_items(opts)
      |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
      |> Enum.map(&build_recently_added_item/1)

    # Apply cursor pagination
    items = paginate_simple(all_items, first, after_cursor)

    {:ok, items}
  end

  @spec up_next(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def up_next(_parent, args, %{context: context}) do
    first = Map.get(args, :first, 10)
    after_cursor = Map.get(args, :after)

    case context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        # Get all TV shows with in-progress episodes
        tv_shows = Media.list_media_items(type: "tv_show", has_files: true)

        all_items =
          tv_shows
          |> Enum.map(fn show ->
            case Playback.get_next_episode(show.id, user.id) do
              nil ->
                nil

              :all_watched ->
                nil

              {state, episode} ->
                %{
                  episode: episode,
                  show: Map.put(show, :added_at, show.inserted_at),
                  progress_state: Atom.to_string(state)
                }
            end
          end)
          |> Enum.reject(&is_nil/1)

        # Apply cursor pagination
        items = paginate_simple(all_items, first, after_cursor)

        {:ok, items}
    end
  end

  @spec favorites(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def favorites(_parent, args, %{context: context}) do
    first = Map.get(args, :first, 50)
    after_cursor = Map.get(args, :after)
    types = Map.get(args, :types)

    case context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        all_items =
          Media.list_user_favorites(user.id)
          |> maybe_filter_by_type(types)
          |> Enum.map(&build_recently_added_item/1)

        items = paginate_simple(all_items, first, after_cursor)
        {:ok, items}
    end
  end

  @spec trending(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def trending(_parent, args, _info) do
    type = Map.get(args, :type, :movie)

    results =
      case type do
        :movie -> Media.trending_movies()
        :tv_show -> Media.trending_tv_shows()
        _ -> {:ok, []}
      end

    case results do
      {:ok, items} ->
        mapped = Enum.map(items, &MediaHelpers.map_external_to_search_result(&1, type))
        {:ok, mapped}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec curated_list(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def curated_list(_parent, args, _info) do
    list_type = Map.get(args, :list_type)
    media_type = Map.get(args, :media_type, :movie)
    page = Map.get(args, :page, 1)

    case Mydia.Metadata.fetch_curated_list(list_type, media_type: media_type, page: page) do
      {:ok, %{results: items, total_results: total_count}} ->
        mapped = Enum.map(items, &MediaHelpers.map_external_to_search_result(&1, media_type))
        {:ok, %{results: mapped, total_count: total_count}}

      {:ok, items} when is_list(items) ->
        mapped = Enum.map(items, &MediaHelpers.map_external_to_search_result(&1, media_type))
        {:ok, %{results: mapped, total_count: length(mapped)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec unwatched(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def unwatched(_parent, args, %{context: context}) do
    first = Map.get(args, :first, 50)
    after_cursor = Map.get(args, :after)
    types = Map.get(args, :types)

    case context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        # Get all media items with files
        media_items = Media.list_media_items(has_files: true)

        # Get IDs of fully watched items
        watched_ids =
          Playback.list_user_progress(user.id, watched: true)
          |> Enum.map(& &1.media_item_id)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        all_items =
          media_items
          |> Enum.reject(&MapSet.member?(watched_ids, &1.id))
          |> maybe_filter_by_type(types)
          |> Enum.sort_by(& &1.inserted_at, {:desc, DateTime})
          |> Enum.map(&build_recently_added_item/1)

        items = paginate_simple(all_items, first, after_cursor)
        {:ok, items}
    end
  end

  # Private helper functions

  defp maybe_filter_by_type(items, nil), do: items
  defp maybe_filter_by_type(items, []), do: items

  defp maybe_filter_by_type(items, types) do
    type_strings = Enum.map(types, &to_string/1)
    Enum.filter(items, &(&1.type in type_strings))
  end

  # Simple pagination for lists (not connection-style)
  defp paginate_simple(items, first, nil) do
    # No cursor - start from beginning
    Enum.take(items, first)
  end

  defp paginate_simple(items, first, after_cursor) do
    # Decode cursor to get offset
    offset = decode_cursor(after_cursor) + 1

    # Skip to after the cursor and take the requested amount
    items
    |> Enum.drop(offset)
    |> Enum.take(first)
  end

  defp decode_cursor(cursor) do
    case Base.decode64(cursor) do
      {:ok, "cursor:" <> offset_str} ->
        String.to_integer(offset_str)

      _ ->
        0
    end
  end

  defp build_continue_watching_item(%{media_item_id: media_item_id} = progress, _user_id)
       when not is_nil(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    case Library.get_media_files_for_item(media_item_id) do
      [] ->
        nil

      _files ->
        %{
          id: media_item.id,
          type: String.to_existing_atom(media_item.type),
          title: media_item.title,
          artwork: MediaHelpers.build_artwork(media_item),
          progress: format_progress(progress),
          show_title: nil,
          season_number: nil,
          episode_number: nil
        }
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp build_continue_watching_item(%{episode_id: episode_id} = progress, _user_id)
       when not is_nil(episode_id) do
    episode = Media.get_episode!(episode_id)

    case Library.get_media_files_for_episode(episode_id) do
      [] ->
        nil

      _files ->
        show = Media.get_media_item!(episode.media_item_id)

        %{
          id: episode.id,
          type: :episode,
          title: episode.title || "Episode #{episode.episode_number}",
          artwork: build_episode_artwork(episode, show),
          progress: format_progress(progress),
          show_id: show.id,
          show_title: show.title,
          season_number: episode.season_number,
          episode_number: episode.episode_number
        }
    end
  rescue
    Ecto.NoResultsError -> nil
  end

  defp build_continue_watching_item(_, _), do: nil

  defp build_recently_added_item(media_item) do
    %{
      id: media_item.id,
      type: String.to_existing_atom(media_item.type),
      title: media_item.title,
      year: media_item.year,
      artwork: MediaHelpers.build_artwork(media_item),
      added_at: media_item.inserted_at
    }
  end

  defp build_episode_artwork(%{metadata: metadata}, show) when not is_nil(metadata) do
    still_path = Mydia.Metadata.Access.get(metadata, :still_path)
    show_artwork = MediaHelpers.build_artwork(show)

    # Always include show's poster/backdrop, plus episode thumbnail if available
    %{
      poster_url: show_artwork && show_artwork.poster_url,
      backdrop_url: show_artwork && show_artwork.backdrop_url,
      thumbnail_url: Mydia.Metadata.ImageUrl.still_url(still_path)
    }
  end

  defp build_episode_artwork(_episode, show), do: MediaHelpers.build_artwork(show)

  defp format_progress(progress), do: MediaHelpers.format_progress(progress)
end
