defmodule MydiaWeb.AdminLibraryPathsLive.Maintenance do
  @moduledoc """
  Event, async and PubSub handlers for the Library Paths page's bulk rename and
  orphaned-sidecar cleanup actions.

  `index.ex` delegates here. The open modal is one assign,
  `:maintenance_modal`, holding `{kind, library_path_id, AsyncResult}`; the
  preview result (including the sidecar paths the cleanup will move) lives on
  the socket, so the client never sends paths back.
  """

  use Gettext, backend: MydiaWeb.Gettext

  import Phoenix.Component, only: [assign: 3, update: 3]
  import Phoenix.LiveView, only: [put_flash: 3, start_async: 3]

  alias Mydia.Jobs.{LibraryRename, SidecarCleanup}
  alias Mydia.Library.BulkRename
  alias Mydia.Library.SidecarCleanup, as: SidecarScan
  alias Mydia.Settings
  alias Phoenix.LiveView.AsyncResult

  ## Events

  def preview_bulk_rename(%{"id" => id}, socket), do: open_preview(socket, :bulk_rename, id)

  def preview_sidecar_cleanup(%{"id" => id}, socket),
    do: open_preview(socket, :sidecar_cleanup, id)

  def close_modal(_params, socket), do: {:noreply, assign(socket, :maintenance_modal, nil)}

  def confirm_bulk_rename(_params, socket) do
    with {:bulk_rename, id,
          %AsyncResult{ok?: true, result: %{changed: changed, conflicts: conflicts}}} <-
           socket.assigns.maintenance_modal,
         true <- changed - length(conflicts) > 0 do
      case LibraryRename.enqueue(id) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:maintenance_modal, nil)
           |> update(:renaming_library_ids, &MapSet.put(&1, id))
           |> put_flash(:info, gettext("Library rename started..."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to start rename"))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  def confirm_sidecar_cleanup(_params, socket) do
    with {:sidecar_cleanup, id, %AsyncResult{ok?: true, result: %{folders: folders}}} <-
           socket.assigns.maintenance_modal,
         paths when paths != [] <- Enum.flat_map(folders, &elem(&1, 1)) do
      case SidecarCleanup.enqueue(id, paths) do
        {:ok, _job} ->
          {:noreply,
           socket
           |> assign(:maintenance_modal, nil)
           |> update(:cleaning_library_ids, &MapSet.put(&1, id))
           |> put_flash(:info, gettext("Sidecar cleanup started..."))}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, gettext("Failed to start cleanup"))}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  ## Async

  def handle_preview_async({:ok, result}, socket), do: {:noreply, set_result(socket, result)}

  def handle_preview_async({:exit, reason}, socket),
    do: {:noreply, set_result(socket, {:error, {:exit, reason}})}

  ## PubSub

  def handle_info({:library_rename_started, %{library_path_id: id}}, socket),
    do: {:noreply, update(socket, :renaming_library_ids, &MapSet.put(&1, id))}

  def handle_info(
        {:library_rename_progress, %{library_path_id: id, done: done, total: total}},
        socket
      ) do
    {:noreply,
     socket
     |> update(:renaming_library_ids, &MapSet.put(&1, id))
     |> update(:rename_progress, &Map.put(&1, id, {done, total}))}
  end

  def handle_info({:library_rename_completed, %{library_path_id: id} = result}, socket) do
    socket =
      socket
      |> update(:renaming_library_ids, &MapSet.delete(&1, id))
      |> update(:rename_progress, &Map.delete(&1, id))

    case result do
      %{error: :busy} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Rename skipped: a cleanup is running on this library")
         )}

      %{error: reason} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Rename failed: %{reason}", reason: format_error(reason))
         )}

      _ ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Renamed %{renamed} files, %{conflicts} conflicts, %{errors} errors",
             renamed: result.renamed,
             conflicts: result.conflicts,
             errors: result.errors
           )
         )}
    end
  end

  def handle_info({:sidecar_cleanup_started, %{library_path_id: id}}, socket),
    do: {:noreply, update(socket, :cleaning_library_ids, &MapSet.put(&1, id))}

  def handle_info({:sidecar_cleanup_completed, %{library_path_id: id} = result}, socket) do
    socket = update(socket, :cleaning_library_ids, &MapSet.delete(&1, id))

    cond do
      Map.get(result, :error) == :busy ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cleanup skipped: a rename or move is running on this library")
         )}

      Map.has_key?(result, :error) ->
        {:noreply,
         put_flash(
           socket,
           :error,
           gettext("Cleanup failed: %{reason}", reason: format_error(result.error))
         )}

      result.moved > 0 ->
        {:noreply,
         put_flash(
           socket,
           :info,
           gettext("Moved %{moved} files to %{container}",
             moved: result.moved,
             container: result.container
           )
         )}

      true ->
        {:noreply, put_flash(socket, :info, gettext("No orphaned sidecars were moved"))}
    end
  end

  ## Helpers

  defp open_preview(socket, kind, id) do
    library_path = Settings.get_library_path!(id)

    {:noreply,
     socket
     |> assign(:maintenance_modal, {kind, id, AsyncResult.loading()})
     |> start_async(:maintenance_preview, fn -> {kind, id, preview(kind, library_path)} end)}
  end

  defp preview(:bulk_rename, library_path), do: BulkRename.preview(library_path)
  defp preview(:sidecar_cleanup, library_path), do: SidecarScan.preview(library_path)

  # Ignores a late result when the modal was closed or switched meanwhile.
  defp set_result(socket, {kind, id, result}) do
    case socket.assigns.maintenance_modal do
      {^kind, ^id, %AsyncResult{} = async} ->
        async =
          case result do
            {:ok, data} -> AsyncResult.ok(async, data)
            {:error, reason} -> AsyncResult.failed(async, reason)
          end

        assign(socket, :maintenance_modal, {kind, id, async})

      _ ->
        socket
    end
  end

  defp set_result(socket, {:error, reason}) do
    case socket.assigns.maintenance_modal do
      {kind, id, async} ->
        assign(socket, :maintenance_modal, {kind, id, AsyncResult.failed(async, reason)})

      nil ->
        socket
    end
  end

  defp format_error(:library_unavailable), do: gettext("library unavailable")
  defp format_error(:s3_unsupported), do: gettext("S3 libraries are not supported")
  defp format_error(reason), do: inspect(reason)
end
