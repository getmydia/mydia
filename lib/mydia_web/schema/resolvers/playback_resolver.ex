defmodule MydiaWeb.Schema.Resolvers.PlaybackResolver do
  @moduledoc """
  Resolvers for playback-related GraphQL mutations.
  """

  alias Mydia.{Media, Playback, Repo}
  alias Mydia.Media.{Episode, MediaItem, Restrictions}

  def update_movie_progress(_parent, args, %{context: context}) do
    %{movie_id: movie_id, position_seconds: position} = args
    duration = Map.get(args, :duration_seconds)

    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, _movie} <- load_movie(context[:current_scope], movie_id) do
          attrs =
            %{position_seconds: position}
            |> put_duration(duration, user.id, media_item_id: movie_id)

          save_and_publish(user.id, [media_item_id: movie_id], attrs, movie_id)
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
        with {:ok, _episode} <- load_episode(context[:current_scope], episode_id) do
          attrs =
            %{position_seconds: position}
            |> put_duration(duration, user.id, episode_id: episode_id)

          save_and_publish(user.id, [episode_id: episode_id], attrs, episode_id)
        end
    end
  end

  defp save_and_publish(user_id, content_id, attrs, node_id) do
    case Playback.save_progress(user_id, content_id, attrs) do
      {:ok, progress} ->
        formatted_progress = format_progress(progress)

        # Publish subscription event
        MydiaWeb.Schema.Publish.publish(
          MydiaWeb.Endpoint,
          formatted_progress,
          progress_updated: node_id
        )

        {:ok, formatted_progress}

      {:error, changeset} ->
        {:error, format_changeset_errors(changeset)}
    end
  end

  def mark_movie_watched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, movie} <- load_movie(context[:current_scope], movie_id),
             :ok <- mark_watched(user.id, media_item_id: movie_id) do
          {:ok, movie}
        end
    end
  end

  def mark_movie_unwatched(_parent, %{movie_id: movie_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, movie} <- load_movie(context[:current_scope], movie_id) do
          Playback.delete_progress(user.id, media_item_id: movie_id)
          {:ok, movie}
        end
    end
  end

  def mark_episode_watched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, episode} <- load_episode(context[:current_scope], episode_id),
             :ok <- mark_watched(user.id, episode_id: episode_id) do
          {:ok, episode}
        end
    end
  end

  def mark_episode_unwatched(_parent, %{episode_id: episode_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, episode} <- load_episode(context[:current_scope], episode_id) do
          Playback.delete_progress(user.id, episode_id: episode_id)
          {:ok, episode}
        end
    end
  end

  # Marks an existing row watched, or creates a watched row when there is none.
  defp mark_watched(user_id, content_id) do
    case Playback.mark_watched(user_id, content_id) do
      {:ok, _progress} ->
        :ok

      {:error, :not_found} ->
        case Playback.save_progress(user_id, content_id, %{
               position_seconds: 0,
               duration_seconds: 1,
               watched: true
             }) do
          {:ok, _} -> :ok
          {:error, changeset} -> {:error, format_changeset_errors(changeset)}
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
        with {:ok, show} <- load_show(context[:current_scope], show_id) do
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
        with {:ok, show} <- load_show(context[:current_scope], show_id),
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
        with {:ok, episode} <- load_episode(context[:current_scope], episode_id),
             {:ok, show} <- load_show(context[:current_scope], episode.media_item_id) do
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
        with {:ok, _item} <-
               load_media_item(context[:current_scope], media_item_id, "Media item not found") do
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
  end

  @doc """
  Hides a movie or show from the viewer's Continue Watching rail.

  `media_item_id` is the movie, or for a series the *show*. The rail carries
  one card per show, so an episode id is not a thing this can take.

  A hide, not an unwatch: progress survives, so the title still offers Resume
  from its detail page, and nothing is pushed out to a media server.
  """
  def remove_from_continue_watching(_parent, %{media_item_id: media_item_id}, %{context: context}) do
    case context[:current_user] do
      nil ->
        {:error, "Authentication required"}

      user ->
        with {:ok, _item} <-
               load_media_item(context[:current_scope], media_item_id, "Media item not found") do
          case Playback.dismiss_from_on_deck(user.id, media_item_id) do
            {:ok, _dismissal} ->
              {:ok, %{media_item_id: media_item_id, removed: true}}

            # Most often an episode id: the rail's cards are episodes, but a
            # card stands for its whole show and that is what gets hidden.
            {:error, :not_found} ->
              {:error, "Media item not found"}

            {:error, changeset} ->
              {:error, format_changeset_errors(changeset)}
          end
        end
    end
  end

  # Private helper functions

  # Safe loaders return an error tuple (not a raised 500) for unknown ids. A
  # title outside the caller's scope reads as unknown, so a restricted account
  # can neither see it nor change its watch state. Every write in this module
  # loads through one of these first.
  defp load_media_item(scope, id, not_found) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         %MediaItem{} = item <- MediaItem |> Restrictions.apply(scope) |> Repo.get(uuid) do
      {:ok, Map.put(item, :added_at, item.inserted_at)}
    else
      _ -> {:error, not_found}
    end
  end

  defp load_show(scope, show_id), do: load_media_item(scope, show_id, "Show not found")
  defp load_movie(scope, movie_id), do: load_media_item(scope, movie_id, "Movie not found")

  defp load_episode(scope, episode_id) do
    with {:ok, uuid} <- Ecto.UUID.cast(episode_id),
         %Episode{} = episode <-
           Episode |> Restrictions.apply_to_episodes(scope) |> Repo.get(uuid) do
      {:ok, episode}
    else
      _ -> {:error, "Episode not found"}
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
