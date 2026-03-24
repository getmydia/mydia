defmodule MydiaWeb.AdultLive.Show do
  @moduledoc """
  LiveView for viewing individual adult media files with video player and metadata.
  """

  use MydiaWeb, :live_view

  alias Mydia.Library
  alias Mydia.Library.{MediaFile, ThumbnailGenerator}

  require Logger

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    file = Library.get_media_file!(id, preload: [:library_path])
    {prev_file, next_file} = Library.get_adjacent_media_files(id, library_path_type: :adult)

    # Get known duration from file metadata, or probe fresh if missing
    known_duration = get_known_duration(file)

    {:ok,
     socket
     |> assign(:file, file)
     |> assign(:prev_file, prev_file)
     |> assign(:next_file, next_file)
     |> assign(:known_duration, known_duration)
     |> assign(:page_title, get_display_name(file))}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("keydown", %{"key" => "ArrowLeft"}, socket) do
    case socket.assigns.prev_file do
      nil -> {:noreply, socket}
      file -> {:noreply, push_navigate(socket, to: ~p"/adult/#{file.id}")}
    end
  end

  def handle_event("keydown", %{"key" => "ArrowRight"}, socket) do
    case socket.assigns.next_file do
      nil -> {:noreply, socket}
      file -> {:noreply, push_navigate(socket, to: ~p"/adult/#{file.id}")}
    end
  end

  def handle_event("keydown", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_file", _params, socket) do
    file = socket.assigns.file

    case Library.delete_media_file(file) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "File deleted successfully")
         |> push_navigate(to: ~p"/adult")}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete file")}
    end
  end

  defp get_display_name(file) do
    case file.relative_path do
      nil -> "Unknown"
      path -> Path.basename(path)
    end
  end

  defp get_video_url(file) do
    "/api/v1/stream/#{file.id}"
  end

  defp format_file_size(nil), do: "-"

  defp format_file_size(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 0)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_date(nil), do: "-"

  defp format_date(%DateTime{} = date) do
    Calendar.strftime(date, "%Y-%m-%d %H:%M")
  end

  # Extract known duration from media file metadata, or probe fresh if missing
  defp get_known_duration(file) do
    case file.metadata do
      %{"duration" => duration} when is_number(duration) and duration > 0 ->
        duration

      _ ->
        # Duration not in metadata - probe fresh from the file
        probe_duration(file)
    end
  end

  # Probe duration directly from the video file using FFprobe
  defp probe_duration(file) do
    case MediaFile.absolute_path(file) do
      nil ->
        Logger.warning("Cannot probe duration: library_path not loaded for media_file #{file.id}")
        nil

      absolute_path ->
        if File.exists?(absolute_path) do
          case ThumbnailGenerator.get_duration(absolute_path) do
            {:ok, duration} when duration > 0 ->
              Logger.info("Probed fresh duration #{duration}s for media_file #{file.id}")

              # Update the database in the background for future requests
              spawn(fn ->
                updated_metadata =
                  (file.metadata || %{})
                  |> Map.put("duration", duration)

                Library.update_media_file(file, %{metadata: updated_metadata})
              end)

              duration

            {:ok, _} ->
              nil

            {:error, reason} ->
              Logger.warning("Failed to probe duration for #{absolute_path}: #{inspect(reason)}")
              nil
          end
        else
          Logger.warning("Cannot probe duration: file not found at #{absolute_path}")
          nil
        end
    end
  end
end
