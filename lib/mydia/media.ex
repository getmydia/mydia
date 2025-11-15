defmodule Mydia.Media do
  @moduledoc """
  The Media context handles movies, TV shows, and episodes.
  """

  import Ecto.Query, warn: false
  require Logger
  alias Mydia.Repo
  alias Mydia.Media.{MediaItem, Episode}
  alias Mydia.Media.Structs.CalendarEntry
  alias Mydia.Events

  ## Media Items

  @doc """
  Returns the list of media items.

  ## Options
    - `:type` - Filter by type ("movie" or "tv_show")
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  def list_media_items(opts \\ []) do
    MediaItem
    |> apply_media_item_filters(opts)
    |> maybe_preload(opts[:preload])
    |> Repo.all()
  end

  @doc """
  Gets a single media item.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the media item does not exist.
  """
  def get_media_item!(id, opts \\ []) do
    MediaItem
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single media item by TMDB ID.
  """
  def get_media_item_by_tmdb(tmdb_id, opts \\ []) do
    MediaItem
    |> where([m], m.tmdb_id == ^tmdb_id)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Creates a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  def create_media_item(attrs \\ %{}, opts \\ []) do
    with {:ok, media_item} <-
           %MediaItem{}
           |> MediaItem.changeset(attrs)
           |> Repo.insert() do
      # Track event
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")

      Events.media_item_added(media_item, actor_type, actor_id)

      # Execute after_media_added hooks asynchronously
      Mydia.Hooks.execute_async("after_media_added", %{
        media_item: serialize_media_item(media_item)
      })

      {:ok, media_item}
    end
  end

  @doc """
  Updates a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  def update_media_item(%MediaItem{} = media_item, attrs, opts \\ []) do
    result =
      media_item
      |> MediaItem.changeset(attrs)
      |> Repo.update()

    case result do
      {:ok, updated_media_item} ->
        # Track event
        actor_type = Keyword.get(opts, :actor_type, :system)
        actor_id = Keyword.get(opts, :actor_id, "media_context")

        Events.media_item_updated(updated_media_item, actor_type, actor_id)

        {:ok, updated_media_item}

      error ->
        error
    end
  end

  @doc """
  Deletes a media item.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  When `:delete_files` is true, will delete all associated media files from disk
  before removing the database records. When false (default), only removes database
  records and preserves files on disk.
  """
  def delete_media_item(%MediaItem{} = media_item, opts \\ []) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Logger.info("delete_media_item called",
      media_item_id: media_item.id,
      title: media_item.title,
      delete_files: delete_files
    )

    # If we need to delete files, load all media files first
    # (including files from episodes for TV shows)
    if delete_files do
      # Load media item with all media files (both direct and through episodes)
      media_item_with_files =
        MediaItem
        |> where([m], m.id == ^media_item.id)
        |> preload([:media_files, episodes: :media_files])
        |> Repo.one!()

      # Collect all media files (movie files + episode files)
      all_media_files =
        media_item_with_files.media_files ++
          Enum.flat_map(media_item_with_files.episodes, & &1.media_files)

      Logger.info("Attempting to delete physical files",
        media_item_id: media_item.id,
        file_count: length(all_media_files),
        file_paths: Enum.map(all_media_files, & &1.path)
      )

      # Delete physical files from disk
      case Mydia.Library.delete_media_files_from_disk(all_media_files) do
        {:ok, success_count, error_count} ->
          Logger.info("Deleted #{success_count} files from disk (#{error_count} errors)",
            media_item_id: media_item.id,
            title: media_item.title
          )

        {:error, reason} ->
          Logger.error("Failed to delete files from disk",
            media_item_id: media_item.id,
            reason: inspect(reason)
          )
      end
    else
      Logger.info("Skipping file deletion (delete_files=false)",
        media_item_id: media_item.id,
        title: media_item.title
      )
    end

    # Track event before deletion (we need the media_item data)
    actor_type = Keyword.get(opts, :actor_type, :system)
    actor_id = Keyword.get(opts, :actor_id, "media_context")

    Events.media_item_removed(media_item, actor_type, actor_id)

    # Delete the media item (and cascade delete all related DB records)
    Repo.delete(media_item)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking media item changes.
  """
  def change_media_item(%MediaItem{} = media_item, attrs \\ %{}) do
    MediaItem.changeset(media_item, attrs)
  end

  @doc """
  Updates the monitored status for multiple media items.

  Returns `{:ok, count}` where count is the number of updated items,
  or `{:error, reason}` if the transaction fails.

  ## Options
    - `:actor_type` - The type of actor (:user, :system, :job) - defaults to :system
    - `:actor_id` - The ID of the actor (user_id, job name, etc.)
  """
  def update_media_items_monitored(ids, monitored, opts \\ []) when is_list(ids) do
    Repo.transaction(fn ->
      # Fetch media items before update to track events
      media_items =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.all()

      # Perform the update
      {count, _} =
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])

      # Track events for each media item
      actor_type = Keyword.get(opts, :actor_type, :system)
      actor_id = Keyword.get(opts, :actor_id, "media_context")

      Enum.each(media_items, fn media_item ->
        Events.media_item_monitoring_changed(media_item, monitored, actor_type, actor_id)
      end)

      count
    end)
  end

  @doc """
  Updates multiple media items with the given attributes in a transaction.

  Only updates non-nil attributes. Returns `{:ok, count}` on success
  where count is the number of updated items.
  """
  def update_media_items_batch(ids, attrs) when is_list(ids) and is_map(attrs) do
    Repo.transaction(fn ->
      # Build the update list, only including non-nil values
      updates =
        attrs
        |> Enum.reject(fn {_key, value} -> is_nil(value) end)
        |> Enum.into(%{})
        |> Map.put(:updated_at, DateTime.utc_now())

      if map_size(updates) > 1 do
        # More than just updated_at
        MediaItem
        |> where([m], m.id in ^ids)
        |> Repo.update_all(set: Map.to_list(updates))
        |> elem(0)
      else
        0
      end
    end)
  end

  @doc """
  Deletes multiple media items in a transaction.

  ## Options
    - `:delete_files` - Whether to delete physical files from disk (default: false)

  Returns `{:ok, count}` where count is the number of deleted items,
  or `{:error, reason}` if the transaction fails.

  When `:delete_files` is true, will delete all associated media files from disk
  before removing the database records. When false (default), only removes database
  records and preserves files on disk.
  """
  def delete_media_items(ids, opts \\ []) when is_list(ids) do
    delete_files = Keyword.get(opts, :delete_files, false)

    Repo.transaction(fn ->
      # If we need to delete files, load all media files first
      if delete_files do
        # Load all media items with their files
        media_items =
          MediaItem
          |> where([m], m.id in ^ids)
          |> preload([:media_files, episodes: :media_files])
          |> Repo.all()

        # Collect all media files from all items
        all_media_files =
          Enum.flat_map(media_items, fn item ->
            item.media_files ++ Enum.flat_map(item.episodes, & &1.media_files)
          end)

        # Delete physical files from disk
        case Mydia.Library.delete_media_files_from_disk(all_media_files) do
          {:ok, success_count, error_count} ->
            Logger.info(
              "Batch deleted #{success_count} files from disk (#{error_count} errors)",
              media_item_count: length(media_items)
            )

          {:error, reason} ->
            Logger.error("Failed to batch delete files from disk",
              reason: inspect(reason)
            )
        end
      end

      # Delete the media items (and cascade delete all related DB records)
      MediaItem
      |> where([m], m.id in ^ids)
      |> Repo.delete_all()
      |> elem(0)
    end)
  end

  @doc """
  Returns the count of movies in the library.
  """
  def count_movies do
    MediaItem
    |> where([m], m.type == "movie")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns the count of TV shows in the library.
  """
  def count_tv_shows do
    MediaItem
    |> where([m], m.type == "tv_show")
    |> Repo.aggregate(:count)
  end

  @doc """
  Returns a map of TMDB IDs to library status for efficient lookup.

  Returns a map where keys are TMDB IDs and values are maps with:
  - `:in_library` - boolean
  - `:monitored` - boolean (if in library)
  - `:type` - "movie" or "tv_show" (if in library)
  - `:id` - database ID (if in library)

  ## Examples

      iex> get_library_status_map()
      %{
        "12345" => %{in_library: true, monitored: true, type: "movie", id: 1},
        "67890" => %{in_library: true, monitored: false, type: "tv_show", id: 2}
      }
  """
  def get_library_status_map do
    MediaItem
    |> select(
      [m],
      {m.tmdb_id, %{in_library: true, monitored: m.monitored, type: m.type, id: m.id}}
    )
    |> where([m], not is_nil(m.tmdb_id))
    |> Repo.all()
    |> Map.new()
  end

  ## Episodes

  @doc """
  Returns the list of episodes for a media item.

  ## Options
    - `:season` - Filter by season number
    - `:monitored` - Filter by monitored status (true/false)
    - `:preload` - List of associations to preload
  """
  def list_episodes(media_item_id, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> apply_episode_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([e], asc: e.season_number, asc: e.episode_number)
    |> Repo.all()
  end

  @doc """
  Gets a single episode.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the episode does not exist.
  """
  def get_episode!(id, opts \\ []) do
    Episode
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Gets a single episode by media item ID, season, and episode number.
  """
  def get_episode_by_number(media_item_id, season_number, episode_number, opts \\ []) do
    Episode
    |> where([e], e.media_item_id == ^media_item_id)
    |> where([e], e.season_number == ^season_number)
    |> where([e], e.episode_number == ^episode_number)
    |> maybe_preload(opts[:preload])
    |> Repo.one()
  end

  @doc """
  Gets the next episode for the given episode.
  Returns the next episode in the same season if available,
  otherwise returns the first episode of the next season.
  Returns nil if there is no next episode.
  """
  def get_next_episode(%Episode{} = episode, opts \\ []) do
    # Try to get next episode in same season first
    next_in_season =
      Episode
      |> where([e], e.media_item_id == ^episode.media_item_id)
      |> where([e], e.season_number == ^episode.season_number)
      |> where([e], e.episode_number > ^episode.episode_number)
      |> order_by([e], asc: e.episode_number)
      |> limit(1)
      |> maybe_preload(opts[:preload])
      |> Repo.one()

    case next_in_season do
      nil ->
        # No more episodes in current season, try next season
        Episode
        |> where([e], e.media_item_id == ^episode.media_item_id)
        |> where([e], e.season_number > ^episode.season_number)
        |> order_by([e], asc: e.season_number, asc: e.episode_number)
        |> limit(1)
        |> maybe_preload(opts[:preload])
        |> Repo.one()

      episode ->
        episode
    end
  end

  @doc """
  Creates an episode.
  """
  def create_episode(attrs \\ %{}) do
    %Episode{}
    |> Episode.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates an episode.
  """
  def update_episode(%Episode{} = episode, attrs) do
    episode
    |> Episode.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the monitored status for all episodes in a season.

  Returns `{:ok, count}` where count is the number of updated episodes,
  or `{:error, reason}` if the transaction fails.

  ## Examples

      iex> update_season_monitoring(media_item_id, 1, true)
      {:ok, 12}

      iex> update_season_monitoring(media_item_id, 2, false)
      {:ok, 8}
  """
  def update_season_monitoring(media_item_id, season_number, monitored)
      when is_boolean(monitored) do
    Repo.transaction(fn ->
      Episode
      |> where([e], e.media_item_id == ^media_item_id)
      |> where([e], e.season_number == ^season_number)
      |> Repo.update_all(set: [monitored: monitored, updated_at: DateTime.utc_now()])
      |> elem(0)
    end)
  end

  @doc """
  Deletes an episode.
  """
  def delete_episode(%Episode{} = episode) do
    Repo.delete(episode)
  end

  @doc """
  Returns an `%Ecto.Changeset{}` for tracking episode changes.
  """
  def change_episode(%Episode{} = episode, attrs \\ %{}) do
    Episode.changeset(episode, attrs)
  end

  @doc """
  Gets aggregate status for a media item (TV show or movie).

  For TV shows, returns status based on all episodes:
  - `:not_monitored` - Media item not monitored
  - `:downloaded` - All monitored episodes downloaded
  - `:partial` - Some episodes downloaded, some missing
  - `:downloading` - Has active downloads
  - `:missing` - No episodes downloaded
  - `:upcoming` - All episodes are upcoming

  For movies, returns simple status based on media files and downloads.

  Returns tuple: `{status, %{downloaded: count, total: count}}` for TV shows
  or `{status, nil}` for movies.

  ## Examples

      iex> get_media_status(%MediaItem{type: "tv_show", monitored: true, episodes: [...]})
      {:partial, %{downloaded: 5, total: 24}}

      iex> get_media_status(%MediaItem{type: "movie", monitored: true})
      {:downloaded, nil}
  """
  def get_media_status(%MediaItem{type: "movie", monitored: false} = media_item) do
    # For non-monitored movies, include file count information
    file_count = length(media_item.media_files)
    {:not_monitored, %{has_files: file_count > 0, file_count: file_count}}
  end

  def get_media_status(%MediaItem{type: "movie"} = media_item) do
    has_files = length(media_item.media_files) > 0

    has_downloads =
      length(media_item.downloads) > 0 &&
        Enum.any?(media_item.downloads, &download_active?/1)

    status =
      cond do
        has_files -> :downloaded
        has_downloads -> :downloading
        true -> :missing
      end

    {status, nil}
  end

  def get_media_status(%MediaItem{type: "tv_show", monitored: false, episodes: episodes}) do
    # For non-monitored TV shows, still show episode counts
    total_episodes = length(episodes)
    downloaded_count = Enum.count(episodes, fn ep -> length(ep.media_files) > 0 end)

    {:not_monitored, %{downloaded: downloaded_count, total: total_episodes}}
  end

  def get_media_status(%MediaItem{type: "tv_show", episodes: episodes}) do
    monitored_episodes = Enum.filter(episodes, & &1.monitored)
    total_monitored = length(monitored_episodes)

    if total_monitored == 0 do
      # No monitored episodes - show all episodes count instead
      total_episodes = length(episodes)
      downloaded_count = Enum.count(episodes, fn ep -> length(ep.media_files) > 0 end)
      {:not_monitored, %{downloaded: downloaded_count, total: total_episodes}}
    else
      downloaded_count =
        monitored_episodes
        |> Enum.count(fn ep -> length(ep.media_files) > 0 end)

      has_active_downloads =
        monitored_episodes
        |> Enum.any?(fn ep ->
          Enum.any?(ep.downloads, &download_active?/1)
        end)

      all_upcoming =
        monitored_episodes
        |> Enum.all?(fn ep ->
          ep.air_date && Date.compare(ep.air_date, Date.utc_today()) == :gt
        end)

      status =
        cond do
          downloaded_count == total_monitored -> :downloaded
          has_active_downloads -> :downloading
          all_upcoming -> :upcoming
          downloaded_count > 0 -> :partial
          true -> :missing
        end

      {status, %{downloaded: downloaded_count, total: total_monitored}}
    end
  end

  @doc """
  Refreshes episodes for a TV show by fetching metadata and creating missing episodes.

  This function is useful for:
  - TV shows added before season metadata was included
  - Manually refreshing episodes when new seasons are available
  - Fixing TV shows with missing episode data

  ## Parameters
    - `media_item` - The TV show media item (must be type "tv_show")
    - `opts` - Options for episode creation
      - `:season_monitoring` - Which seasons to fetch ("all", "first", "latest", "none")
      - `:force` - If true, will delete and recreate all episodes (default: false)

  ## Returns
    - `{:ok, count}` - Number of episodes created
    - `{:error, reason}` - Error reason

  ## Examples

      iex> refresh_episodes_for_tv_show(media_item)
      {:ok, 236}

      iex> refresh_episodes_for_tv_show(media_item, season_monitoring: "latest")
      {:ok, 12}
  """
  def refresh_episodes_for_tv_show(media_item, opts \\ [])

  def refresh_episodes_for_tv_show(%MediaItem{type: "tv_show"} = media_item, opts) do
    alias Mydia.Metadata

    season_monitoring = Keyword.get(opts, :season_monitoring, "all")
    force = Keyword.get(opts, :force, false)

    # Get TMDB ID from metadata
    tmdb_id =
      case media_item.metadata do
        %{"provider_id" => id} when is_binary(id) -> id
        _ -> media_item.tmdb_id
      end

    if is_nil(tmdb_id) or tmdb_id == "" do
      {:error, :missing_tmdb_id}
    else
      # Fetch fresh metadata to get seasons info
      config = Metadata.default_relay_config()

      case Metadata.fetch_by_id(config, to_string(tmdb_id), media_type: :tv_show) do
        {:ok, metadata} ->
          # Delete existing episodes if force option is enabled
          if force do
            Episode
            |> where([e], e.media_item_id == ^media_item.id)
            |> Repo.delete_all()
          end

          # Get seasons from metadata (using atom key since metadata comes from provider)
          seasons = metadata[:seasons] || []

          Logger.info(
            "Fetching episodes for TV show: #{media_item.title}, found #{length(seasons)} seasons in metadata"
          )

          # Filter seasons based on monitoring preference
          seasons_to_fetch =
            case season_monitoring do
              "all" -> seasons
              "first" -> Enum.take(seasons, 1)
              "latest" -> Enum.take(seasons, -1)
              "none" -> []
              _ -> seasons
            end

          # Fetch and create episodes for each season
          episode_count =
            Enum.reduce(seasons_to_fetch, 0, fn season, count ->
              # Skip season 0 (specials) unless explicitly monitoring all
              if season.season_number == 0 and season_monitoring != "all" do
                count
              else
                Logger.info("Processing episodes for season #{season.season_number}")

                case create_episodes_for_season(media_item, season, config, force) do
                  {:ok, created} ->
                    Logger.info(
                      "Processed #{created} episodes for season #{season.season_number}"
                    )

                    count + created

                  {:error, reason} ->
                    Logger.error(
                      "Failed to create episodes for season #{season.season_number}: #{inspect(reason)}"
                    )

                    count
                end
              end
            end)

          Logger.info("Total episodes processed: #{episode_count}")
          {:ok, episode_count}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  def refresh_episodes_for_tv_show(%MediaItem{type: type}, _opts) do
    {:error, {:invalid_type, "Expected tv_show, got #{type}"}}
  end

  ## Calendar

  @doc """
  Returns episodes with air dates in the specified date range.
  Only returns episodes for monitored media items by default.

  ## Options
    - `:preload` - List of associations to preload
    - `:monitored` - Filter by media item monitored status (default: true)
  """
  def list_episodes_by_air_date(start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    Episode
    |> join(:inner, [e], m in MediaItem, on: e.media_item_id == m.id)
    |> where([e, m], not is_nil(e.air_date))
    |> where([e, m], e.air_date >= ^start_date and e.air_date <= ^end_date)
    |> where([e, m], m.monitored == ^monitored)
    |> select([e, m], %{
      id: e.id,
      type: "episode",
      air_date: e.air_date,
      title: e.title,
      season_number: e.season_number,
      episode_number: e.episode_number,
      media_item_id: m.id,
      media_item_title: m.title,
      media_item_type: m.type,
      has_files:
        fragment(
          "CASE WHEN EXISTS(SELECT 1 FROM media_files WHERE episode_id = ?) THEN true ELSE false END",
          e.id
        ),
      has_downloads:
        fragment(
          "CASE WHEN EXISTS(SELECT 1 FROM downloads WHERE episode_id = ?) THEN true ELSE false END",
          e.id
        )
    })
    |> order_by([e, m], asc: e.air_date, asc: m.title)
    |> Repo.all()
    |> Enum.map(fn entry ->
      CalendarEntry.new_episode(
        id: entry.id,
        air_date: entry.air_date,
        title: entry.title,
        season_number: entry.season_number,
        episode_number: entry.episode_number,
        media_item_id: entry.media_item_id,
        media_item_title: entry.media_item_title,
        media_item_type: entry.media_item_type,
        has_files: entry.has_files,
        has_downloads: entry.has_downloads
      )
    end)
  end

  @doc """
  Returns monitored movies with release dates in the specified date range from metadata.
  Movies must have a release_date in their metadata field.

  ## Options
    - `:monitored` - Filter by monitored status (default: true)
  """
  def list_movies_by_release_date(start_date, end_date, opts \\ []) do
    monitored = Keyword.get(opts, :monitored, true)

    MediaItem
    |> where([m], m.type == "movie")
    |> where([m], m.monitored == ^monitored)
    |> where([m], not is_nil(fragment("?->>'release_date'", m.metadata)))
    |> Repo.all()
    |> Enum.filter(fn item ->
      case item.metadata do
        %{"release_date" => date_str} when is_binary(date_str) ->
          case Date.from_iso8601(date_str) do
            {:ok, date} ->
              Date.compare(date, start_date) != :lt and Date.compare(date, end_date) != :gt

            _ ->
              false
          end

        _ ->
          false
      end
    end)
    |> Enum.map(fn item ->
      {:ok, release_date} = Date.from_iso8601(item.metadata["release_date"])

      has_files =
        Repo.exists?(from f in Mydia.Library.MediaFile, where: f.media_item_id == ^item.id)

      has_downloads =
        Repo.exists?(from d in Mydia.Downloads.Download, where: d.media_item_id == ^item.id)

      CalendarEntry.new_movie(
        id: item.id,
        air_date: release_date,
        title: item.title,
        media_item_id: item.id,
        media_item_title: item.title,
        media_item_type: item.type,
        has_files: has_files,
        has_downloads: has_downloads
      )
    end)
  end

  ## Private Functions

  defp create_episodes_for_season(media_item, season, config, force) do
    alias Mydia.Metadata

    # Fetch season details with episodes
    tmdb_id =
      case media_item.metadata do
        %{"provider_id" => id} when is_binary(id) -> id
        _ -> media_item.tmdb_id
      end

    case Metadata.fetch_season(config, to_string(tmdb_id), season.season_number) do
      {:ok, season_data} ->
        episodes = season_data.episodes || []

        created_count =
          Enum.reduce(episodes, 0, fn episode, count ->
            season_num = episode.season_number
            episode_num = episode.episode_number

            # Skip if season or episode number is nil
            if is_nil(season_num) or is_nil(episode_num) do
              count
            else
              # Check if episode already exists (unless force is enabled)
              existing =
                if force do
                  nil
                else
                  get_episode_by_number(
                    media_item.id,
                    season_num,
                    episode_num
                  )
                end

              if is_nil(existing) do
                case create_episode(%{
                       media_item_id: media_item.id,
                       season_number: season_num,
                       episode_number: episode_num,
                       title: episode.name,
                       air_date: parse_air_date(episode.air_date),
                       metadata: episode,
                       monitored: media_item.monitored
                     }) do
                  {:ok, _episode} -> count + 1
                  {:error, _changeset} -> count
                end
              else
                # Update existing episode with fresh metadata
                case update_episode(existing, %{
                       title: episode.name,
                       air_date: parse_air_date(episode.air_date),
                       metadata: episode
                     }) do
                  {:ok, _episode} -> count + 1
                  {:error, _changeset} -> count
                end
              end
            end
          end)

        {:ok, created_count}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_air_date(nil), do: nil
  defp parse_air_date(%Date{} = date), do: date

  defp parse_air_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> nil
    end
  end

  defp parse_air_date(_), do: nil

  defp apply_media_item_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:type, type}, query ->
        where(query, [m], m.type == ^type)

      {:monitored, monitored}, query ->
        where(query, [m], m.monitored == ^monitored)

      _other, query ->
        query
    end)
  end

  defp apply_episode_filters(query, opts) do
    Enum.reduce(opts, query, fn
      {:season, season}, query ->
        where(query, [e], e.season_number == ^season)

      {:monitored, monitored}, query ->
        where(query, [e], e.monitored == ^monitored)

      _other, query ->
        query
    end)
  end

  defp maybe_preload(query, nil), do: query
  defp maybe_preload(query, []), do: query
  defp maybe_preload(query, preloads), do: preload(query, ^preloads)

  # Helper function to check if a download is active
  # Downloads are active if they haven't completed and haven't failed
  defp download_active?(download) do
    is_nil(download.completed_at) && is_nil(download.error_message)
  end

  # Serialize media item for hooks
  defp serialize_media_item(%MediaItem{} = media_item) do
    %{
      id: media_item.id,
      type: media_item.type,
      title: media_item.title,
      tmdb_id: media_item.tmdb_id,
      year: media_item.year,
      monitored: media_item.monitored,
      metadata: media_item.metadata
    }
  end
end
