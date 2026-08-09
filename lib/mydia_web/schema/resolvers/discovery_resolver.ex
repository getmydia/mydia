defmodule MydiaWeb.Schema.Resolvers.DiscoveryResolver do
  @moduledoc """
  Resolvers for discovery-related GraphQL queries (home screen rails).
  """

  alias Mydia.{Library, Media, Playback}

  alias Mydia.Media.RecentlyAdded
  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Metadata.ImageUrl
  alias MydiaWeb.Schema.Resolvers.ItemBuilder
  alias MydiaWeb.Schema.Resolvers.MediaSort

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
    thirty_days_ago = DateTime.add(DateTime.utc_now(), -30, :day)

    entries =
      RecentlyAdded.list_recent(
        since: thirty_days_ago,
        types: requested_types(Map.get(args, :types)),
        limit: pagination_limit(first, after_cursor)
      )

    all_items =
      Enum.map(entries, fn entry ->
        ItemBuilder.recently_added_item(entry.media_item,
          added_at: entry.content_added_at,
          new_episode_count: entry.new_episode_count,
          latest_episode: entry.latest_episode
        )
      end)

    {:ok, paginate_simple(all_items, first, after_cursor)}
  end

  # The GraphQL arg is a list of atoms; RecentlyAdded filters on the string
  # column. Nil and a list covering both types both mean "no filter".
  defp requested_types(nil), do: nil
  defp requested_types([]), do: nil

  defp requested_types(types) do
    strings = Enum.map(types, &to_string/1)

    if "movie" in strings and "tv_show" in strings, do: nil, else: strings
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
  def favorites(_parent, args, resolution) do
    first = Map.get(args, :first, 50)
    after_cursor = Map.get(args, :after)
    types = Map.get(args, :types)
    category = Map.get(args, :category)
    sort = Map.get(args, :sort)

    case resolution.context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        favorites =
          Media.list_user_favorites(user.id)
          |> maybe_filter_by_type(types)
          |> maybe_filter_by_category(category)
          |> sort_items(sort, resolution)

        added_at = RecentlyAdded.added_at_map(ids: Enum.map(favorites, & &1.id))

        all_items =
          Enum.map(favorites, fn item ->
            ItemBuilder.recently_added_item(item, added_at: Map.get(added_at, item.id))
          end)

        items = paginate_simple(all_items, first, after_cursor)
        {:ok, items}
    end
  end

  @spec unwatched(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def unwatched(_parent, args, resolution) do
    first = Map.get(args, :first, 50)
    after_cursor = Map.get(args, :after)
    types = Map.get(args, :types)
    category = Map.get(args, :category)
    sort = Map.get(args, :sort)

    case resolution.context[:current_user] do
      nil ->
        {:ok, []}

      user ->
        opts = [has_files: true]
        opts = if category, do: Keyword.put(opts, :category, to_string(category)), else: opts
        media_items = Media.list_media_items(opts)

        watched_ids =
          Playback.list_user_progress(user.id, watched: true)
          |> Enum.map(& &1.media_item_id)
          |> Enum.reject(&is_nil/1)
          |> MapSet.new()

        unwatched =
          media_items
          |> Enum.reject(&MapSet.member?(watched_ids, &1.id))
          |> maybe_filter_by_type(types)
          |> sort_items(sort, resolution)

        added_at = RecentlyAdded.added_at_map(ids: Enum.map(unwatched, & &1.id))

        all_items =
          Enum.map(unwatched, fn item ->
            ItemBuilder.recently_added_item(item, added_at: Map.get(added_at, item.id))
          end)

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

  defp maybe_filter_by_category(items, nil), do: items

  defp maybe_filter_by_category(items, category),
    do: Enum.filter(items, &(&1.category == to_string(category)))

  # Sorting must run over the whole list before `paginate_simple/3`, whose
  # cursor is a positional offset. `MediaSort` is stable with nil keys last and
  # seeds random with phash2, so page boundaries hold across requests.
  defp sort_items(items, nil, _resolution), do: items

  defp sort_items(items, sort, resolution) do
    user = current_user(resolution)
    effective = MediaSort.effective_sort(sort, user)
    progress = MediaSort.progress_map(user, Map.get(effective, :field))
    MediaSort.sort(items, effective, progress)
  end

  defp current_user(%{context: context}), do: context[:current_user]
  defp current_user(_resolution), do: nil

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

  # `list_recent/1` takes `Enum.take` on this limit BEFORE loading each item's
  # metadata and resolving its latest episode, so the limit here has to cover
  # everything `paginate_simple/3` can slice from — the offset the cursor
  # encodes, plus the page itself — or a page past the first would silently
  # come back empty. Without a limit at all, every mount rebuilds and loads
  # the entire 30-day window just to show `first` cards.
  defp pagination_limit(first, nil), do: first
  defp pagination_limit(first, after_cursor), do: decode_cursor(after_cursor) + 1 + first

  defp build_continue_watching_item(%{media_item_id: media_item_id} = progress, _user_id)
       when not is_nil(media_item_id) do
    media_item = Media.get_media_item!(media_item_id)

    case Library.get_media_files_for_item(media_item_id) do
      [] ->
        nil

      files ->
        %{
          id: media_item.id,
          type: String.to_existing_atom(media_item.type),
          title: media_item.title,
          artwork: ItemBuilder.artwork(media_item),
          progress: format_progress(progress),
          files: files,
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

      files ->
        show = Media.get_media_item!(episode.media_item_id)

        %{
          id: episode.id,
          type: :episode,
          title: episode.title || "Episode #{episode.episode_number}",
          artwork: build_episode_artwork(episode, show),
          progress: format_progress(progress),
          files: files,
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

  defp build_episode_artwork(%{metadata: metadata} = episode, show) when not is_nil(metadata) do
    still_path = MetadataAccess.get(episode.metadata, :still_path)
    show_artwork = ItemBuilder.artwork(show)

    %{
      poster_url: show_artwork && show_artwork.poster_url,
      backdrop_url: show_artwork && show_artwork.backdrop_url,
      thumbnail_url: ImageUrl.still_url(still_path)
    }
  end

  defp build_episode_artwork(_episode, show), do: ItemBuilder.artwork(show)

  defp format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end
end
