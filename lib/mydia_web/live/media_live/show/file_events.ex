defmodule MydiaWeb.MediaLive.Show.FileEvents do
  @moduledoc false

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  alias Mydia.Media
  alias Mydia.Media.ProviderSwitch
  alias Mydia.Library
  alias Mydia.Downloads
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders,
    only: [load_media_item: 1, load_transcode_jobs: 1]

  import MydiaWeb.MediaLive.Show.Helpers,
    only: [get_season_media_files: 2, refresh_files: 1, provider_label: 1]

  require Logger

  def refresh_metadata(_params, socket) do
    media_item = socket.assigns.media_item

    case ProviderSwitch.provider_refresh_decision(media_item) do
      {:reidentify, target} ->
        # Search + adopt do network I/O; run them async so the LiveView socket
        # is never blocked (a multi-season switch can take many seconds).
        {:noreply,
         socket
         |> assign(:reidentifying, true)
         |> put_flash(:info, "Re-identifying on #{provider_label(target)}...")
         |> start_async(:reidentify_search, fn ->
           {target, ProviderSwitch.find_reidentify_candidate(media_item, target)}
         end)}

      :refetch ->
        do_standard_refresh(media_item, socket)
    end
  end

  @doc """
  Adopts a manually-selected re-identification candidate from the picker modal.
  """
  def select_reidentify_candidate(%{"provider_id" => provider_id}, socket) do
    media_item = socket.assigns.media_item
    target = socket.assigns.reidentify_provider

    candidate =
      Enum.find(
        socket.assigns.reidentify_candidates,
        &(to_string(&1.provider_id) == provider_id)
      )

    if candidate do
      {:noreply,
       socket
       |> assign(:show_reidentify_modal, false)
       |> assign(:reidentifying, true)
       |> put_flash(:info, "Switching to #{provider_label(target)}...")
       |> start_async(:reidentify_adopt, fn ->
         {target, ProviderSwitch.adopt_provider_switch(media_item, candidate, target)}
       end)}
    else
      {:noreply,
       socket
       |> assign(:show_reidentify_modal, false)
       |> put_flash(:error, "That selection is no longer available")}
    end
  end

  def cancel_reidentify(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_reidentify_modal, false)
     |> assign(:reidentify_candidates, [])
     |> assign(:reidentify_provider, nil)}
  end

  # async result: provider re-identification search
  def handle_reidentify_search_async({:ok, {target, {:confident, candidate}}}, socket) do
    media_item = socket.assigns.media_item

    {:noreply,
     start_async(socket, :reidentify_adopt, fn ->
       {target, ProviderSwitch.adopt_provider_switch(media_item, candidate, target)}
     end)}
  end

  def handle_reidentify_search_async({:ok, {target, {:needs_picker, candidates}}}, socket) do
    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> assign(:reidentify_provider, target)
     |> assign(:reidentify_candidates, candidates)
     |> assign(:show_reidentify_modal, true)}
  end

  def handle_reidentify_search_async({:ok, {target, {:error, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> put_flash(:error, "Could not search #{provider_label(target)}: #{inspect(reason)}")}
  end

  def handle_reidentify_search_async({:exit, reason}, socket) do
    Logger.error("Re-identification search crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> put_flash(:error, "Re-identification failed unexpectedly")}
  end

  # async result: provider switch (adopt)
  def handle_reidentify_adopt_async({:ok, {target, {:ok, _updated}}}, socket) do
    media_item = socket.assigns.media_item

    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> assign(:show_reidentify_modal, false)
     |> assign(:reidentify_candidates, [])
     |> assign(:media_item, load_media_item(media_item.id))
     |> put_flash(
       :info,
       "Switched to #{provider_label(target)}. Episodes were re-matched; " <>
         "episode-level watch history was reset."
     )}
  end

  def handle_reidentify_adopt_async({:ok, {_target, {:error, reason}}}, socket) do
    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> assign(:show_reidentify_modal, false)
     |> put_flash(:error, "Provider switch failed: #{inspect(reason)}")}
  end

  def handle_reidentify_adopt_async({:exit, reason}, socket) do
    Logger.error("Provider switch crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:reidentifying, false)
     |> put_flash(:error, "Provider switch failed unexpectedly")}
  end

  # Refresh.run/2 already refreshes episodes for TV shows and writes NFOs, so
  # this no longer hand-rolls the two-call sequence. Episode-refresh failures
  # are logged there rather than surfaced as a flash: they are best-effort and
  # must not read as a failed metadata refresh.
  #
  # `force: true` because a person clicked the button. The season-refresh
  # throttle is sized for the weekly sweep, and without this it silently
  # declines the episode half of the refresh for 24 hours — 168 once the show
  # has ended — while this still flashes "Metadata refreshed".
  defp do_standard_refresh(media_item, socket) do
    case Media.Refresh.run(media_item, force: true) do
      {:ok, _updated_item} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(media_item.id))
         |> put_flash(:info, "Metadata refreshed#{ambiguous_note(media_item)}")}

      {:error, :missing_provider_id} ->
        {:noreply, put_flash(socket, :error, "Cannot refresh: Missing provider ID (TMDB/TVDB)")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to refresh metadata: #{inspect(reason)}")}
    end
  end

  # When a show's files span libraries with different providers, re-identification
  # is skipped; tell the operator so the no-op switch isn't confusing.
  defp ambiguous_note(media_item) do
    case ProviderSwitch.resolve_library_provider(media_item) do
      :ambiguous ->
        " (provider re-identification skipped: this show's files span libraries with different sources)"

      _ ->
        ""
    end
  end

  def refresh_all_file_metadata(_params, socket) do
    media_item = socket.assigns.media_item
    media_files = media_item.media_files

    if Enum.empty?(media_files) do
      {:noreply, put_flash(socket, :info, "No media files to refresh")}
    else
      {:noreply,
       socket
       |> assign(:refreshing_file_metadata, true)
       |> start_async(:refresh_files, fn -> refresh_files(media_files) end)}
    end
  end

  def rescan_season_files(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)
    season_media_files = get_season_media_files(media_item, season_num)

    if Enum.empty?(season_media_files) do
      {:noreply, put_flash(socket, :info, "No media files to refresh for season #{season_num}")}
    else
      {:noreply,
       socket
       |> assign(:rescanning_season, season_num)
       |> start_async(:rescan_season_files, fn ->
         {season_num, refresh_files(season_media_files)}
       end)}
    end
  end

  def rescan_series(_params, socket) do
    media_item = socket.assigns.media_item

    if media_item.type != "tv_show" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
    else
      {:noreply,
       socket
       |> put_flash(:info, "Re-scanning series: discovering new files and refreshing metadata...")
       |> start_async(:rescan_series, fn ->
         scan_result = Library.rescan_series(media_item.id)

         case scan_result do
           {:ok, _result} ->
             updated_media_item =
               Media.get_media_item!(media_item.id,
                 preload: [episodes: [media_files: :library_path]]
               )

             all_media_files = Enum.flat_map(updated_media_item.episodes, & &1.media_files)
             refresh_result = refresh_files(all_media_files)
             {scan_result, refresh_result}

           error ->
             {error, {:ok, 0, 0}}
         end
       end)}
    end
  end

  def rescan_season(%{"season-number" => season_number_str}, socket) do
    media_item = socket.assigns.media_item
    season_num = String.to_integer(season_number_str)

    if media_item.type != "tv_show" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
    else
      {:noreply,
       socket
       |> assign(:rescanning_season, season_num)
       |> put_flash(
         :info,
         "Re-scanning season #{season_num}: discovering new files and refreshing metadata..."
       )
       |> start_async(:rescan_season, fn ->
         scan_result = Library.rescan_season(media_item.id, season_num)

         case scan_result do
           {:ok, _result} ->
             updated_media_item =
               Media.get_media_item!(media_item.id,
                 preload: [episodes: [media_files: :library_path]]
               )

             season_media_files = get_season_media_files(updated_media_item, season_num)
             refresh_result = refresh_files(season_media_files)
             {season_num, scan_result, refresh_result}

           error ->
             {season_num, error, {:ok, 0, 0}}
         end
       end)}
    end
  end

  def rescan_movie(_params, socket) do
    media_item = socket.assigns.media_item

    if media_item.type != "movie" do
      {:noreply, put_flash(socket, :error, "Re-scan is only available for movies")}
    else
      {:noreply,
       socket
       |> put_flash(:info, "Re-scanning movie: discovering new files and refreshing metadata...")
       |> start_async(:rescan_movie, fn ->
         scan_result = Library.rescan_movie(media_item.id)

         case scan_result do
           {:ok, _result} ->
             updated_media_item =
               Media.get_media_item!(media_item.id, preload: [media_files: :library_path])

             all_media_files = updated_media_item.media_files
             refresh_result = refresh_files(all_media_files)
             {scan_result, refresh_result}

           error ->
             {error, {:ok, 0, 0}}
         end
       end)}
    end
  end

  def show_file_delete_confirm(%{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id, preload: :library_path)

    {:noreply,
     socket
     |> assign(:show_file_delete_confirm, true)
     |> assign(:file_to_delete, file)
     |> assign(:delete_file_from_disk, true)}
  end

  def hide_file_delete_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_file_delete_confirm, false)
     |> assign(:file_to_delete, nil)}
  end

  def toggle_file_delete_from_disk(%{"delete_file_from_disk" => value}, socket) do
    {:noreply, assign(socket, :delete_file_from_disk, value == "true")}
  end

  def delete_media_file(_params, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      file = socket.assigns.file_to_delete
      delete_files = socket.assigns.delete_file_from_disk

      socket =
        socket
        |> assign(:show_file_delete_confirm, false)
        |> assign(:file_to_delete, nil)

      case Library.delete_media_file(file, delete_files: delete_files) do
        {:ok, _} ->
          {:noreply,
           socket
           |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
           |> put_flash(:info, delete_file_success_message(delete_files))}

        {:ok, _, :file_delete_failed} ->
          {:noreply,
           socket
           |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
           |> put_flash(
             :error,
             "Removed the file record, but the file on disk could not be deleted. " <>
               "Check the file permissions and remove it manually if needed."
           )}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to delete media file")}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp delete_file_success_message(true), do: "Media file deleted, including the file on disk"

  defp delete_file_success_message(false),
    do: "Media file removed from library, file kept on disk"

  def show_file_details(%{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id)

    {:noreply,
     socket
     |> assign(:show_file_details_modal, true)
     |> assign(:file_details, file)}
  end

  def hide_file_details(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_file_details_modal, false)
     |> assign(:file_details, nil)}
  end

  def pre_transcode(
        %{"media-file-id" => media_file_id, "resolution" => resolution},
        socket
      ) do
    media_item = socket.assigns.media_item

    case Downloads.DownloadService.prepare_by_file(media_file_id, resolution) do
      {:ok, _job_info} ->
        {:noreply,
         socket
         |> assign(:transcode_jobs, load_transcode_jobs(media_item))
         |> put_flash(:info, "Pre-transcode started for #{resolution}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to start pre-transcode: #{inspect(reason)}")}
    end
  end

  def cancel_transcode(%{"job-id" => job_id}, socket) do
    case Downloads.DownloadService.cancel_job(job_id) do
      {:ok, :cancelled} ->
        media_item = socket.assigns.media_item

        {:noreply,
         socket
         |> assign(:transcode_jobs, load_transcode_jobs(media_item))
         |> put_flash(:info, "Transcode cancelled")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Failed to cancel: #{inspect(reason)}")}
    end
  end

  def show_rename_modal(_params, socket) do
    media_item = load_media_item(socket.assigns.media_item.id)

    rename_previews =
      Mydia.Library.FileRenamer.generate_rename_previews_for_media_item(media_item)

    {:noreply,
     socket
     |> assign(:show_rename_modal, true)
     |> assign(:rename_previews, rename_previews)}
  end

  def hide_rename_modal(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:renaming_files, false)}
  end

  def confirm_rename_files(_params, socket) do
    rename_previews = socket.assigns.rename_previews

    rename_specs =
      Enum.map(rename_previews, fn preview ->
        %{file_id: preview.file_id, new_path: preview.proposed_path}
      end)

    {:noreply,
     socket
     |> assign(:renaming_files, true)
     |> start_async(:rename_files, fn ->
       Mydia.Library.FileRenamer.rename_files_batch(rename_specs)
     end)}
  end

  def mark_file_preferred(%{"file-id" => file_id}, socket) do
    file = Library.get_media_file!(file_id)
    media_item = socket.assigns.media_item

    case Library.update_media_file(file, %{quality_profile_id: media_item.quality_profile_id}) do
      {:ok, _} ->
        {:noreply,
         socket
         |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
         |> put_flash(:info, "Marked as preferred version")}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to mark file as preferred")}
    end
  end

  # handle_async dispatches

  def handle_refresh_files_async({:ok, {:ok, success_count, error_count}}, socket) do
    message =
      if error_count > 0 do
        "Refreshed #{success_count} file(s), #{error_count} failed"
      else
        "Successfully refreshed #{success_count} file(s)"
      end

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_refresh_files_async({:ok, {:error, reason}}, socket) do
    Logger.error("File metadata refresh failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> put_flash(:error, "Failed to refresh file metadata: #{inspect(reason)}")}
  end

  def handle_refresh_files_async({:exit, reason}, socket) do
    Logger.error("File metadata refresh task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:refreshing_file_metadata, false)
     |> put_flash(:error, "Metadata refresh failed unexpectedly")}
  end

  def handle_rescan_season_files_async(
        {:ok, {season_num, {:ok, success_count, error_count}}},
        socket
      ) do
    message =
      if error_count > 0 do
        "Re-scanned #{success_count} file(s) in Season #{season_num}, #{error_count} failed"
      else
        "Successfully re-scanned #{success_count} file(s) in Season #{season_num}"
      end

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_rescan_season_files_async({:ok, {season_num, {:error, reason}}}, socket) do
    Logger.error("Season file metadata refresh failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Failed to refresh Season #{season_num} files: #{inspect(reason)}")}
  end

  def handle_rescan_season_files_async({:exit, reason}, socket) do
    Logger.error("Season file metadata refresh task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Season metadata refresh failed unexpectedly")}
  end

  def handle_rescan_series_async({:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message = rescan_flash_message("Re-scan", scan_result, refreshed)

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_rescan_series_async({:ok, {{:error, :not_a_tv_show}, _}}, socket) do
    {:noreply, put_flash(socket, :error, "Re-scan is only available for TV shows")}
  end

  def handle_rescan_series_async({:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "No existing media files found. Please import at least one file first."
     )}
  end

  def handle_rescan_series_async({:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Series re-scan failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Failed to re-scan series: #{inspect(reason)}")}
  end

  def handle_rescan_series_async({:exit, reason}, socket) do
    Logger.error("Series re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Series re-scan failed unexpectedly")}
  end

  def handle_rescan_movie_async({:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message = rescan_flash_message("Re-scan", scan_result, refreshed)

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(:info, message)}
  end

  def handle_rescan_movie_async({:ok, {{:error, :not_a_movie}, _}}, socket) do
    {:noreply, put_flash(socket, :error, "Re-scan is only available for movies")}
  end

  def handle_rescan_movie_async({:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       "No existing media files found. Please import at least one file first."
     )}
  end

  def handle_rescan_movie_async({:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Movie re-scan failed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Failed to re-scan movie: #{inspect(reason)}")}
  end

  def handle_rescan_movie_async({:exit, reason}, socket) do
    Logger.error("Movie re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, "Movie re-scan failed unexpectedly")}
  end

  def handle_rescan_season_async(
        {:ok, {season_num, {:ok, scan_result}, {:ok, refreshed, _errors}}},
        socket
      ) do
    message = rescan_flash_message("Season #{season_num} re-scan", scan_result, refreshed)

    {:noreply,
     socket
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> assign(:rescanning_season, nil)
     |> put_flash(:info, message)}
  end

  def handle_rescan_season_async({:ok, {_season_num, {:error, :not_a_tv_show}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Re-scan is only available for TV shows")}
  end

  def handle_rescan_season_async({:ok, {season_num, {:error, :no_media_files}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(
       :error,
       "No existing media files found for season #{season_num}. Please import at least one file first."
     )}
  end

  def handle_rescan_season_async({:ok, {season_num, {:error, reason}, _}}, socket) do
    Logger.error("Season #{season_num} re-scan failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Failed to re-scan season #{season_num}: #{inspect(reason)}")}
  end

  def handle_rescan_season_async({:exit, reason}, socket) do
    Logger.error("Season re-scan task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, "Season re-scan failed unexpectedly")}
  end

  def handle_rename_files_async({:ok, {:ok, results}}, socket) do
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    message =
      cond do
        error_count == 0 ->
          "Successfully renamed #{success_count} file(s)"

        success_count == 0 ->
          "Failed to rename all files"

        true ->
          "Renamed #{success_count} file(s), #{error_count} failed"
      end

    flash_type = if error_count > 0, do: :warning, else: :info

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> assign(:show_rename_modal, false)
     |> assign(:rename_previews, [])
     |> assign(:media_item, load_media_item(socket.assigns.media_item.id))
     |> put_flash(flash_type, message)}
  end

  def handle_rename_files_async({:ok, {:error, reason}}, socket) do
    Logger.error("File rename failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> put_flash(:error, "Failed to rename files: #{inspect(reason)}")}
  end

  def handle_rename_files_async({:exit, reason}, socket) do
    Logger.error("File rename task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:renaming_files, false)
     |> put_flash(:error, "File rename failed unexpectedly")}
  end

  defp rescan_flash_message(prefix, scan_result, refreshed) do
    deleted = Map.get(scan_result, :deleted_files, 0)

    parts = ["Found #{scan_result.new_files} new file(s)"]

    parts =
      if deleted > 0,
        do: parts ++ ["moved #{deleted} file(s) to trash"],
        else: parts

    parts = parts ++ ["refreshed metadata for #{refreshed} file(s)"]

    parts =
      if Enum.empty?(scan_result.errors),
        do: parts,
        else: parts ++ ["#{length(scan_result.errors)} error(s)"]

    "#{prefix} complete! #{Enum.join(parts, ", ")}"
  end
end
