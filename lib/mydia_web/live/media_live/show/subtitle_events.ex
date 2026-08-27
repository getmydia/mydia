defmodule MydiaWeb.MediaLive.Show.SubtitleEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_file_subtitle_tracks: 1]

  require Logger

  def open_subtitle_search(%{"media-file-id" => media_file_id}, socket) do
    # library_path is what resolves the file's location for the modal header.
    media_file = Mydia.Library.get_media_file!(media_file_id, preload: [:library_path])

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

  # The result is looked up from the socket rather than rebuilt from the click
  # payload. The wire used to carry the provider's own file id, which meant the
  # server both trusted it and had to parse it; parsing it as an integer killed
  # the LiveView for every relay and Gestdown result, whose ids are strings.
  def download_subtitle_result(%{"index" => index}, socket) when is_binary(index) do
    media_file = socket.assigns.selected_media_file

    with {position, ""} <- Integer.parse(index),
         true <- position >= 0,
         result when not is_nil(result) <-
           Enum.at(socket.assigns.subtitle_search_results, position) do
      {:noreply,
       socket
       |> assign(:downloading_subtitle_index, position)
       |> start_async(:download_subtitle, fn ->
         Mydia.Subtitles.download_from_result(result, media_file.id)
       end)}
    else
      _ ->
        {:noreply, put_flash(socket, :error, "That result is no longer available. Search again.")}
    end
  end

  # The rendered button always sends a string index, so this clause only
  # guards a hand-crafted payload (a nil, a JSON number, or a missing key).
  # This handler must never let a client value reach a parser that can raise.
  def download_subtitle_result(_params, socket) do
    {:noreply, put_flash(socket, :error, "That result is no longer available. Search again.")}
  end

  def delete_subtitle(%{"subtitle-id" => subtitle_id}, socket) do
    case Mydia.Subtitles.delete_subtitle(subtitle_id) do
      :ok ->
        {:noreply,
         socket
         |> assign(
           :media_file_subtitle_tracks,
           load_media_file_subtitle_tracks(socket.assigns.media_item)
         )
         |> put_flash(:info, "Subtitle deleted successfully")}

      {:error, reason} ->
        Logger.error("Failed to delete subtitle", subtitle_id: subtitle_id, reason: reason)

        {:noreply,
         socket
         |> put_flash(:error, "Failed to delete subtitle: #{inspect(reason)}")}
    end
  end

  def set_subtitle_offset(
        %{"media-file-id" => media_file_id, "track-ref" => track_ref, "offset_ms" => raw},
        socket
      )
      when is_binary(raw) do
    case Integer.parse(raw) do
      {offset_ms, ""} -> store_offset(socket, media_file_id, track_ref, offset_ms)
      _ -> {:noreply, put_flash(socket, :error, "Offset must be a whole number of milliseconds")}
    end
  end

  # A hand-crafted payload whose offset is not even a string, or one missing
  # a key entirely. `Integer.parse/1` requires a binary and raises
  # FunctionClauseError on anything else, so the `is_binary/1` guard above is
  # load-bearing: without it, a crafted non-string offset would take the
  # LiveView process down instead of landing here. Neither case is an error
  # worth a flash; there is simply nothing to store.
  def set_subtitle_offset(_params, socket), do: {:noreply, socket}

  def nudge_subtitle_offset(
        %{"media-file-id" => media_file_id, "track-ref" => track_ref, "delta" => raw},
        socket
      )
      when is_binary(raw) do
    with {delta, ""} <- Integer.parse(raw) do
      current = Mydia.Subtitles.TrackSettings.offset_ms(media_file_id, track_ref)
      store_offset(socket, media_file_id, track_ref, current + delta)
    else
      _ -> {:noreply, socket}
    end
  end

  # See set_subtitle_offset/2's fallback clause: the is_binary/1 guard above
  # is what keeps a non-string delta from reaching Integer.parse/1 and
  # crashing the LiveView.
  def nudge_subtitle_offset(_params, socket), do: {:noreply, socket}

  # Runs off the LiveView process via start_async, matching every other
  # rescan-shaped action in this LiveView (rescan_movie, rescan_series,
  # rescan_season, rescan_season_files in FileEvents). Mydia.Subtitles.Sidecars.reconcile/1
  # lists a directory, runs two queries, and hashes every newly discovered
  # sidecar; running that inline in handle_event would block the whole page
  # for this user with no loading indicator, which is worst on the network
  # mounts a self-hosted NAS setup is likely to use.
  def rescan_subtitles(%{"media-file-id" => media_file_id}, socket) do
    media_file = Mydia.Library.get_media_file!(media_file_id, preload: [:library_path])

    {:noreply,
     socket
     |> put_flash(:info, "Checking for subtitle files on disk...")
     |> start_async(:rescan_subtitles, fn -> Mydia.Subtitles.Sidecars.reconcile(media_file) end)}
  end

  defp store_offset(socket, media_file_id, track_ref, offset_ms) do
    case Mydia.Subtitles.TrackSettings.set_offset(media_file_id, track_ref, offset_ms) do
      {:ok, _setting} ->
        {:noreply,
         assign(
           socket,
           :media_file_subtitle_tracks,
           load_media_file_subtitle_tracks(socket.assigns.media_item)
         )}

      {:error, _changeset} ->
        max = Mydia.Subtitles.TrackSetting.max_offset_ms()

        {:noreply,
         put_flash(socket, :error, "Offset must be between -#{max} and #{max} milliseconds")}
    end
  end

  # handle_async dispatches

  def handle_rescan_subtitles_async({:ok, {:ok, tally}}, socket) do
    {:noreply,
     socket
     |> assign(
       :media_file_subtitle_tracks,
       load_media_file_subtitle_tracks(socket.assigns.media_item)
     )
     |> put_flash(
       :info,
       "Rescan complete: #{tally.adopted} adopted, #{tally.reaped} removed"
     )}
  end

  def handle_rescan_subtitles_async({:ok, {:error, reason}}, socket) do
    {:noreply,
     put_flash(socket, :error, "Could not read that file's directory: #{inspect(reason)}")}
  end

  def handle_rescan_subtitles_async({:exit, reason}, socket) do
    Logger.error("Subtitle rescan task crashed: #{inspect(reason)}")

    {:noreply, put_flash(socket, :error, "Subtitle rescan failed unexpectedly")}
  end

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
     |> assign(:downloading_subtitle_index, nil)
     |> assign(:show_subtitle_search_modal, false)
     |> assign(:selected_media_file, nil)
     |> assign(:subtitle_search_state, :idle)
     |> assign(:subtitle_search_results, [])
     |> assign(:subtitle_providers, [])
     |> assign(
       :media_file_subtitle_tracks,
       load_media_file_subtitle_tracks(socket.assigns.media_item)
     )
     |> put_flash(:info, "Subtitle downloaded successfully")}
  end

  def handle_download_subtitle_async({:ok, {:error, reason}}, socket) do
    Logger.error("Subtitle download failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle_index, nil)
     |> put_flash(:error, "Subtitle download failed: #{download_error_message(reason)}")}
  end

  def handle_download_subtitle_async({:exit, reason}, socket) do
    Logger.error("Subtitle download task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:downloading_subtitle_index, nil)
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

  defp download_error_message(:unrecognized_subtitle_content),
    do: "the provider sent a file that is not a subtitle."

  defp download_error_message({:unsupported_subtitle_format, format}),
    do: "that subtitle is in #{format} format, which Mydia cannot use."

  defp download_error_message(_reason),
    do: "check the server logs for details."
end
