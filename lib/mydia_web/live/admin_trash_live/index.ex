defmodule MydiaWeb.AdminTrashLive.Index do
  @moduledoc """
  Lists trashed media files and lets an operator restore or purge them.

  ## Why the list is re-queried rather than streamed

  Every action here changes what the list should contain, and the filter
  counts in the chips have to agree with it. Re-querying a page of 50 rows
  after each action is cheaper than reconciling a stream against a changed
  filter, and a stale row on a destructive page is a correctness problem
  rather than a performance one. This follows `AdminDuplicatesLive.Index`,
  which re-plans on every render for the same reason.

  ## The audit is not part of the page load

  `TrashStore.audit/0` walks the filesystem. A library on a disconnected NAS
  mount would hang every render if the header figure came from disk, so the
  header sums `media_files.size` instead and the walk runs in a Task only when
  the operator asks for it.

  ## Sweep never takes a path from the client

  `TrashStore.sweep/1` calls `File.rm_rf/1` on whatever paths it is handed and
  does not re-validate that they sit under a trash root; that is safe today
  only because `TrashStore.audit/0` is the sole producer of entries. The
  `"sweep"` handler below reads the audit result already held in
  `socket.assigns.audit` and never accepts a path, id, or any other
  filesystem reference from event params.
  """
  use MydiaWeb, :live_view

  alias Mydia.Library
  alias Mydia.Library.TrashStore

  @per_page 50

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Configuration - Trash")
     |> assign(:active_tab, :trash)
     |> assign(:reason, nil)
     |> assign(:page, 0)
     |> assign(:show_empty_modal, false)
     |> assign(:audit, nil)
     |> assign(:scanning, false)
     |> assign(:retention_days, Mydia.Config.get().media.trash_retention_days)
     |> load()}
  end

  defp load(socket) do
    socket
    |> assign(:summary, Library.trashed_summary())
    |> assign(:counts, Library.count_trashed_media_files())
    |> assign(
      :files,
      Library.list_trashed_media_files(
        reason: socket.assigns.reason,
        limit: @per_page,
        offset: socket.assigns.page * @per_page,
        preload: [:media_item, :episode, :library_path]
      )
    )
  end

  @impl true
  def handle_event("filter_reason", %{"reason" => ""}, socket) do
    {:noreply, socket |> assign(reason: nil, page: 0) |> load()}
  end

  def handle_event("filter_reason", %{"reason" => reason}, socket) do
    # Never String.to_atom/1 on request data. The chip values come from the
    # component's own fixed list, so an unknown one is a bug or a forged
    # event, and both mean "no filter".
    parsed =
      Enum.find_value(MydiaWeb.AdminTrashLive.Components.reasons(), fn {r, _, _} ->
        if to_string(r) == reason, do: r
      end)

    {:noreply, socket |> assign(reason: parsed, page: 0) |> load()}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, String.to_integer(page)) |> load()}
  end

  def handle_event("restore_file", %{"id" => id}, socket) do
    case fetch_trashed(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That file is no longer in the trash.")}

      file ->
        case Library.restore_media_file(file) do
          {:ok, restored} ->
            {:noreply,
             socket
             |> put_flash(:info, "Restored #{label(restored)}.")
             |> load()}

          {:ok, restored, :trash_copy_retained} ->
            {:noreply,
             socket
             |> put_flash(
               :warning,
               "Restored #{label(restored)}, but its library path was already occupied, so the " <>
                 "trashed copy was kept. Run \"Scan trash directory\" to find and remove it."
             )
             |> load()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not restore that file: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("purge_file", %{"id" => id}, socket) do
    case fetch_trashed(id) do
      nil ->
        {:noreply, put_flash(socket, :error, "That file is no longer in the trash.")}

      file ->
        case Library.purge_media_file(file) do
          :ok ->
            {:noreply,
             socket |> put_flash(:info, "Deleted #{label(file)} permanently.") |> load()}

          {:error, reason} ->
            {:noreply,
             put_flash(socket, :error, "Could not delete that file: #{inspect(reason)}")}
        end
    end
  end

  def handle_event("confirm_empty", _params, socket) do
    {:noreply, assign(socket, :show_empty_modal, true)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, :show_empty_modal, false)}
  end

  def handle_event("empty_trash", _params, socket) do
    {:ok, count} = Library.purge_old_trashed_media_files(0)

    {:noreply,
     socket
     |> assign(:show_empty_modal, false)
     |> assign(:page, 0)
     |> put_flash(:info, "Purged #{count} file(s) from the trash.")
     |> load()}
  end

  def handle_event("scan_directory", _params, socket) do
    {:noreply,
     socket
     |> assign(:scanning, true)
     |> start_async(:audit, fn -> TrashStore.audit() end)}
  end

  # Reads the audit result out of assigns rather than accepting anything from
  # params: see the moduledoc note "Sweep never takes a path from the
  # client". Params here carry no path, id, or other filesystem reference,
  # and must never be made to.
  def handle_event("sweep", _params, socket) do
    case socket.assigns.audit do
      nil ->
        {:noreply, socket}

      audit ->
        result = TrashStore.sweep(audit.retained ++ audit.orphaned)

        {:noreply,
         socket
         |> assign(:audit, nil)
         |> put_flash(:info, sweep_message(result))}
    end
  end

  @impl true
  def handle_async(:audit, {:ok, audit}, socket) do
    {:noreply, socket |> assign(:scanning, false) |> assign(:audit, audit)}
  end

  def handle_async(:audit, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:scanning, false)
     |> put_flash(:error, "Could not read the trash directory: #{inspect(reason)}")}
  end

  defp sweep_message(%{swept: swept, bytes: bytes, skipped: 0}) do
    "Swept #{swept} item(s), reclaiming " <>
      MydiaWeb.AdminTrashLive.Components.humanize_bytes(bytes) <> "."
  end

  defp sweep_message(%{swept: swept, bytes: bytes, skipped: skipped}) do
    "Swept #{swept} item(s), reclaiming " <>
      MydiaWeb.AdminTrashLive.Components.humanize_bytes(bytes) <>
      ". Skipped #{skipped}, either too recently written to be safe or not removable."
  end

  defp fetch_trashed(id) do
    Library.get_trashed_media_file(id, preload: [:media_item, :episode, :library_path])
  end

  defp label(file), do: MydiaWeb.AdminTrashLive.Components.label_for(file)
end
