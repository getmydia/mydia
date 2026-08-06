defmodule MydiaWeb.Schema.Resolvers.MediaResolver do
  @moduledoc """
  Resolvers for media-related GraphQL fields.
  """

  alias Mydia.{Media, Library, Playback}

  alias Mydia.Metadata.Access, as: MetadataAccess
  alias Mydia.Metadata.ImageUrl
  alias Mydia.Metadata.Structs.Video
  alias Mydia.Repo

  # Detections below this floor are persisted, so the operator can see and
  # diagnose them, but are not shown to players. 0.4 is exactly 2 agreeing
  # partners out of 5 attempted, the lowest value the detection acceptance rule
  # can produce, so the floor admits every accepted detection while still
  # leaving room to raise it from field reports without re-analyzing anything.
  # A 0.5 floor would discard every minimum-consensus detection and make the
  # acceptance rule unreachable in practice.
  @segment_confidence_floor 0.4

  # Movie and TVShow field resolvers

  @spec resolve_overview(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_overview(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :overview)}
  end

  @spec resolve_runtime(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_runtime(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :runtime)}
  end

  @spec resolve_genres(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_genres(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :genres) || []}
  end

  @spec resolve_content_rating(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_content_rating(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :content_rating)}
  end

  @spec resolve_trailer_url(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_trailer_url(parent, _args, _info) do
    videos = MetadataAccess.get_field(parent, :videos) || []

    url =
      case List.first(videos) do
        nil -> nil
        video -> Video.youtube_watch_url(video)
      end

    {:ok, url}
  end

  @spec resolve_rating(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_rating(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :vote_average)}
  end

  @spec resolve_status(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_status(parent, _args, _info) do
    {:ok, MetadataAccess.get_field(parent, :status)}
  end

  @spec resolve_category(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_category(%{category: category}, _args, _info) when is_binary(category) do
    {:ok, String.to_existing_atom(category)}
  end

  def resolve_category(%{category: category}, _args, _info) when is_atom(category) do
    {:ok, category}
  end

  def resolve_category(_parent, _args, _info), do: {:ok, nil}

  @spec resolve_artwork(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_artwork(%{metadata: metadata} = _parent, _args, _info) do
    poster_path = MetadataAccess.get(metadata, :poster_path)
    backdrop_path = MetadataAccess.get(metadata, :backdrop_path)

    artwork = %{
      poster_url: ImageUrl.poster_url(poster_path),
      backdrop_url: ImageUrl.backdrop_url(backdrop_path),
      thumbnail_url: nil
    }

    {:ok, artwork}
  end

  def resolve_artwork(_parent, _args, _info), do: {:ok, nil}

  # Movie-specific resolvers

  @spec resolve_movie_files(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_movie_files(%{id: media_item_id}, _args, _info) do
    files = Library.get_media_files_for_item(media_item_id)
    {:ok, files}
  end

  @spec resolve_progress(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_progress(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, nil}

      user ->
        case Playback.get_progress(user.id, media_item_id: media_item_id) do
          nil ->
            {:ok, nil}

          progress ->
            {:ok, format_progress(progress)}
        end
    end
  end

  # TV Show-specific resolvers

  @spec resolve_seasons(map(), map(), Absinthe.Resolution.t()) :: {:ok, term()} | {:error, term()}
  def resolve_seasons(%{id: media_item_id}, _args, _info) do
    # Get all episodes and group by season
    episodes = Media.list_episodes(media_item_id)

    seasons =
      episodes
      |> Enum.group_by(& &1.season_number)
      |> Enum.map(fn {season_number, season_episodes} ->
        # Check if any episode has files
        has_files =
          Enum.any?(season_episodes, fn ep ->
            files = Library.get_media_files_for_episode(ep.id)
            files != []
          end)

        # Count aired episodes (air_date is in the past)
        today = Date.utc_today()

        aired_count =
          Enum.count(season_episodes, fn ep ->
            ep.air_date != nil and Date.compare(ep.air_date, today) != :gt
          end)

        %{
          season_number: season_number,
          episode_count: length(season_episodes),
          aired_episode_count: aired_count,
          has_files: has_files,
          # Store episodes for nested resolution
          _episodes: season_episodes,
          _media_item_id: media_item_id
        }
      end)
      |> Enum.sort_by(& &1.season_number)

    {:ok, seasons}
  end

  @spec resolve_season_count(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_season_count(%{id: media_item_id}, _args, _info) do
    episodes = Media.list_episodes(media_item_id)

    season_count =
      episodes
      |> Enum.map(& &1.season_number)
      |> Enum.uniq()
      |> length()

    {:ok, season_count}
  end

  @spec resolve_episode_count(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_count(%{id: media_item_id}, _args, _info) do
    episodes = Media.list_episodes(media_item_id)
    {:ok, length(episodes)}
  end

  @spec resolve_next_episode(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_next_episode(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        # Return first episode if no user
        case Media.list_episodes(media_item_id) do
          [] -> {:ok, nil}
          [first | _] -> {:ok, first}
        end

      user ->
        case Playback.get_next_episode(media_item_id, user.id) do
          nil -> {:ok, nil}
          :all_watched -> {:ok, nil}
          {_state, episode} -> {:ok, episode}
        end
    end
  end

  @spec resolve_next_up(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_next_up(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        # Mirrors resolve_next_episode/3 so the two fields never disagree.
        case Media.list_episodes(media_item_id) do
          [] -> {:ok, nil}
          [first | _] -> {:ok, %{episode: first, progress_state: "start"}}
        end

      user ->
        case Playback.get_next_episode(media_item_id, user.id) do
          nil -> {:ok, nil}
          :all_watched -> {:ok, nil}
          {state, episode} -> {:ok, %{episode: episode, progress_state: Atom.to_string(state)}}
        end
    end
  end

  # Season resolver for episodes
  @spec resolve_season_episodes(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_season_episodes(%{_episodes: episodes}, _args, _info) when is_list(episodes) do
    sorted = Enum.sort_by(episodes, & &1.episode_number)
    {:ok, sorted}
  end

  def resolve_season_episodes(
        %{season_number: season_number, _media_item_id: media_item_id},
        _args,
        _info
      ) do
    episodes =
      Media.list_episodes(media_item_id)
      |> Enum.filter(&(&1.season_number == season_number))
      |> Enum.sort_by(& &1.episode_number)

    {:ok, episodes}
  end

  # Episode-specific resolvers

  @spec resolve_episode_overview(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_overview(%{metadata: metadata}, _args, _info) do
    {:ok, MetadataAccess.get(metadata, :overview)}
  end

  def resolve_episode_overview(_episode, _args, _info), do: {:ok, nil}

  @spec resolve_episode_runtime(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_runtime(%{metadata: metadata}, _args, _info) do
    {:ok, MetadataAccess.get(metadata, :runtime)}
  end

  def resolve_episode_runtime(_episode, _args, _info), do: {:ok, nil}

  @spec resolve_episode_thumbnail(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_thumbnail(%{metadata: metadata}, _args, _info) do
    still_path = MetadataAccess.get(metadata, :still_path)
    {:ok, ImageUrl.still_url(still_path)}
  end

  def resolve_episode_thumbnail(_episode, _args, _info), do: {:ok, nil}

  @spec resolve_episode_files(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_files(%{id: episode_id}, _args, _info) do
    files = Library.get_media_files_for_episode(episode_id)
    {:ok, files}
  end

  @spec resolve_episode_progress(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_episode_progress(%{id: episode_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, nil}

      user ->
        case Playback.get_progress(user.id, episode_id: episode_id) do
          nil ->
            {:ok, nil}

          progress ->
            {:ok, format_progress(progress)}
        end
    end
  end

  @spec resolve_has_file(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_has_file(%{id: episode_id}, _args, _info) do
    files = Library.get_media_files_for_episode(episode_id)
    {:ok, files != []}
  end

  @spec resolve_parent_show(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_parent_show(%{media_item_id: media_item_id}, _args, _info)
      when not is_nil(media_item_id) do
    show = Media.get_media_item!(media_item_id)
    {:ok, Map.put(show, :added_at, show.inserted_at)}
  rescue
    Ecto.NoResultsError -> {:ok, nil}
  end

  def resolve_parent_show(_episode, _args, _info), do: {:ok, nil}

  # Helper functions

  defp format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end

  # Favorites resolver

  @spec resolve_is_favorite(map(), map(), Absinthe.Resolution.t()) ::
          {:ok, term()} | {:error, term()}
  def resolve_is_favorite(%{id: media_item_id}, _args, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:ok, false}

      user ->
        {:ok, Media.is_favorite?(user.id, media_item_id)}
    end
  end

  # Skippable segments

  @doc """
  Resolves the skippable segments of a media file.
  """
  @spec segments(map(), map(), Absinthe.Resolution.t()) :: {:ok, [Library.MediaSegment.t()]}
  def segments(media_file, _args, _info) do
    {:ok, visible_segments(media_file)}
  end

  @doc """
  Filters persisted segments down to the ones trustworthy enough to show a viewer.

  The floor is a single condition on `confidence`, with no exception by
  `source`. Chapter-sourced segments clear it because the detection pipeline
  writes chapter matches at confidence 1.0, not because this function treats
  them specially.

  That uniformity is deliberate. Exposure stays one rule in one place, which is
  the same reason `confidence` and `source` never reach the player. And a
  chapter segment that somehow lands below the floor vanishing from the wire is
  the signal you want, because it means something wrote it wrong; a bypass on
  `source` would mask precisely that.

  Public so the confidence floor can be exercised directly in tests.
  """
  @spec visible_segments(map()) :: [Library.MediaSegment.t()]
  def visible_segments(%{segments: %Ecto.Association.NotLoaded{}} = media_file) do
    media_file |> Repo.preload(:segments) |> visible_segments()
  end

  def visible_segments(%{segments: segments}) when is_list(segments) do
    segments
    |> Enum.filter(&(&1.confidence >= @segment_confidence_floor))
    |> Enum.sort_by(& &1.start_ms)
  end

  def visible_segments(_media_file), do: []
end
