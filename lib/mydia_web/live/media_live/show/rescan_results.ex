defmodule MydiaWeb.MediaLive.Show.RescanResults do
  @moduledoc """
  Async result handlers for the series, movie and season re-scans, with their flash text.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 2]

  require Logger

  def handle_rescan_series_async({:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message = rescan_flash_message(:all, scan_result, refreshed)

    {:noreply,
     socket
     |> assign(
       :media_item,
       load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)
     )
     |> put_flash(:info, message)}
  end

  def handle_rescan_series_async({:ok, {{:error, :not_a_tv_show}, _}}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Re-scan is only available for TV shows"))}
  end

  def handle_rescan_series_async({:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("No existing media files found. Please import at least one file first.")
     )}
  end

  def handle_rescan_series_async({:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Series re-scan failed: #{inspect(reason)}")

    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Failed to re-scan series: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_rescan_series_async({:exit, reason}, socket) do
    Logger.error("Series re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, gettext("Series re-scan failed unexpectedly"))}
  end

  def handle_rescan_movie_async({:ok, {{:ok, scan_result}, {:ok, refreshed, _errors}}}, socket) do
    message = rescan_flash_message(:all, scan_result, refreshed)

    {:noreply,
     socket
     |> assign(
       :media_item,
       load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)
     )
     |> put_flash(:info, message)}
  end

  def handle_rescan_movie_async({:ok, {{:error, :not_a_movie}, _}}, socket) do
    {:noreply, put_flash(socket, :error, gettext("Re-scan is only available for movies"))}
  end

  def handle_rescan_movie_async({:ok, {{:error, :no_media_files}, _}}, socket) do
    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("No existing media files found. Please import at least one file first.")
     )}
  end

  def handle_rescan_movie_async({:ok, {{:error, reason}, _}}, socket) do
    Logger.error("Movie re-scan failed: #{inspect(reason)}")

    {:noreply,
     put_flash(
       socket,
       :error,
       gettext("Failed to re-scan movie: %{reason}", reason: inspect(reason))
     )}
  end

  def handle_rescan_movie_async({:exit, reason}, socket) do
    Logger.error("Movie re-scan task crashed: #{inspect(reason)}")
    {:noreply, put_flash(socket, :error, gettext("Movie re-scan failed unexpectedly"))}
  end

  def handle_rescan_season_async(
        {:ok, {season_num, {:ok, scan_result}, {:ok, refreshed, _errors}}},
        socket
      ) do
    message = rescan_flash_message({:season, season_num}, scan_result, refreshed)

    {:noreply,
     socket
     |> assign(
       :media_item,
       load_media_item(socket.assigns.current_scope, socket.assigns.media_item.id)
     )
     |> assign(:rescanning_season, nil)
     |> put_flash(:info, message)}
  end

  def handle_rescan_season_async({:ok, {_season_num, {:error, :not_a_tv_show}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, gettext("Re-scan is only available for TV shows"))}
  end

  def handle_rescan_season_async({:ok, {season_num, {:error, :no_media_files}, _}}, socket) do
    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(
       :error,
       gettext(
         "No existing media files found for season %{number}. Please import at least one file first.",
         number: season_num
       )
     )}
  end

  def handle_rescan_season_async({:ok, {season_num, {:error, reason}, _}}, socket) do
    Logger.error("Season #{season_num} re-scan failed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(
       :error,
       gettext("Failed to re-scan season %{number}: %{reason}",
         number: season_num,
         reason: inspect(reason)
       )
     )}
  end

  def handle_rescan_season_async({:exit, reason}, socket) do
    Logger.error("Season re-scan task crashed: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:rescanning_season, nil)
     |> put_flash(:error, gettext("Season re-scan failed unexpectedly"))}
  end

  defp rescan_flash_message(scope, scan_result, refreshed) do
    deleted = Map.get(scan_result, :deleted_files, 0)

    parts = [
      ngettext(
        "Found %{count} new file",
        "Found %{count} new files",
        scan_result.new_files
      )
    ]

    parts =
      if deleted > 0,
        do:
          parts ++
            [ngettext("moved %{count} file to trash", "moved %{count} files to trash", deleted)],
        else: parts

    staged = Map.get(scan_result, :staged, 0)

    parts =
      if staged > 0,
        do:
          parts ++
            [
              ngettext(
                "sent %{count} file to Import for review",
                "sent %{count} files to Import for review",
                staged
              )
            ],
        else: parts

    parts =
      parts ++
        [
          ngettext(
            "refreshed metadata for %{count} file",
            "refreshed metadata for %{count} files",
            refreshed
          )
        ]

    scan_errors = Map.get(scan_result, :scan_errors, [])

    parts =
      if Enum.empty?(scan_errors),
        do: parts,
        else:
          parts ++
            [
              ngettext(
                "%{count} file could not be read",
                "%{count} files could not be read",
                length(scan_errors)
              )
            ]

    parts =
      if Enum.empty?(scan_result.errors),
        do: parts,
        else:
          parts ++
            [ngettext("%{count} error", "%{count} errors", length(scan_result.errors))]

    details = Enum.join(parts, ", ")

    case scope do
      {:season, season_num} ->
        gettext("Season %{number} re-scan complete! %{details}",
          number: season_num,
          details: details
        )

      _ ->
        gettext("Re-scan complete! %{details}", details: details)
    end
  end
end
