defmodule MydiaWeb.DownloadsLive.RemoveConfirm do
  @moduledoc """
  The confirm dialog for removing one torrent from its client: a finished
  download's trash button, and a client torrent stranded in Issues.

  Both ask whether the downloaded files go too. Deleting is the default:
  import hardlinks or copies, so the library keeps its copy, and leaving the
  data behind is what filled the download folder in issue #1422. A browser
  `data-confirm` cannot carry that checkbox, hence the dialog.
  """

  use MydiaWeb, :html

  alias Mydia.Downloads
  alias Mydia.Downloads.ExternalTorrents
  alias Mydia.Downloads.Structs.ExternalTorrent
  alias MydiaWeb.SeedingComponents

  @enforce_keys [:target, :title]
  defstruct [:target, :title, warning: nil, delete_files: true]

  @type target :: {:download, binary()} | {:torrent, binary()}
  @type t :: %__MODULE__{
          target: target(),
          title: String.t(),
          warning: String.t() | nil,
          delete_files: boolean()
        }

  @doc """
  The dialog for a tracked download. `download` should be the row the page
  rendered, which carries the client's ratio, so an unmet seeding goal is
  named in the warning.
  """
  @spec for_download(map()) :: t()
  def for_download(download) do
    %__MODULE__{
      target: {:download, download.id},
      title: download.title,
      warning: SeedingComponents.removal_warning_text(download)
    }
  end

  @doc "The dialog for a client torrent Mydia does not track."
  @spec for_torrent(Mydia.Downloads.Structs.ExternalTorrent.t()) :: t()
  def for_torrent(torrent), do: %__MODULE__{target: {:torrent, torrent.id}, title: torrent.title}

  @doc """
  Removes a client torrent Mydia does not track, returning the flash to show.
  """
  @spec remove_torrent(String.t(), boolean()) :: {:info | :error, String.t()}
  def remove_torrent(id, delete_files) do
    with %ExternalTorrent{} = torrent <- ExternalTorrents.find(id) || :gone,
         :ok <- Downloads.remove_external_torrent(torrent, delete_files: delete_files) do
      {:info, gettext("Removed from the download client")}
    else
      :gone -> {:error, gettext("That torrent is no longer in the client")}
      {:error, _reason} -> {:error, gettext("Could not remove that torrent from the client")}
    end
  end

  attr :confirm, __MODULE__, default: nil

  def remove_confirm_modal(assigns) do
    ~H"""
    <.modal :if={@confirm} id="remove-confirm-modal" show on_cancel="close_remove_confirm">
      <:title>{gettext("Remove from client")}</:title>
      <form
        id="remove-confirm-form"
        phx-change="toggle_remove_delete_files"
        phx-submit="confirm_remove"
      >
        <p class="text-base-content/80 break-words">
          {gettext("Remove %{title} from the download client and clear it from Mydia?",
            title: @confirm.title
          )}
        </p>
        <p
          :if={@confirm.warning}
          id="remove-confirm-warning"
          class="alert alert-warning alert-soft mt-4 text-sm"
        >
          {@confirm.warning}
        </p>
        <label class="label cursor-pointer justify-start gap-3 mt-4">
          <%!-- Unchecked boxes submit nothing; the hidden input says "false". --%>
          <input type="hidden" name="delete_files" value="false" />
          <input
            id="remove-confirm-delete-files"
            type="checkbox"
            name="delete_files"
            value="true"
            checked={@confirm.delete_files}
            class="checkbox checkbox-error"
          />
          <span class="label-text whitespace-normal">
            {gettext("Also delete the downloaded files from the download folder")}
          </span>
        </label>
        <p class="text-sm text-base-content/60 mt-2">
          {if @confirm.delete_files,
            do: gettext("Files already imported into your library are kept. This cannot be undone."),
            else: gettext("The files stay in the download folder until you remove them.")}
        </p>
      </form>
      <:actions>
        <button
          id="remove-confirm-cancel"
          type="button"
          class="btn btn-ghost"
          phx-click="close_remove_confirm"
        >
          {gettext("Cancel")}
        </button>
        <button
          id="remove-confirm-submit"
          type="submit"
          form="remove-confirm-form"
          class={["btn", (@confirm.delete_files && "btn-error") || "btn-primary"]}
        >
          {if @confirm.delete_files,
            do: gettext("Remove and delete files"),
            else: gettext("Remove")}
        </button>
      </:actions>
    </.modal>
    """
  end
end
