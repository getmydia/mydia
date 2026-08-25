defmodule MydiaWeb.Api.ThumbnailController do
  @moduledoc """
  Controller for serving video thumbnail sprite sheets and VTT files.

  Provides endpoints for fetching WebVTT files and sprite sheets that enable
  seek preview functionality in video players.
  """

  use MydiaWeb, :controller

  alias Mydia.Library
  alias Mydia.Library.GeneratedMedia
  alias MydiaWeb.MediaAccess

  require Logger

  @doc """
  Serve the WebVTT file for a media file's thumbnails.

  Returns the VTT file that maps timestamps to sprite sheet coordinates.
  Returns 404 if the file doesn't have generated thumbnails.

  ## Example
      GET /api/v1/media/:id/thumbnails.vtt
  """
  def show_vtt(conn, %{"id" => media_file_id}) do
    try do
      media_file = Library.get_media_file!(media_file_id)

      case MediaAccess.authorize_media_file(conn, media_file) do
        :denied ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media file not found"})

        :ok ->
          serve_vtt(conn, media_file)
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found"})
    end
  end

  defp serve_vtt(conn, media_file) do
    if media_file.vtt_blob do
      path = GeneratedMedia.get_path(:vtt, media_file.vtt_blob)

      if File.exists?(path) do
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> put_resp_content_type("text/vtt")
        |> send_file(200, path)
      else
        Logger.warning("VTT file missing for media file #{media_file.id}: #{media_file.vtt_blob}")

        conn
        |> put_status(:not_found)
        |> json(%{error: "VTT file not found on disk"})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "No thumbnails available for this file"})
    end
  end

  @doc """
  Serve the sprite sheet image for a media file's thumbnails.

  Returns the sprite sheet JPEG image containing all thumbnail frames.
  Returns 404 if the file doesn't have generated thumbnails.

  ## Example
      GET /api/v1/media/:id/thumbnails.jpg
  """
  def show_sprite(conn, %{"id" => media_file_id}) do
    try do
      media_file = Library.get_media_file!(media_file_id)

      case MediaAccess.authorize_media_file(conn, media_file) do
        :denied ->
          conn
          |> put_status(:not_found)
          |> json(%{error: "Media file not found"})

        :ok ->
          serve_sprite(conn, media_file)
      end
    rescue
      Ecto.NoResultsError ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "Media file not found"})
    end
  end

  defp serve_sprite(conn, media_file) do
    if media_file.sprite_blob do
      path = GeneratedMedia.get_path(:sprite, media_file.sprite_blob)

      if File.exists?(path) do
        conn
        |> put_resp_header("cache-control", "public, max-age=31536000")
        |> put_resp_content_type("image/jpeg")
        |> send_file(200, path)
      else
        Logger.warning(
          "Sprite file missing for media file #{media_file.id}: #{media_file.sprite_blob}"
        )

        conn
        |> put_status(:not_found)
        |> json(%{error: "Sprite file not found on disk"})
      end
    else
      conn
      |> put_status(:not_found)
      |> json(%{error: "No thumbnails available for this file"})
    end
  end
end
