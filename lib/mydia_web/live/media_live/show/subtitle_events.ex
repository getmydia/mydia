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
     |> assign(:subtitle_search_state, :idle)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_providers, [])}
  end

  def close_subtitle_search_modal(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_state, :idle)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_providers, [])}
  end

  def update_subtitle_languages(%{"languages" => languages}, socket) do
    {:noreply, assign(socket, :selected_languages, languages)}
  end

  # Unchecking every chip drops the key from the change payload rather than
  # sending an empty list.
  def update_subtitle_languages(_params, socket) do
    {:noreply, assign(socket, :selected_languages, [])}
  end

  def clear_subtitle_languages(_params, socket) do
    {:noreply, assign(socket, :selected_languages, [])}
  end

  def perform_subtitle_search(_params, socket) do
    media_file = socket.assigns.selected_media_file
    languages = Enum.join(socket.assigns.selected_languages, ",")

    {:noreply,
     socket
     |> assign(:subtitle_search_state, :searching)
     |> start_async(:subtitle_search, fn ->
       Mydia.Subtitles.search_candidates(media_file.id, languages)
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
     |> assign(:downloading_subtitle_id, subtitle_info.file_id)
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

  def handle_subtitle_search_async(
        {:ok, {:ok, %{results: results, providers: providers}}},
        socket
      ) do
    Logger.info("Subtitle search completed",
      result_count: length(results),
      provider_count: length(providers)
    )

    {:noreply,
     socket
     |> assign(:subtitle_search_state, :loaded)
     |> assign(:subtitle_search_results, results)
     |> assign(:subtitle_providers, providers)}
  end

  def handle_subtitle_search_async({:ok, {:error, reason}}, socket) do
    Logger.error("Subtitle search failed: #{inspect(reason)}")

    {:noreply, assign(socket, :subtitle_search_state, {:error, reason})}
  end

  def handle_subtitle_search_async({:exit, reason}, socket) do
    Logger.error("Subtitle search task crashed: #{inspect(reason)}")

    {:noreply, assign(socket, :subtitle_search_state, {:error, :crashed})}
  end

  def handle_download_subtitle_async({:ok, {:ok, _subtitle}}, socket) do
    Logger.info("Subtitle downloaded successfully")

    {:noreply,
     socket
     |> assign(:downloading_subtitle_id, nil)
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_state, :idle)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_providers, [])
     |> assign(:media_file_subtitles, load_media_file_subtitles(socket.assigns.media_item))
     |> put_flash(:info, "Subtitle downloaded successfully")}
  end

  def handle_download_subtitle_async({:ok, {:error, reason}}, socket) do
    Logger.error("Subtitle download failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle_id, nil)
     |> put_flash(:error, "Subtitle download failed: #{download_error_message(reason)}")}
  end

  def handle_download_subtitle_async({:exit, reason}, socket) do
    Logger.error("Subtitle download task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle_id, nil)
     |> put_flash(:error, "Subtitle download failed: #{download_error_message(reason)}")}
  end

  # Every clause here matches a class of failure `Mydia.Subtitles.download_subtitle/3`
  # (or the provider it delegates to) can return. Anything unmatched still logs the
  # raw reason above but never puts it in front of an operator.
  defp download_error_message(:media_file_not_found),
    do: "that file is no longer in the library."

  defp download_error_message(:media_file_path_not_resolved),
    do: "the file's location on disk could not be resolved."

  defp download_error_message({:unsupported_format, _format}),
    do: "that subtitle format is not supported."

  defp download_error_message({:missing_required_fields, _fields}),
    do: "the provider did not return everything needed to download it."

  defp download_error_message(:not_found),
    do: "that subtitle is no longer available from the provider."

  defp download_error_message(:rate_limited),
    do: "the provider rate limited the request. Try again shortly."

  defp download_error_message(:service_unavailable),
    do: "the subtitle provider is unavailable right now."

  defp download_error_message(:unauthorized),
    do: "the provider rejected the request. Check its credentials."

  defp download_error_message(_reason),
    do: "check the server logs for details."
end
