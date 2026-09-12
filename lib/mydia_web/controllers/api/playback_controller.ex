defmodule MydiaWeb.Api.PlaybackController do
  @moduledoc """
  REST API controller for playback progress tracking.

  Provides endpoints for saving and retrieving video playback progress
  to enable resume functionality and watch tracking across devices.
  """

  use MydiaWeb, :controller

  alias Mydia.{Media, Playback}
  alias Mydia.Auth.Guardian
  require Logger

  @doc """
  Gets playback progress for a movie.

  GET /api/v1/playback/movie/:id

  Returns:
    - 200: Playback progress (or default values if no progress exists)
    - 404: Media item not found
  """
  def show_movie(conn, %{"id" => media_item_id}) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_media_item!(conn.assigns.current_scope, media_item_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media item not found"})

      media_item ->
        if media_item.type != "movie" do
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media item is not a movie"})
        else
          progress = Playback.get_progress(current_user.id, media_item_id: media_item_id)
          json(conn, serialize_progress(progress))
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Media item not found"})
  end

  @doc """
  Gets playback progress for a TV episode.

  GET /api/v1/playback/episode/:id

  Returns:
    - 200: Playback progress (or default values if no progress exists)
    - 404: Episode not found
  """
  def show_episode(conn, %{"id" => episode_id}) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_episode!(conn.assigns.current_scope, episode_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})

      _episode ->
        progress = Playback.get_progress(current_user.id, episode_id: episode_id)
        json(conn, serialize_progress(progress))
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Episode not found"})
  end

  @doc """
  Saves playback progress for a movie.

  POST /api/v1/playback/movie/:id

  Body:
    {
      "position_seconds": 1250,
      "duration_seconds": 5400
    }

  Returns:
    - 200: Updated playback progress
    - 404: Media item not found
    - 422: Invalid data
  """
  def update_movie(conn, %{"id" => media_item_id} = params) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_media_item!(conn.assigns.current_scope, media_item_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media item not found"})

      media_item ->
        if media_item.type != "movie" do
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media item is not a movie"})
        else
          attrs = %{
            position_seconds: params["position_seconds"],
            duration_seconds: params["duration_seconds"]
          }

          case Playback.save_progress(current_user.id, [media_item_id: media_item_id], attrs) do
            {:ok, progress} ->
              Logger.debug("Saved movie playback progress",
                user_id: current_user.id,
                media_item_id: media_item_id,
                position: progress.position_seconds,
                percentage: progress.completion_percentage
              )

              json(conn, serialize_progress(progress))

            {:error, changeset} ->
              conn
              |> put_status(:unprocessable_entity)
              |> json(%{error: "Invalid data", details: format_changeset_errors(changeset)})
          end
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Media item not found"})
  end

  @doc """
  Saves playback progress for a TV episode.

  POST /api/v1/playback/episode/:id

  Body:
    {
      "position_seconds": 1250,
      "duration_seconds": 5400
    }

  Returns:
    - 200: Updated playback progress
    - 404: Episode not found
    - 422: Invalid data
  """
  def update_episode(conn, %{"id" => episode_id} = params) do
    current_user = Guardian.Plug.current_resource(conn)

    case Media.get_episode!(conn.assigns.current_scope, episode_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Episode not found"})

      _episode ->
        attrs = %{
          position_seconds: params["position_seconds"],
          duration_seconds: params["duration_seconds"]
        }

        case Playback.save_progress(current_user.id, [episode_id: episode_id], attrs) do
          {:ok, progress} ->
            Logger.debug("Saved episode playback progress",
              user_id: current_user.id,
              episode_id: episode_id,
              position: progress.position_seconds,
              percentage: progress.completion_percentage
            )

            json(conn, serialize_progress(progress))

          {:error, changeset} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "Invalid data", details: format_changeset_errors(changeset)})
        end
    end
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Episode not found"})
  end

  @doc """
  Gets playback progress for a media file (stub for adult content).

  GET /api/v1/playback/file/:id

  Returns:
    - 200: Default empty progress (progress tracking not implemented for files)
    - 404: Media file not found
  """
  def show_file(conn, %{"id" => media_file_id}) do
    alias Mydia.Library

    # Verify the media file exists
    _media_file = Library.get_media_file!(media_file_id)

    # Return default progress (codec info is now provided by candidates API)
    json(conn, serialize_progress(nil))
  rescue
    Ecto.NoResultsError ->
      conn
      |> put_status(:not_found)
      |> json(%{error: "Media file not found"})
  end

  @doc """
  Saves playback progress for a media file (stub for adult content).

  POST /api/v1/playback/file/:id

  Returns:
    - 200: Acknowledgment (progress is not actually saved)
  """
  def update_file(conn, %{"id" => _media_file_id} = params) do
    # For adult content files, we acknowledge the progress but don't persist it
    # This prevents errors in the video player but doesn't clutter the database
    json(conn, %{
      position_seconds: params["position_seconds"] || 0,
      duration_seconds: params["duration_seconds"],
      completion_percentage: 0,
      watched: false
    })
  end

  ## Private Functions

  defp serialize_progress(nil) do
    %{
      position_seconds: 0,
      duration_seconds: nil,
      completion_percentage: 0,
      watched: false
    }
  end

  defp serialize_progress(progress) do
    %{
      position_seconds: progress.position_seconds,
      duration_seconds: progress.duration_seconds,
      completion_percentage: progress.completion_percentage,
      watched: progress.watched,
      last_watched_at: progress.last_watched_at
    }
  end

  defp format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
