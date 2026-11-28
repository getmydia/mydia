defmodule MydiaWeb.DownloadsLive.FilesPanel do
  @moduledoc """
  Lets the operator choose which files of a built-in torrent download, from the
  Downloads detail drawer, until the download is imported.

  The client is asked for the file list only when the drawer opens on a
  different download, after a save, and when the operator presses Refresh,
  never on a Downloads list refresh. A list that came back empty (a magnet
  whose metadata has not resolved) or failed is not retried on its own: the
  panel says so and offers Refresh. Renders nothing when the download's
  client cannot select files.
  """
  use MydiaWeb, :live_component

  import MydiaWeb.FileTreeComponents, only: [file_tree: 1, toggle_target: 1]

  alias Mydia.Downloads.FileTree
  alias Mydia.Downloads.TorrentFiles

  @impl true
  def update(%{download: download} = assigns, socket) do
    socket = assign(socket, assigns)
    socket = assign(socket, :editable, TorrentFiles.editable?(download))

    # `loaded_id` is set only by a load that returned files, `pending_id` by
    # one that did not; either way a list refresh does not ask the client.
    if download.id in [socket.assigns[:loaded_id], socket.assigns[:pending_id]] do
      {:ok, socket}
    else
      {:ok, load(socket)}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket), do: {:noreply, load(socket)}

  def handle_event("toggle_files", params, socket) do
    case toggle_target(params) do
      nil ->
        {:noreply, socket}

      target ->
        {:noreply, change_selection(socket, &FileTree.toggle(&1, socket.assigns.files, target))}
    end
  end

  def handle_event("toggle_all_files", _params, socket) do
    {:noreply, change_selection(socket, &FileTree.toggle_all(&1, socket.assigns.files))}
  end

  def handle_event("save", _params, socket) do
    download = socket.assigns.download
    indexes = socket.assigns.selected |> MapSet.to_list() |> Enum.sort()

    case TorrentFiles.save(download, indexes) do
      :ok ->
        {:noreply, socket |> assign(:error, nil) |> load()}

      {:error, :no_importable_file} ->
        {:noreply, assign(socket, :error, gettext("Keep at least one video file."))}

      {:error, :imported} ->
        {:noreply,
         socket
         |> assign(:editable, false)
         |> reload_after_error(gettext("This download was already imported."))}

      {:error, _reason} ->
        {:noreply, reload_after_error(socket, gettext("Couldn't update the file selection."))}
    end
  end

  defp change_selection(%{assigns: %{editable: false}} = socket, _fun), do: socket

  defp change_selection(socket, fun),
    do: assign(socket, :selected, fun.(socket.assigns.selected))

  defp load(socket) do
    download = socket.assigns.download
    supported = TorrentFiles.supported?(download)
    files = list_files(download, supported)

    selected = files |> Enum.filter(& &1.included?) |> MapSet.new(& &1.index)

    assign(socket,
      supported: supported,
      files: files,
      selected: selected,
      saved: selected,
      error: nil,
      loaded_id: if(files != [], do: download.id),
      pending_id: if(files == [], do: download.id)
    )
  end

  # After a failed save the client may not answer either: keep the list the
  # operator just saw, so the error shown with it stays on screen.
  defp reload_after_error(socket, error) do
    files =
      case list_files(socket.assigns.download, socket.assigns.supported) do
        [] -> socket.assigns.files
        files -> files
      end

    assign(socket, files: files, error: error)
  end

  defp list_files(download, supported) do
    with true <- supported, {:ok, files} <- TorrentFiles.list(download) do
      files
    else
      _ -> []
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="download-files-component">
      <fieldset :if={@supported} id="download-files-panel" class="fieldset">
        <legend class="fieldset-legend">{gettext("Files")}</legend>
        <div :if={@files == []} class="flex items-center gap-3">
          <p id="download-files-unavailable" class="text-sm text-base-content/70">
            {gettext("The file list is not available yet.")}
          </p>
          <button
            id="download-files-refresh"
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="refresh"
            phx-target={@myself}
          >
            <.icon name="hero-arrow-path" class="size-4" />
            {gettext("Refresh")}
          </button>
        </div>
        <.form
          :if={@files != []}
          for={%{}}
          as={:selection}
          id="download-files-form"
          phx-submit="save"
          phx-target={@myself}
        >
          <.file_tree
            id="download-files-tree"
            files={@files}
            selected={@selected}
            disabled={not @editable}
            target={@myself}
            show_progress={true}
          />
          <p :if={@selected != @saved} id="download-files-unsaved" class="text-warning text-sm mt-2">
            {gettext("Unsaved changes")}
          </p>
          <p :if={@error} id="download-files-error" class="text-error text-sm mt-2">{@error}</p>
          <button
            :if={@editable}
            id="download-files-save"
            type="submit"
            class="btn btn-primary btn-sm mt-3"
          >
            {gettext("Save selection")}
          </button>
        </.form>
      </fieldset>
    </div>
    """
  end
end
