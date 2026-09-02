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
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Mydia.PubSub, Mydia.Jobs.TrashAction.topic())

    {:ok,
     socket
     |> assign(:page_title, "Configuration - Trash")
     |> assign(:active_tab, :trash)
     |> assign(:reason, nil)
     |> assign(:page, 0)
     |> assign(:page_size, @per_page)
     |> assign(:show_empty_modal, false)
     |> assign(:audit, nil)
     |> assign(:scanning, false)
     |> assign(:sweeping, false)
     |> assign(:selection, MapSet.new())
     |> assign(:retention_days, Mydia.Config.get().media.trash_retention_days)
     |> load()}
  end

  defp load(socket) do
    counts = Library.count_trashed_media_files()
    total_matching = matching_count(counts, socket.assigns.reason)

    # Count first, then clamp, then query. Every action on this page removes
    # rows, so the offset held in assigns can outrun the result set it was
    # computed against: restoring the only row on page 2 of 51 leaves 50 rows
    # and an offset of 50, which returns nothing and renders "Showing 51-50
    # of 50". The last page is the highest offset that still holds a row.
    page = clamp_page(socket.assigns.page, total_matching)

    socket
    |> assign(:summary, Library.trashed_summary())
    |> assign(:counts, counts)
    |> assign(:total_matching, total_matching)
    |> assign(:page, page)
    |> assign(
      :files,
      Library.list_trashed_media_files(
        reason: socket.assigns.reason,
        limit: @per_page,
        offset: page * @per_page,
        preload: [:media_item, :library_path, episode: :media_item]
      )
    )
  end

  defp clamp_page(_page, total) when total <= 0, do: 0
  defp clamp_page(page, total), do: page |> max(0) |> min(div(total - 1, @per_page))

  defp matching_count(counts, nil), do: counts |> Map.values() |> Enum.sum()
  defp matching_count(counts, :unknown), do: Map.get(counts, nil, 0)
  defp matching_count(counts, reason), do: Map.get(counts, reason, 0)

  @impl true
  def handle_event("filter_reason", %{"reason" => ""}, socket) do
    {:noreply, socket |> assign(reason: nil, page: 0, selection: MapSet.new()) |> load()}
  end

  def handle_event("filter_reason", %{"reason" => reason}, socket) do
    # Never String.to_atom/1 on request data. The chip values come from the
    # component's own fixed list, so an unknown one is a bug or a forged
    # event, and both mean "no filter".
    parsed =
      Enum.find_value(MydiaWeb.AdminTrashLive.Components.reasons(), fn {r, _, _} ->
        if to_string(r) == reason, do: r
      end)

    # A selection, explicit or "all matching", is scoped to the filter that
    # was active when it was made. `{:all_matching, :missing}` means every
    # Missing row, not whatever the next filter happens to show, so changing
    # the filter must drop it rather than let it silently retarget a
    # destructive bulk action at the wrong rows.
    {:noreply, socket |> assign(reason: parsed, page: 0, selection: MapSet.new()) |> load()}
  end

  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, socket |> assign(:page, String.to_integer(page)) |> load()}
  end

  def handle_event("toggle_select", %{"id" => id}, socket) do
    selection =
      case socket.assigns.selection do
        # Ticking a box after "select all matching" drops back to an explicit
        # set, otherwise the click would appear to do nothing.
        {:all_matching, _reason} -> MapSet.new([id])
        ids -> toggle(ids, id)
      end

    {:noreply, assign(socket, :selection, selection)}
  end

  def handle_event("select_all_matching", _params, socket) do
    {:noreply, assign(socket, :selection, {:all_matching, socket.assigns.reason})}
  end

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, :selection, MapSet.new())}
  end

  def handle_event("bulk_restore", _params, socket), do: enqueue(socket, "restore")
  def handle_event("bulk_purge", _params, socket), do: enqueue(socket, "purge")

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
    # `sweep/1` calls `File.rm_rf/1` per entry, so it inherits the same
    # disconnected-mount hazard as the audit walk and runs off the LiveView
    # process for the same reason. Dropping the audit as the task starts
    # leaves nothing for a second click to re-sweep.
    case socket.assigns.audit do
      nil ->
        {:noreply, socket}

      audit ->
        entries = audit.retained ++ audit.orphaned

        {:noreply,
         socket
         |> assign(:audit, nil)
         |> assign(:sweeping, true)
         |> start_async(:sweep, fn -> TrashStore.sweep(entries) end)}
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

  def handle_async(:sweep, {:ok, result}, socket) do
    {:noreply, socket |> assign(:sweeping, false) |> put_flash(:info, sweep_message(result))}
  end

  def handle_async(:sweep, {:exit, reason}, socket) do
    {:noreply,
     socket
     |> assign(:sweeping, false)
     |> put_flash(:error, "Could not sweep the trash directory: #{inspect(reason)}")}
  end

  @impl true
  def handle_info({:trash_action_progress, _progress}, socket), do: {:noreply, socket}

  def handle_info({:trash_action_done, result}, socket) do
    {:noreply, socket |> put_flash(:info, done_message(result)) |> load()}
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

  defp enqueue(socket, action) do
    args = %{"action" => action, "selection" => encode(socket.assigns.selection)}

    case %{} |> Map.merge(args) |> Mydia.Jobs.TrashAction.new() |> Oban.insert() do
      {:ok, _job} ->
        {:noreply,
         socket
         |> assign(:selection, MapSet.new())
         |> put_flash(:info, "Working through the selected files in the background.")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not start that: #{inspect(reason)}")}
    end
  end

  defp encode({:all_matching, reason}),
    do: %{"type" => "all_matching", "reason" => reason && to_string(reason)}

  defp encode(%MapSet{} = ids), do: %{"type" => "ids", "ids" => MapSet.to_list(ids)}

  defp toggle(ids, id) do
    if MapSet.member?(ids, id), do: MapSet.delete(ids, id), else: MapSet.put(ids, id)
  end

  defp done_message(%{action: "restore", ok: ok, retained: retained, failed: failed}) do
    base = "Restored #{ok} file(s)."

    base
    |> maybe_append(
      retained > 0,
      " #{retained} had an occupied library path, so the trashed copy was kept."
    )
    |> maybe_append(failed > 0, " #{failed} could not be restored.")
  end

  defp done_message(%{action: "purge", ok: ok, failed: failed}) do
    "Deleted #{ok} file(s) permanently."
    |> maybe_append(failed > 0, " #{failed} could not be deleted.")
  end

  defp maybe_append(message, false, _suffix), do: message
  defp maybe_append(message, true, suffix), do: message <> suffix

  defp fetch_trashed(id) do
    Library.get_trashed_media_file(id,
      preload: [:media_item, :library_path, episode: :media_item]
    )
  end

  defp label(file), do: MydiaWeb.AdminTrashLive.Components.label_for(file)
end
