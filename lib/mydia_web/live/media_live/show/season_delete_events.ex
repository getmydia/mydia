defmodule MydiaWeb.MediaLive.Show.SeasonDeleteEvents do
  @moduledoc false

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Library
  alias Mydia.Media
  alias MydiaWeb.Live.Authorization

  import MydiaWeb.MediaLive.Show.Loaders, only: [load_media_item: 2]

  @events ~w(show_season_delete_confirm hide_season_delete_confirm change_season_delete delete_season_files)

  @doc "The `handle_event/3` names this module owns."
  def events, do: @events

  def assign_defaults(socket) do
    socket
    |> assign(:show_season_delete_confirm, false)
    |> assign(:season_delete, nil)
  end

  def handle("show_season_delete_confirm", params, socket), do: show_confirm(params, socket)
  def handle("hide_season_delete_confirm", params, socket), do: hide_confirm(params, socket)
  def handle("change_season_delete", params, socket), do: change(params, socket)
  def handle("delete_season_files", params, socket), do: delete_files(params, socket)

  defp show_confirm(%{"season-number" => season_number_str}, socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      season_number = String.to_integer(season_number_str)

      episodes =
        Enum.filter(socket.assigns.media_item.episodes, &(&1.season_number == season_number))

      files = Enum.flat_map(episodes, & &1.media_files)

      if files == [] do
        {:noreply, socket}
      else
        {:noreply,
         assign(socket, :season_delete, %{
           season_number: season_number,
           episode_ids: Enum.map(episodes, & &1.id),
           file_count: length(files),
           bytes: Enum.reduce(files, 0, &((&1.size || 0) + &2)),
           mode: :trash,
           unmonitor: true
         })
         |> assign(:show_season_delete_confirm, true)}
      end
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp hide_confirm(_params, socket) do
    {:noreply,
     socket
     |> assign(:show_season_delete_confirm, false)
     |> assign(:season_delete, nil)}
  end

  # Same fixed-clause mode parsing as toggle_file_delete_mode/2. The checkbox
  # arrives as "true"/"false" (a hidden "false" input precedes it); anything
  # but "true" leaves the season monitored.
  defp change(params, %{assigns: %{season_delete: %{} = state}} = socket) do
    mode =
      case params["file_delete_mode"] do
        "library_only" -> :library_only
        "permanent" -> :permanent
        _ -> :trash
      end

    {:noreply,
     assign(socket, :season_delete, %{
       state
       | mode: mode,
         unmonitor: params["unmonitor"] == "true"
     })}
  end

  defp change(_params, socket), do: {:noreply, socket}

  defp delete_files(_params, %{assigns: %{season_delete: %{} = state}} = socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      media_item_id = socket.assigns.media_item.id
      socket = socket |> assign(:show_season_delete_confirm, false) |> assign(:season_delete, nil)

      {count, failed} = run_season_delete(state)

      # The user asked for the season to stop being monitored; honour it even
      # when some files failed, since the failure count is shown below.
      if state.unmonitor,
        do: Media.update_season_monitoring(media_item_id, state.season_number, false)

      socket =
        socket
        |> assign(:media_item, load_media_item(socket.assigns.current_scope, media_item_id))
        |> put_flash(:info, season_delete_success_message(state.mode, count))

      socket =
        if failed == [],
          do: socket,
          else:
            put_flash(
              socket,
              :error,
              ngettext(
                "%{count} file could not be removed",
                "%{count} files could not be removed",
                length(failed)
              )
            )

      {:noreply, socket}
    else
      {:unauthorized, socket} -> {:noreply, socket}
    end
  end

  defp delete_files(_params, socket), do: {:noreply, socket}

  # Returns {removed_count, failed}. A `:file_delete_failed` entry is a row
  # that is already gone from the DB, so it counts as failed, not removed.
  defp run_season_delete(%{mode: :trash} = state) do
    {:ok, %{trashed: ok, failed: failed}} =
      Library.trash_episode_files(state.episode_ids, reason: :manual)

    {length(ok), failed}
  end

  defp run_season_delete(%{mode: mode} = state) do
    {:ok, %{deleted: ok, failed: failed}} =
      Library.delete_episode_files(state.episode_ids, delete_files: mode == :permanent)

    {length(ok), failed}
  end

  defp season_delete_success_message(:trash, n),
    do: ngettext("Moved %{count} file to trash", "Moved %{count} files to trash", n)

  defp season_delete_success_message(:permanent, n),
    do:
      ngettext(
        "Deleted %{count} file, including from disk",
        "Deleted %{count} files, including from disk",
        n
      )

  defp season_delete_success_message(:library_only, n),
    do:
      ngettext(
        "Removed %{count} file from the library, kept on disk",
        "Removed %{count} files from the library, kept on disk",
        n
      )
end
