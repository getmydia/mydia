defmodule MydiaWeb.MediaLive.Show.SubtitleEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_file_subtitles: 1]
  import MydiaWeb.MediaLive.Show.Helpers, only: [parse_optional_float: 1, parse_optional_int: 1]

  require Logger

  def open_subtitle_search(%{"media-file-id" => media_file_id}, socket) do
    media_file = Mydia.Library.get_media_file!(media_file_id)

    {:noreply,
     socket
     |> assign(:show_subtitle_search_modal, true)
     |> assign(:selected_media_file, media_file)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_provider_statuses, [])}
  end

  def close_subtitle_search_modal(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_provider_statuses, [])
     |> assign(:searching_subtitles, false)}
  end

  def update_subtitle_languages(%{"languages" => languages}, socket) do
    {:noreply, assign(socket, :selected_languages, languages)}
  end

  def perform_subtitle_search(_params, socket) do
    media_file = socket.assigns.selected_media_file
    languages = Enum.join(socket.assigns.selected_languages, ",")
    user_id = socket.assigns.current_user.id

    {:noreply,
     socket
     |> assign(:searching_subtitles, true)
     |> start_async(:subtitle_search, fn ->
       Mydia.Subtitles.search_subtitles(media_file.id, languages: languages, user_id: user_id)
     end)}
  end

  def download_subtitle_result(
        %{
          "file-id" => file_id,
          "language" => language,
          "format" => format,
          "subtitle-hash" => subtitle_hash
        } = params,
        socket
      ) do
    media_file = socket.assigns.selected_media_file

    subtitle_info = %{
      file_id: String.to_integer(file_id),
      language: language,
      format: format,
      subtitle_hash: subtitle_hash,
      rating: parse_optional_float(params["rating"]),
      download_count: parse_optional_int(params["download-count"]),
      hearing_impaired: params["hearing-impaired"] == "true"
    }

    {:noreply,
     socket
     |> assign(:downloading_subtitle, true)
     |> start_async(:download_subtitle, fn ->
       Mydia.Subtitles.download_subtitle(subtitle_info, media_file.id)
     end)}
  end

  def delete_subtitle(%{"subtitle-id" => subtitle_id}, socket) do
    case Mydia.Subtitles.delete_subtitle(subtitle_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(:media_file_subtitles, load_media_file_subtitles(socket.assigns.media_item))
         |> put_flash(:info, "Subtitle deleted successfully")}

      {:error, reason} ->
        Logger.error("Failed to delete subtitle", subtitle_id: subtitle_id, reason: reason)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete subtitle: #{inspect(reason)}")}
    end
  end

  # handle_async dispatches

  def handle_subtitle_search_async({:ok, {:ok, {:downloaded, subtitle}}}, socket) do
    Logger.info("Subtitle auto-downloaded from search", language: subtitle.language)

    {:noreply,
     socket
     |> assign(:searching_subtitles, false)
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_provider_statuses, [])
     |> assign(:media_file_subtitles, load_media_file_subtitles(socket.assigns.media_item))
     |> put_flash(:info, "Subtitle downloaded successfully")}
  end

  def handle_subtitle_search_async(
        {:ok, {:ok, %{results: results, providers: providers}}},
        socket
      ) do
    Logger.info("Subtitle search completed",
      result_count: length(results),
      failed_provider_count: Enum.count(providers, & &1.error)
    )

    {:noreply,
     socket
     |> assign(:searching_subtitles, false)
     |> assign(:subtitle_search_results, results)
     |> assign(:subtitle_provider_statuses, providers)}
  end

  def handle_subtitle_search_async({:ok, {:error, reason}}, socket) do
    Logger.error("Subtitle search failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching_subtitles, false)
     |> put_flash(:error, "Subtitle search failed: #{inspect(reason)}")}
  end

  def handle_subtitle_search_async({:exit, reason}, socket) do
    Logger.error("Subtitle search task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:searching_subtitles, false)
     |> put_flash(:error, "Subtitle search failed unexpectedly")}
  end

  def handle_download_subtitle_async({:ok, {:ok, _subtitle}}, socket) do
    Logger.info("Subtitle downloaded successfully")

    {:noreply,
     socket
     |> assign(:downloading_subtitle, false)
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_results, [])
     |> assign(:media_file_subtitles, load_media_file_subtitles(socket.assigns.media_item))
     |> put_flash(:info, "Subtitle downloaded successfully")}
  end

  def handle_download_subtitle_async({:ok, {:error, reason}}, socket) do
    Logger.error("Subtitle download failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle, false)
     |> put_flash(:error, "Subtitle download failed: #{inspect(reason)}")}
  end

  def handle_download_subtitle_async({:exit, reason}, socket) do
    Logger.error("Subtitle download task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle, false)
     |> put_flash(:error, "Subtitle download failed unexpectedly")}
  end
end
