defmodule MydiaWeb.DownloadsLive.FilesPanel do
  @moduledoc """
  Lets the operator choose which files of a built-in torrent download, from the
  Downloads detail drawer, until the download is imported.

  The client is asked for the file list only when the drawer opens on a
  different download and after a save, never on a Downloads list refresh.
  Renders nothing when the download's client cannot select files.
  """
  use MydiaWeb, :live_component

  import MydiaWeb.Formatters, only: [format_file_size: 1]

  alias Mydia.Downloads.TorrentFiles

  @impl true
  def update(%{download: download} = assigns, socket) do
    socket = assign(socket, assigns)
    socket = assign(socket, :editable, TorrentFiles.editable?(download))

    if socket.assigns[:loaded_id] == download.id do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded_id, download.id) |> load()}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    download = socket.assigns.download
    indexes = params |> Map.get("files", []) |> Enum.flat_map(&parse_index/1)

    case TorrentFiles.save(download, indexes) do
      :ok ->
        {:noreply, socket |> assign(:error, nil) |> load()}

      {:error, :no_importable_file} ->
        {:noreply, assign(socket, :error, gettext("Keep at least one video file."))}

      {:error, :imported} ->
        send(self(), {:flash, :error, gettext("This download was already imported.")})
        {:noreply, load(socket)}

      {:error, _reason} ->
        send(self(), {:flash, :error, gettext("Couldn't update the file selection.")})
        {:noreply, load(socket)}
    end
  end

  defp load(socket) do
    download = socket.assigns.download
    supported = TorrentFiles.supported?(download)

    files =
      with true <- supported, {:ok, files} <- TorrentFiles.list(download) do
        files
      else
        _ -> []
      end

    assign(socket, supported: supported, files: files, error: nil)
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
      <fieldset :if={@supported and @files != []} id="download-files-panel" class="fieldset">
        <legend class="fieldset-legend">{gettext("Files")}</legend>
        <.form
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
