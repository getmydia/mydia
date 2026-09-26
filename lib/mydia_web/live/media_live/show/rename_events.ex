defmodule MydiaWeb.MediaLive.Show.RenameEvents do
  @moduledoc """
  Event and async handlers for the show page's rename modal.

  The previews and the selection both live on the socket; the client only
  sends toggles, which `RenameSelection` checks against the previews.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]
  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 1]

  alias Mydia.Library.FileRenamer
  alias MydiaWeb.MediaLive.Show.RenameSelection

  require Logger

  def show_rename_modal(_params, socket) do
    media_item = load_media_item(socket.assigns.media_item.id)
    previews = FileRenamer.generate_rename_previews_for_media_item(media_item)

    {:noreply,
     socket
     |> assign(:show_rename_modal, true)
     |> assign(:rename_previews, previews)
     |> assign(:rename_selected, RenameSelection.initial(previews))}
  end

  def hide_rename_modal(_params, socket), do: {:noreply, reset(socket)}

  def toggle_rename_file(%{"file-id" => file_id}, socket) do
    update_selection(socket, &RenameSelection.toggle_file(&1, &2, file_id))
  end

  def toggle_rename_season(%{"season-number" => season}, socket) do
    case Integer.parse(season) do
      {n, ""} -> update_selection(socket, &RenameSelection.toggle_season(&1, &2, n))
      _ -> {:noreply, socket}
    end
  end

  def select_all_rename(_params, socket),
    do: update_selection(socket, fn _selected, previews -> RenameSelection.initial(previews) end)

  def clear_rename_selection(_params, socket),
    do: update_selection(socket, fn _selected, _previews -> MapSet.new() end)

  def confirm_rename_files(_params, socket) do
    specs = RenameSelection.specs(socket.assigns.rename_selected, socket.assigns.rename_previews)

    if specs == [] do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(:renaming_files, true)
       |> start_async(:rename_files, fn -> FileRenamer.rename_files_batch(specs) end)}
    end
  end

  def handle_rename_files_async({:ok, {:ok, results}}, socket) do
    success_count = Enum.count(results, &match?({:ok, _}, &1))
    error_count = Enum.count(results, &match?({:error, _}, &1))

    message =
      cond do
        error_count == 0 -> "Successfully renamed #{success_count} file(s)"
        success_count == 0 -> "Failed to rename all files"
        true -> "Renamed #{success_count} file(s), #{error_count} failed"
      end

    flash_type = if error_count > 0, do: :warning, else: :info

    {:noreply,
     socket
     |> reset()
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

  defp update_selection(socket, fun) do
    selected = fun.(socket.assigns.rename_selected, socket.assigns.rename_previews)
    {:noreply, assign(socket, :rename_selected, selected)}
  end

  defp reset(socket) do
    socket
    |> assign(:show_rename_modal, false)
    |> assign(:rename_previews, [])
    |> assign(:rename_selected, MapSet.new())
    |> assign(:renaming_files, false)
  end
end
