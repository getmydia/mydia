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

  import MydiaWeb.Formatters, only: [format_file_size: 1]

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

  def handle_event("save", params, socket) do
    download = socket.assigns.download
    indexes = params |> Map.get("files", []) |> Enum.flat_map(&parse_index/1)

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

  defp load(socket) do
    download = socket.assigns.download
    supported = TorrentFiles.supported?(download)
    files = list_files(download, supported)

    assign(socket,
      supported: supported,
      files: files,
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

  defp parse_index(value) do
    case Integer.parse(to_string(value)) do
      {index, ""} when index >= 0 -> [index]
      _ -> []
    end
  end

  defp file_progress(%{size: size, downloaded: downloaded}) when size > 0,
    do: min(100, trunc(downloaded * 100 / size))

  defp file_progress(_file), do: 0

  @impl true
  def render(assigns) do
    ~H"""
    <div>
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
          <ul class="flex flex-col gap-2">
            <li :for={file <- @files} id={"download-file-#{file.index}"}>
              <label class="flex items-start gap-3 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  name="files[]"
                  value={file.index}
                  checked={file.included?}
                  disabled={not @editable}
                  class="checkbox checkbox-sm mt-0.5"
                />
                <span class="min-w-0 flex-1">
                  <span class="block break-all">{file.path}</span>
                  <span class="flex items-center gap-2 text-xs text-base-content/60">
                    <span>{format_file_size(file.size)}</span>
                    <progress
                      :if={file.included?}
                      class="progress progress-primary w-24"
                      value={file_progress(file)}
                      max="100"
                    ></progress>
                  </span>
                </span>
              </label>
            </li>
          </ul>
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
