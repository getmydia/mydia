defmodule MydiaWeb.Schema.Resolvers.PlaybackResolver do
  @moduledoc """
  Resolvers for playback-related GraphQL mutations.
  """

  alias Mydia.{Media, Playback, Repo}
  alias Mydia.Media.{Episode, MediaItem}

  def update_movie_progress(_parent, args, %{context: context}) do
    %{movie_id: movie_id, position_seconds: position} = args
    duration = Map.get(args, :duration_seconds)

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        attrs =
          %{position_seconds: position}
          |> put_duration(duration, user.id, media_item_id: movie_id)

        case Playback.save_progress(user.id, [media_item_id: movie_id], attrs) do
          {:ok, progress} ->
            formatted_progress = format_progress(progress)

            # Publish subscription event
            Absinthe.Subscription.publish(
              MydiaWeb.Endpoint,
              formatted_progress,
              progress_updated: movie_id
            )

            {:ok, formatted_progress}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  def update_episode_progress(_parent, args, %{context: context}) do
    %{episode_id: episode_id, position_seconds: position} = args
    duration = Map.get(args, :duration_seconds)

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        attrs =
          %{position_seconds: position}
          |> put_duration(duration, user.id, episode_id: episode_id)

        case Playback.save_progress(user.id, [episode_id: episode_id], attrs) do
          {:ok, progress} ->
            formatted_progress = format_progress(progress)

            # Publish subscription event
            Absinthe.Subscription.publish(
              MydiaWeb.Endpoint,
              formatted_progress,
              progress_updated: episode_id
            )

            {:ok, formatted_progress}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  def mark_movie_watched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.mark_watched(user.id, media_item_id: movie_id) do
          {:ok, _progress} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}

          {:error, :not_found} ->
            # Create watched progress if it doesn't exist
            case Playback.save_progress(user.id, [media_item_id: movie_id], %{
                   position_seconds: 0,
                   duration_seconds: 1,
                   watched: true
                 }) do
              {:ok, _} ->
                movie = Media.get_media_item!(movie_id)
                {:ok, Map.put(movie, :added_at, movie.inserted_at)}

              {:error, changeset} ->
                {:error, format_changeset_errors(changeset)}
            end
        end
    end
  end

  def mark_movie_unwatched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.delete_progress(user.id, media_item_id: movie_id) do
          {:ok, _} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}

          {:error, :not_found} ->
            movie = Media.get_media_item!(movie_id)
            {:ok, Map.put(movie, :added_at, movie.inserted_at)}
        end
    end
  end

  def mark_episode_watched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.mark_watched(user.id, episode_id: episode_id) do
          {:ok, _progress} ->
            {:ok, Media.get_episode!(episode_id)}

          {:error, :not_found} ->
            # Create watched progress if it doesn't exist
            case Playback.save_progress(user.id, [episode_id: episode_id], %{
                   position_seconds: 0,
                   duration_seconds: 1,
                   watched: true
                 }) do
              {:ok, _} ->
                {:ok, Media.get_episode!(episode_id)}

              {:error, changeset} ->
                {:error, format_changeset_errors(changeset)}
            end
        end
    end
  end

  def mark_episode_unwatched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Playback.delete_progress(user.id, episode_id: episode_id) do
          {:ok, _} ->
            {:ok, Media.get_episode!(episode_id)}

          {:error, :not_found} ->
            {:ok, Media.get_episode!(episode_id)}
        end
    end
  end

  def mark_season_watched(_parent, %{show_id: show_id, season_number: season_number}, %{
        context: context
      }) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, show} <- load_show(show_id) do
          :ok = Playback.mark_season_watched(user.id, show_id, season_number)
          {:ok, show}
        end
    end
  end

  def mark_season_unwatched(_parent, %{show_id: show_id, season_number: season_number}, %{
        context: context
      }) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, show} <- load_show(show_id),
             :ok <- Playback.mark_season_unwatched(user.id, show_id, season_number) do
          {:ok, show}
        end
    end
  end

  def mark_episodes_up_to_watched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, episode} <- load_episode(episode_id),
             {:ok, show} <- load_show(episode.media_item_id) do
          :ok = Playback.mark_episodes_up_to_watched(user.id, episode_id)
          {:ok, show}
        end
    end
  end

  def toggle_favorite(_parent, %{media_item_id: media_item_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        case Media.toggle_favorite(user.id, media_item_id) do
          {:ok, :added} ->
            {:ok, %{is_favorite: true, media_item_id: media_item_id}}

          {:ok, :removed} ->
            {:ok, %{is_favorite: false, media_item_id: media_item_id}}

          {:error, changeset} ->
            {:error, format_changeset_errors(changeset)}
        end
    end
  end

  # Private helper functions

  # Safe loaders return an error tuple (not a raised 500) for unknown ids.
  defp load_show(show_id) do
    case Repo.get(MediaItem, show_id) do
      nil -> {:error, "Show not found"}
      show -> {:ok, Map.put(show, :added_at, show.inserted_at)}
    end
  end

  defp load_episode(episode_id) do
    case Repo.get(Episode, episode_id) do
      nil -> {:error, "Episode not found"}
      episode -> {:ok, episode}
    end
  end

  defp format_progress(progress) do
    %{
      position_seconds: progress.position_seconds || 0,
      duration_seconds: progress.duration_seconds,
      percentage: progress.completion_percentage,
      watched: progress.watched || false,
      last_watched_at: progress.last_watched_at
    }
  end

  defp format_changeset_errors(%Ecto.Changeset{} = changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  # The GraphQL arg is optional but the changeset requires it, so an omitted
  # duration used to fail validation and drop the write silently. Reuse
  # whatever we already stored instead of rejecting the position.
  #
  # The stored row is fetched only when the client did not send a usable
  # duration. This runs on every progress tick from every playing session, and
  # `save_progress/4` already does its own lookup, so an unconditional fetch
  # here would double the reads on the busiest write path in the app.
  defp put_duration(attrs, duration, _user_id, _content_id)
       when is_integer(duration) and duration > 0 do
    Map.put(attrs, :duration_seconds, duration)
  end

  defp put_duration(attrs, _duration, user_id, content_id) do
    case Playback.get_progress(user_id, content_id) do
      %{duration_seconds: stored} when is_integer(stored) ->
        Map.put(attrs, :duration_seconds, stored)

      _ ->
        attrs
    end
  end
end
