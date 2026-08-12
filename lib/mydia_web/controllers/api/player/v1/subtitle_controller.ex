defmodule MydiaWeb.Api.Player.V1.SubtitleController do
  @moduledoc """
  REST API controller for subtitle management.

  Provides endpoints for:
  - Listing available subtitle tracks (embedded and external)
  - Streaming/downloading subtitle files
  """

  use MydiaWeb, :controller

  import Ecto.Query, only: [from: 2]

  alias Mydia.Library.FileRanking
  alias Mydia.Library.MediaFile
  alias Mydia.Repo
  alias Mydia.Subtitles.Delivery
  alias Mydia.Subtitles.Extractor
  alias Mydia.Subtitles.Subtitle

  require Logger

  @doc """
  Lists all available subtitle tracks for a media file.

  GET /api/player/v1/subtitles/:type/:id

  Parameters:
    - type: "movie", "episode", or "file"
    - id: The media item ID, episode ID, or media file ID

  Returns:
    {
      "data": [
        {
          "track_id": 0,
          "language": "eng",
          "title": "English",
          "format": "srt",
          "embedded": true
        }
      ]
    }

  Status codes:
    - 200: Success
    - 404: Media not found
    - 500: Server error
  """
  def index(conn, %{"type" => type, "id" => id}) do
    case resolve_media_file(type, id) do
      {:ok, media_file} ->
        tracks = Extractor.list_subtitle_tracks(media_file)

        json(conn, %{
          data: tracks
        })

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media not found"})

      {:error, :no_media_files} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media files available"})

      {:error, :invalid_type} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid type. Use 'movie', 'episode', or 'file'"})
    end
  end

  @doc """
  Downloads or streams a specific subtitle track.

  GET /api/player/v1/subtitles/:type/:id/:track

  Parameters:
    - type: "movie", "episode", or "file"
    - id: The media item ID, episode ID, or media file ID
    - track: Track identifier (integer for embedded, UUID for external)

  Query parameters:
    - format: Output format (srt, vtt, ass) - optional, defaults to srt

  Returns:
    - Subtitle content, converted to the requested format, with appropriate Content-Type

  Status codes:
    - 200: Success
    - 400: Unsupported `format` value
    - 404: Media or track not found
    - 415: Track is image-based and cannot be converted to text
    - 500: Extraction failed
  """
  def show(conn, %{"type" => type, "id" => id, "track" => track_param}) do
    format = Map.get(conn.query_params, "format", "srt")
    track_id = parse_track_id(track_param)

    with {:format, true} <- {:format, format in Subtitle.supported_formats()},
         {:media_file, {:ok, media_file}} <- {:media_file, resolve_media_file(type, id)},
         {:track, %{deliverable: true}} <- {:track, find_track(media_file, track_id)} do
      deliver(conn, media_file, track_id, format)
    else
      {:format, false} ->
        conn
        |> put_status(:bad_request)
        |> json(%{
          error:
            "Invalid format. Accepted values: #{Enum.join(Subtitle.supported_formats(), ", ")}"
        })

      {:media_file, {:error, :not_found}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media not found"})

      {:media_file, {:error, :no_media_files}} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "No media files available"})

      {:media_file, {:error, :invalid_type}} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "Invalid type. Use 'movie', 'episode', or 'file'"})

      {:track, nil} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Subtitle track not found"})

      {:track, %{deliverable: false}} ->
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{error: "Image-based subtitles cannot be converted to text"})
    end
  end

  # Resolves the track through the same listing the index action uses, so
  # deliverability (false for image-based embedded tracks) is checked before
  # ever calling Delivery. Delivery has no notion of "this integer track_id
  # is actually a bitmap stream" - it would just hand the id to ffmpeg and
  # fail with an opaque extraction error.
  defp find_track(media_file, track_id) do
    media_file
    |> Extractor.list_subtitle_tracks()
    |> Enum.find(&(&1.track_id == track_id))
  end

  defp deliver(conn, media_file, track_id, format) do
    case Delivery.content(media_file, track_id, format) do
      {:ok, body} ->
        conn
        |> put_resp_header("content-type", get_subtitle_mime_type(format))
        |> put_resp_header(
          "content-disposition",
          "inline; filename=\"subtitle-#{track_id}.#{format}\""
        )
        |> send_resp(200, body)

      {:error, :image_subtitle} ->
        conn
        |> put_status(:unsupported_media_type)
        |> json(%{error: "Image-based subtitles cannot be converted to text"})

      {:error, :subtitle_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Subtitle track not found"})

      {:error, :file_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Subtitle file not found on disk"})

      {:error, :unauthorized} ->
        conn
        |> put_status(:forbidden)
        |> json(%{error: "Unauthorized access to subtitle"})

      {:error, :media_file_not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found on disk"})

      {:error, reason} ->
        Logger.error("Failed to deliver subtitle",
          media_file_id: media_file.id,
          track_id: track_id,
          reason: inspect(reason)
        )

        conn
        |> put_status(:internal_server_error)
        |> json(%{error: "Failed to extract subtitle track"})
    end
  end

  ## Private Functions

  # Resolves a media file from type and ID
  defp resolve_media_file(type, id) do
    case type do
      "movie" ->
        try do
          media_item =
            Mydia.Media.get_media_item!(id, preload: [media_files: active_files_query()])

          case FileRanking.best(media_item.media_files) do
            nil -> {:error, :no_media_files}
            media_file -> {:ok, media_file}
          end
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      "episode" ->
        try do
          episode = Mydia.Media.get_episode!(id, preload: [media_files: active_files_query()])

          case FileRanking.best(episode.media_files) do
            nil -> {:error, :no_media_files}
            media_file -> {:ok, media_file}
          end
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      "file" ->
        try do
          # A trashed file is not a subtitle source, same as the "movie" and
          # "episode" clauses above (see active_files_query/0 below).
          media_file = Repo.get!(active_files_query(), id)
          {:ok, media_file}
        rescue
          Ecto.NoResultsError -> {:error, :not_found}
        end

      _ ->
        {:error, :invalid_type}
    end
  end

  # Mirrors the filter in Mydia.Streaming.Candidates: a trashed file is not a
  # subtitle source.
  defp active_files_query do
    from(mf in MediaFile, where: is_nil(mf.trashed_at), preload: :library_path)
  end

  # Parse track ID from string parameter
  defp parse_track_id(track_param) do
    # Try to parse as integer first (embedded subtitle)
    case Integer.parse(track_param) do
      {int_val, ""} ->
        int_val

      _ ->
        # Not an integer, treat as external subtitle UUID
        track_param
    end
  end

  # Get MIME type for subtitle format
  defp get_subtitle_mime_type("srt"), do: "text/plain; charset=utf-8"
  defp get_subtitle_mime_type("vtt"), do: "text/vtt; charset=utf-8"
  defp get_subtitle_mime_type("ass"), do: "text/plain; charset=utf-8"
  defp get_subtitle_mime_type("ssa"), do: "text/plain; charset=utf-8"
  defp get_subtitle_mime_type(_), do: "text/plain; charset=utf-8"
end
