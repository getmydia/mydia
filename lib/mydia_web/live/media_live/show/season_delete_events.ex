defmodule MydiaWeb.MediaLive.Show.SeasonDeleteEvents do
  @moduledoc false

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3]

  alias Mydia.Library
  alias Mydia.Media.{Episode, Monitoring}
  alias MydiaWeb.Live.Authorization
  alias MydiaWeb.MediaLive.Show.{Loaders, SeasonDelete}

  @events ~w(show_season_delete_confirm hide_season_delete_confirm change_season_delete delete_season_files)

  @doc """
  True for the `handle_event/3` names this module owns. A guard, so the show
  LiveView dispatches on the same list `handle/3` matches.
  """
  defguard is_season_delete_event(event) when event in @events

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

      episode_ids =
        for e <- socket.assigns.media_item.episodes,
            e.season_number == season_number,
            do: e.id

      # The same selection the delete acts on, so the numbers match what goes.
      # A season whose files are all blocked still opens, to say why nothing
      # can be removed.
      case Library.episode_files_for_removal(episode_ids) do
        %{removable: [], blocked: []} ->
          {:noreply, socket}

        %{removable: files, blocked: blocked} ->
          {:noreply,
           socket
           |> assign(:season_delete, %SeasonDelete{
             season_number: season_number,
             episode_ids: episode_ids,
             file_count: length(files),
             bytes: Enum.reduce(files, 0, &((&1.size || 0) + &2)),
             blocked_count: length(blocked)
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
  defp change(params, %{assigns: %{season_delete: %SeasonDelete{} = state}} = socket) do
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

  defp delete_files(_params, %{assigns: %{season_delete: %SeasonDelete{file_count: 0}}} = socket),
    do: {:noreply, socket}

  defp delete_files(_params, %{assigns: %{season_delete: %SeasonDelete{} = state}} = socket) do
    with :ok <- Authorization.authorize_delete_media(socket) do
      media_item_id = socket.assigns.media_item.id
      socket = socket |> assign(:show_season_delete_confirm, false) |> assign(:season_delete, nil)

      {count, failed} = run_season_delete(state)

      # The user asked for the season to stop being monitored. Honour it for
      # every episode except those a file still holds: one that failed, or
      # one skipped because it also covers another season.
      if state.unmonitor, do: unmonitor_released(state.episode_ids, failed)

      media_item = Loaders.load_media_item(socket.assigns.current_scope, media_item_id)
      # The hero links the next episode's file; recompute it as mount does.
      {next_episode, next_episode_state} = Loaders.load_next_episode(media_item, socket)

      socket =
        socket
        |> assign(:media_item, media_item)
        |> assign(:next_episode, next_episode)
        |> assign(:next_episode_state, next_episode_state)
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

  defp unmonitor_released(episode_ids, failed) do
    held = failed |> Enum.map(&elem(&1, 0)) |> Library.covered_episode_ids()

    episode_ids
    |> Enum.reject(&MapSet.member?(held, &1))
    |> Enum.map(&%Episode{id: &1})
    |> Monitoring.set_episodes_monitored(false)
  end

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
